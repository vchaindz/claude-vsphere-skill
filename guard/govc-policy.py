#!/usr/bin/env python3
"""
govc-policy — deterministic security layer for the govc skill.

A Claude Code PreToolUse hook that classifies every govc / govc-safe
invocation in a Bash command and enforces a tier from a policy file the
model cannot edit. Unlike the safety rules in SKILL.md — which are
instructions to the model — this is code: it runs before the command does,
and its decision does not depend on what the model intended.

Tiers (policy file, default READONLY if the file is missing or malformed —
fail closed):

  readonly   only read-class commands (info/ls/find/collect/events/metrics…)
  standard   read + mutate (create, clone, power-on, migrate, config
             changes); destroy-class commands are denied
  full       everything, but destroy-class commands return permission
             decision "ask" — the user must confirm in the UI, always,
             deterministically

Classification:

  read     .info / .ls suffix or explicit read set; never mutates vSphere
  mutate   named subcommands we recognise but that only change state
  destroy  explicit set + suffix heuristic (rm / remove / destroy /
           shutdown / reboot / wipe / unregister), so destructive
           subcommands added in future govc releases are still caught;
           vm.power is classified per flag (-off / -reset / -suspend /
           -s / -r all stop a running workload, so all five are destroy;
           -on is mutate), and -flag=true is normalised to -flag

           *plus* anything whose subcommand we cannot actually read off
           the command line — `... | xargs govc`, `$B vm.destroy`,
           `govc $(...)`. Unknown is the suspicious case, and only readonly
           denies mutate, so an indeterminate subcommand has to be destroy
           or every higher tier fails open on ordinary shell indirection.

Scripts are read through. A govc call the model wrote into a file with the
Write tool never appears in the Bash command, so `bash ./x.sh`, `./x.sh`,
`source x.sh` and the scripts those run in turn (depth 3) are opened and
classified the same way. Files the command merely *reads* are not judged:
`cat notes.md` must not be denied for what the prose in notes.md mentions.

The guard also refuses any command that writes to its own policy file or to
this script, at every tier: without that, the agent can raise its own tier.
Paths are resolved — `cd`, `~`, `$HOME`, relative — and compared against the
two real files, so a checkout of this repo stays editable and testable.

Honesty note, same as the privacy wrapper: this matches text, so it is
deterministic — the same command always gets the same decision — but it can
only read what is on disk when it runs. Content piped into a shell from
somewhere it cannot see (`curl … | bash`) is not covered, and a deliberately
hostile agent could obfuscate its way around text matching. For a hard
boundary use a least-privilege vCenter role; the two compose (see README).

Policy file: ~/.config/govc-guard/policy  (override: GOVC_GUARD_POLICY set
in the environment that launched Claude Code — env assignments inside the
Bash command itself cannot retarget the hook, which reads its own process
environment).

Format:
    tier = standard
    # optional, space/comma separated govc subcommands:
    deny  = vm.migrate datastore.upload      # always denied on top of tier
    allow = snapshot.revert                  # demote destroy -> mutate

The installer also writes settings.json deny rules covering both the policy
file and this script, so neither can be edited through the file tools.

Self-test: govc-policy.py --selftest
"""

import json
import os
import re
import shlex
import sys

POLICY_PATH = os.environ.get(
    "GOVC_GUARD_POLICY",
    os.path.join(os.environ.get("XDG_CONFIG_HOME")
                 or os.path.join(os.path.expanduser("~"), ".config"),
                 "govc-guard", "policy"))

# ---------------------------------------------------------------- policy --

VALID_TIERS = ("readonly", "standard", "full")


def load_policy():
    """Returns (tier, extra_deny:set, allow:set, note:str)."""
    tier, deny, allow, note = "readonly", set(), set(), ""
    try:
        with open(POLICY_PATH, encoding="utf-8") as f:
            seen_tier = None
            for line in f:
                line = line.split("#", 1)[0].strip()
                if not line or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                key, val = key.strip().lower(), val.strip()
                if key == "tier":
                    seen_tier = val.lower()
                elif key == "deny":
                    deny |= set(re.split(r"[,\s]+", val.lower()) if val else [])
                elif key == "allow":
                    allow |= set(re.split(r"[,\s]+", val.lower()) if val else [])
            if seen_tier in VALID_TIERS:
                tier = seen_tier
            else:
                note = (f"policy file {POLICY_PATH} has no valid tier — "
                        "failing closed to readonly")
    except FileNotFoundError:
        note = (f"no policy file at {POLICY_PATH} — failing closed to "
                "readonly (run guard/setup.sh to choose a tier)")
    except OSError as e:
        note = f"policy file unreadable ({e}) — failing closed to readonly"
    deny.discard("")
    allow.discard("")
    return tier, deny, allow, note


# --------------------------------------------------------- classification --

READ_EXACT = {
    "about", "about.cert", "version", "ls", "find", "tree", "collect",
    "object.collect", "events", "tasks", "alarms", "logs", "logs.ls",
    "metric.ls", "metric.info", "metric.sample", "metric.interval.info",
    "snapshot.tree", "session.ls", "cluster.usage", "role.usage",
    "datastore.disk.info", "guest.ps", "guest.df", "guest.ls",
    "vm.ip", "vm.dataset.entry.get", "host.vnic.hint",
    # read vSphere, write only local files
    "export.ovf", "datastore.download", "guest.download",
    # `env` reaches this set only after the credential check in decide()
    "env",
}

# `govc <flag>` never runs a subcommand — it prints the help banner
HELP_FLAGS = {"-h", "--help", "-help"}

# A token the shell has not finished with — $VAR, $(...), `...` — could still
# turn into any subcommand at all, so it is never treated as a literal one.
# (A token that is merely *not* a valid subcommand, like a stray word from a
# quoted string, is harmless: govc rejects it as an unknown command.)
UNRESOLVED = re.compile(r"[$`]")

DESTROY_EXACT = {
    "vm.destroy", "object.destroy", "datastore.rm", "snapshot.remove",
    "snapshot.revert", "host.remove", "host.shutdown", "host.reboot",
    "pool.destroy", "device.remove", "disk.rm", "volume.rm",
    "vm.unregister", "library.rm", "vcsa.shutdown.poweroff",
    "vcsa.shutdown.reboot", "vcsa.shutdown.stop",
}

DESTROY_SUFFIXES = ("rm", "remove", "destroy", "shutdown", "reboot",
                    "wipe", "unregister")

# vm.power flags that stop or disrupt a running workload. -s (guest shutdown)
# and -r (guest reboot) are in here too: they are the *polite* way to take a
# production VM down, but the VM still goes down, so the operator confirms.
POWER_DESTROY_FLAGS = {"-off", "-reset", "-suspend", "-s", "-r"}

# Flags that turn an otherwise read-class subcommand into a state change.
# `govc alarms` lists triggered alarms, which is why it is in READ_EXACT — but
# `govc alarms -ack` acknowledges them, clearing the operator's own warning
# signal, and a health check that "helpfully" acknowledges leaves no trace of
# it in the report it produces. Matched through flag_names, so `--ack` and
# `-ack=true` count — and so does `-ack=false`, which over-classifies a
# command nobody writes. That is the same fail-closed trade as `-off=false`
# under POWER_DESTROY_FLAGS.
#
# Every other verb in READ_EXACT was checked against govc 0.53.0 for this
# shape and none of them has a mutating flag (`session.ls -r` lists the cached
# REST session, `guest.ps -X` waits for a process rather than killing it). The
# table exists so the next one is a line here, not a second special case.
READ_MUTATE_FLAGS = {
    "alarms": {"-ack"},
}

# `govc env` prints GOVC_PASSWORD in cleartext under every output flag
# (-json, -dump, -x, ...); only naming a single non-secret variable is safe
ENV_SENSITIVE = re.compile(r"\bGOVC_PASSWORD\b", re.I)
ENV_VAR_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")

# The guard's own two files, by absolute path: the policy it reads and the
# script it runs as. Matching resolved paths rather than the *names* keeps a
# checkout of this repo editable — `guard/govc-policy.py` in a working tree
# is not the installed hook, and only the installed one decides anything.
GUARD_FILES = frozenset(
    os.path.realpath(p) for p in (POLICY_PATH, __file__))

# best-effort "this segment writes something" heuristic
WRITES = re.compile(
    r">|\btee\b|\b(?:rm|mv|cp|ln|install|chmod|chown|truncate|dd|touch|"
    r"shred)\b|\bsed\s+-[a-z]*i\b|\bgit\s+(?:checkout|restore|clean)\b")
# `python3 x.py` runs x.py; `python3 -c "open(...,'w')"` is a write. Only the
# second form counts, or the guard could never be self-tested.
INLINE_PROG = re.compile(r"\b(?:python3?|perl|ruby|node|awk)\b.*\s-[ce]\b")

# scripts the hook reads through, to see govc calls that are not in the
# Bash command itself
SHELL_RUNNERS = {"bash", "sh", "zsh", "ksh", "dash", "source", "eval"}
MAX_SCRIPT_BYTES = 1 << 20
MAX_SCRIPTS = 16

# matches govc, ./govc, /path/govc, govc.exe, AND govc-safe — policy applies
# to the privacy wrapper too, but not to govc-rehydrate (handled elsewhere)
CALL_RE = re.compile(
    r"(?<![\w/.\\-])"
    r"(?:[A-Za-z]:)?"
    r"(?:[\w.\\/-]*[\\/])?"
    r"govc(?:-safe)?(?:\.exe)?"
    r"(?![\w.-])")


def flag_names(args):
    """The flag tokens as Go's flag package would see them.

    Go accepts one *or two* leading minus signs for the same flag — "One or
    two minus signs may be used; they are equivalent" — so `--off` is `-off`
    and matching only the single-dash spelling is a bypass, not a nicety.
    (Three or more is a parse error in Go, so `---off` needs no handling.)
    `-flag=value` names the same flag as `-flag`.
    """
    out = set()
    for a in args:
        a = a.lower().split("=", 1)[0]
        if a.startswith("--"):
            a = a[1:]
        out.add(a)
    return out


def classify(subcommand, args, allow):
    """-> 'read' | 'mutate' | 'destroy'."""
    sc = subcommand.lower()

    if sc in HELP_FLAGS:
        return "read"

    if not sc or UNRESOLVED.search(sc):
        # We could not read the subcommand off the command line: it is empty
        # (`... | xargs govc`, `$B vm.destroy`) or still a shell expansion
        # (`$@`, `$(...)`). Unknown *is* the dangerous case, so it is
        # destroy-class — calling it 'mutate' lets every tier above readonly
        # through, since only readonly denies mutations.
        return "destroy"

    if sc == "vm.power":
        # Go accepts -off, --off, -off=true and -off=1 for the same boolean
        # flag (see flag_names), and a flag that is still $EXPANDED could
        # turn out to be any of them
        flags = flag_names(args)
        cls = ("destroy" if (flags & POWER_DESTROY_FLAGS
                             or any(c in a for a in args for c in "$`"))
               else "mutate")
    elif sc in DESTROY_EXACT or sc.rsplit(".", 1)[-1] in DESTROY_SUFFIXES:
        cls = "destroy"
    elif sc in READ_EXACT or sc.endswith(".info") or sc.endswith(".ls"):
        cls = "read"
        mutating = READ_MUTATE_FLAGS.get(sc)
        if mutating and (mutating & flag_names(args)
                         or any(c in a for a in args for c in "$`")):
            # Any argument the shell has not finished with escalates too —
            # the same rule vm.power uses, because `OPTS=-ack; govc alarms
            # $OPTS /DC1` acknowledges alarms just as surely as spelling the
            # flag out. The cost is that a path passed through a variable
            # (`govc alarms "$dc"` in a loop) is denied at readonly, and
            # that cost is worth nothing to avoid: triggered alarms are
            # propagated up the inventory hierarchy and PATH already
            # defaults to `/`, so a bare `govc alarms` returns every
            # triggered alarm in the environment. Use the bare form for
            # reporting and the question never comes up.
            cls = "mutate"
    else:
        cls = "mutate"  # unknown never passes as read — fail closed

    if cls == "destroy" and sc in allow:
        cls = "mutate"
    return cls


def strip_comments(cmd):
    """Drop unquoted # comments — the shell never runs them, so neither the
    denials nor the allowances should depend on what they mention."""
    out, quote = [], None
    for line in cmd.splitlines(keepends=True):
        cut = None
        for i, ch in enumerate(line):
            if quote:
                if ch == quote:
                    quote = None
            elif ch in "'\"":
                quote = ch
            elif ch == "#" and (i == 0 or line[i - 1] in " \t"):
                cut = i
                break
        out.append(line[:cut] + "\n" if cut is not None else line)
    return "".join(out)


def segments(cmd):
    """Split a command into pipeline/list segments, tokenised."""
    for seg in re.split(r"[|;&\n]|&&|\|\|", strip_comments(cmd)):
        try:
            toks = shlex.split(seg)
        except ValueError:
            toks = seg.split()
        if toks:
            yield toks


def resolve_targets(cmd, cwd=None):
    """Yield (segment_tokens, absolute paths those tokens name).

    `cd` inside the command is followed, so `cd ~/.config/govc-guard && echo
    x > policy` resolves `policy` to the file it will really overwrite.
    """
    here = cwd or os.getcwd()
    for toks in segments(cmd):
        if toks[0] == "cd" and len(toks) > 1:
            here = os.path.normpath(os.path.join(
                here, os.path.expanduser(os.path.expandvars(toks[1]))))
            continue
        paths = []
        for t in toks:
            t = os.path.expanduser(os.path.expandvars(t))
            if t and not t.startswith("-"):
                paths.append(os.path.normpath(os.path.join(here, t)))
        yield toks, paths


def script_paths(cmd, cwd=None):
    """Yield paths the command would *execute*: `bash x.sh`, `./x.sh`,
    `source x.sh`. Not files it merely reads — `cat notes.md` must not be
    judged by what the prose in notes.md happens to mention."""
    for toks, paths in resolve_targets(cmd, cwd):
        head = os.path.basename(toks[0])
        if head in SHELL_RUNNERS or toks[0] == ".":
            for tok, path in zip(toks[1:], paths[1:]):
                if not tok.startswith("-"):
                    yield path
                    break
        elif "/" in toks[0] or toks[0].endswith((".sh", ".bash", ".zsh")):
            yield paths[0]


def read_scripts(cmd, cwd=None, depth=3):
    """(path, text) for each script the command runs, and each script those
    run in turn. A govc call the model wrote into a file with the Write tool
    never appears in the Bash command — but the file is right there to read."""
    seen, queue, out = set(), list(script_paths(cmd, cwd)), []
    while queue and len(out) < MAX_SCRIPTS and depth > 0:
        nxt = []
        for path in queue:
            rp = os.path.realpath(path)
            if rp in seen or len(out) >= MAX_SCRIPTS:
                continue
            seen.add(rp)
            try:
                if os.path.getsize(rp) > MAX_SCRIPT_BYTES:
                    continue
                with open(rp, "rb") as f:
                    raw = f.read(MAX_SCRIPT_BYTES)
            except OSError:
                continue
            if b"govc" not in raw:
                # still follow it: it may exec another script that does
                text = raw.decode("utf-8", "replace")
            else:
                text = raw.decode("utf-8", "replace")
                out.append((path, text))
            nxt += list(script_paths(text, os.path.dirname(rp)))
        queue, depth = nxt, depth - 1
    return out


def extract_invocations(cmd):
    """Yield (subcommand, args) for each govc/govc-safe call in the text."""
    for m in CALL_RE.finditer(cmd):
        tail = cmd[m.end():]
        # cut at the next shell separator so one invocation's args don't
        # bleed into the next
        sep = re.search(r"[|;&`)]|&&|\|\|", tail)
        tail, delim = ((tail[:sep.start()], sep.group(0)) if sep
                       else (tail, ""))
        try:
            toks = shlex.split(tail)
        except ValueError:
            toks = tail.split()
        if delim == "`":
            # The cut landed on a command substitution inside this
            # invocation's own arguments — `govc alarms `echo -ack` /DC1`.
            # Dropping it would hand classify() a flagless `alarms` and call
            # it a read, so pass the tick along as an argument and let the
            # unresolved-argument checks see it. `$(...)` needs no such help:
            # that cut lands on the `)`, which leaves the `$(` in the tokens.
            toks.append("`")
        if not toks:
            yield ("", [])
            continue
        yield (toks[0], toks[1:])


# ------------------------------------------------------------------ hook --

def out(decision, reason):
    json.dump({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": reason,
    }}, sys.stdout)
    sys.exit(0)


def guards_itself(cmd, cwd=None):
    """True if the command writes to the policy file or to this script."""
    for toks, paths in resolve_targets(cmd, cwd):
        text = " ".join(toks)
        if not (WRITES.search(text) or INLINE_PROG.search(text)):
            continue
        if any(os.path.realpath(p) in GUARD_FILES for p in paths):
            return True
        # a path quoted inside an inline program is one token, not a path
        if any(g in text for g in GUARD_FILES):
            return True
    return False


def scan(text, tier, extra_deny, allow, prefix, origin=""):
    """Judge one piece of shell text -> (decision, reason) or None."""
    where = f" (in {origin})" if origin else ""
    worst = None  # deny > ask > allow
    for sub, args in extract_invocations(strip_comments(text)):
        sc = sub.lower()

        if sc == "env" and not (args and all(
                ENV_VAR_RE.match(a) and not ENV_SENSITIVE.search(a)
                for a in args)):
            return ("deny", prefix + f"`govc env`{where} prints "
                    "GOVC_PASSWORD in cleartext under every output flag "
                    "(-json, -dump, -x). Name the specific non-secret "
                    "variable you need instead, e.g. `govc env GOVC_URL`.")

        if sc in extra_deny:
            return ("deny", prefix + f"`{sc}`{where} is denied by the local "
                    f"policy file. Ask the operator to change {POLICY_PATH} "
                    "if this is needed.")

        cls = classify(sc, args, allow)

        if cls == "read":
            continue
        if tier == "readonly":
            return ("deny", prefix + f"`govc {sc}`{where} is {cls}-class and "
                    "this environment is locked to read-only. Answer with "
                    "read-only commands (*.info, find, collect, events, "
                    "metric.sample). If a change is truly required, the "
                    "operator must raise the tier in the policy file.")
        if cls == "destroy":
            if tier == "standard":
                return ("deny", prefix + f"`govc {sc}`{where} is "
                        "destroy-class and the policy tier is `standard`. "
                        "This is a hard stop, not a confirmation prompt. "
                        "Tell the user what you wanted to run and why; only "
                        "the operator can raise the tier to `full`.")
            worst = ("ask", prefix + f"`govc {sc}`{where} is destroy-class. "
                     "Confirm the exact objects affected before approving.")
    return worst


def decide(cmd, tier, extra_deny, allow, note, cwd=None):
    """Pure decision function -> (decision, reason) or None (no opinion)."""
    prefix = f"[govc-policy tier={tier}] "
    if note:
        prefix += note + ". "

    # The guard protects itself before it protects vSphere: a command that
    # rewrites the policy file or this script would turn every check below
    # into a no-op, so it is refused at every tier.
    if guards_itself(cmd, cwd):
        return ("deny", prefix + "this command writes to the govc-guard "
                "policy file or to the policy hook itself. The tier is the "
                "operator's to set, not the agent's — ask them to edit "
                f"{POLICY_PATH} directly.")

    # The command text, plus any script it is about to run: a govc call the
    # model put in a file with the Write tool is not in the command at all.
    worst = None
    for origin, text in [("", cmd)] + read_scripts(cmd, cwd):
        v = scan(text, tier, extra_deny, allow, prefix, origin)
        if v and v[0] == "deny":
            return v
        worst = worst or v
    return worst


def main():
    raw = sys.stdin.read()
    try:
        event = json.loads(raw)
    except json.JSONDecodeError:
        sys.exit(0)
    if event.get("hook_event_name") != "PreToolUse":
        sys.exit(0)
    if event.get("tool_name") != "Bash":
        sys.exit(0)
    cmd = (event.get("tool_input") or {}).get("command", "") or ""

    tier, extra_deny, allow, note = load_policy()
    verdict = decide(cmd, tier, extra_deny, allow, note, event.get("cwd"))
    if verdict:
        out(*verdict)
    sys.exit(0)


# -------------------------------------------------------------- selftest --

def selftest():
    import shutil
    import tempfile

    cases = [
        # cmd, tier, expected (None = allow / no opinion)
        ("ls -la /tmp",                              "readonly", None),
        ("govc about",                               "readonly", None),
        ("govc find / -type m",                      "readonly", None),
        ("govc vm.info -json my-vm",                 "readonly", None),
        ("govc snapshot.tree -vm x",                 "readonly", None),
        # reads that neither end in .info/.ls nor were on the original list
        ("govc vm.ip my-vm",                         "readonly", None),
        ("govc about.cert",                          "readonly", None),
        ("govc role.usage Admin",                    "readonly", None),
        ("govc datastore.download vmx /tmp/local",   "readonly", None),
        ("govc guest.download -vm x /etc/hosts /tmp/h",
                                                     "readonly", None),
        ("govc vm.create -m 4096 new-vm",            "readonly", "deny"),
        ("govc vm.power -on my-vm",                  "readonly", "deny"),
        ("govc vm.create -m 4096 new-vm",            "standard", None),
        ("govc vm.power -on my-vm",                  "standard", None),
        ("govc vm.power -off my-vm",                 "standard", "deny"),
        ("govc vm.power -reset my-vm",               "standard", "deny"),
        # stopping a workload is destroy-class however politely it is asked
        ("govc vm.power -s my-vm",                   "standard", "deny"),
        ("govc vm.power -r my-vm",                   "standard", "deny"),
        ("govc vm.power -s my-vm",                   "full",     "ask"),
        # Go accepts -flag=true for every boolean flag
        ("govc vm.power -off=true my-vm",            "standard", "deny"),
        ("govc vm.power -suspend=true my-vm",        "standard", "deny"),
        ("govc vm.power -reset=TRUE my-vm",          "standard", "deny"),
        ("govc vm.power -on=true my-vm",             "standard", None),
        # ...and Go treats one and two minus signs as the same flag
        ("govc vm.power --off my-vm",                "standard", "deny"),
        ("govc vm.power --off=true my-vm",           "standard", "deny"),
        ("govc vm.power --suspend my-vm",            "standard", "deny"),
        ("govc vm.power --s my-vm",                  "standard", "deny"),
        ("govc vm.power --off my-vm",                "full",     "ask"),
        ("govc vm.power --on my-vm",                 "standard", None),
        ("govc vm.power --on my-vm",                 "readonly", "deny"),
        # a flag that is only known at runtime could be any of them
        ("govc vm.power $FLAG my-vm",                "standard", "deny"),
        # a read verb with a flag that writes: `alarms` lists them,
        # `alarms -ack` acknowledges them
        ("govc alarms",                              "readonly", None),
        ("govc alarms -l /DC1",                      "readonly", None),
        ("govc alarms -json | jq '.[]'",             "readonly", None),
        # a path through a variable could expand to the flag, so it escalates
        # — use the bare `govc alarms` (root, propagated) for reporting
        ('govc alarms "$dc"',                        "readonly", "deny"),
        ("govc alarms $OPTS /DC1",                   "readonly", "deny"),
        ("govc alarms `echo -ack` /DC1",             "readonly", "deny"),
        ('govc alarms "$dc"',                        "standard", None),
        ("govc alarms -ack /DC1",                    "readonly", "deny"),
        ("govc alarms -ack=true /DC1",               "readonly", "deny"),
        ("govc alarms -ack -n alarm.X vm/x",         "readonly", "deny"),
        ("govc alarms --ack /DC1",                   "readonly", "deny"),
        ("govc alarms --ack=true /DC1",              "readonly", "deny"),
        ("govc alarms -$FLAG /DC1",                  "readonly", "deny"),
        # acknowledging is a change, not a destruction — no ask-gate at full
        ("govc alarms -ack /DC1",                    "standard", None),
        ("govc alarms -ack /DC1",                    "full",     None),
        ("govc vm.destroy my-vm",                    "standard", "deny"),
        ("govc snapshot.remove -vm x '*'",           "standard", "deny"),
        ("govc snapshot.revert -vm x",               "standard", "deny"),
        ("govc host.shutdown -host e1",              "standard", "deny"),
        ("govc vm.destroy my-vm",                    "full",     "ask"),
        ("govc vm.power -off my-vm",                 "full",     "ask"),
        ("govc vm.create -m 4096 new-vm",            "full",     None),
        # pipelines: every invocation is checked, worst wins
        ("govc find / -type m | tr '\\n' '\\0' | xargs -0 govc vm.info -json",
                                                     "readonly", None),
        ("govc find / -type m | xargs -0 govc vm.destroy",
                                                     "standard", "deny"),
        ("echo x && govc object.destroy /DC1/vm/x",  "standard", "deny"),
        ("x=$(govc vm.info -json a); govc vm.destroy a",
                                                     "standard", "deny"),
        # unknown subcommand never counts as read
        ("govc some.new.thing",                      "readonly", "deny"),
        ("govc some.new.rm",                         "standard", "deny"),
        # a subcommand we cannot read off the command line is the *most*
        # suspicious case, so it is destroy-class — not mutate. Otherwise
        # every tier above readonly fails open on ordinary shell indirection.
        ("printf 'vm.destroy\\nmy-vm\\n' | xargs govc",
                                                     "standard", "deny"),
        ("printf 'vm.destroy\\nmy-vm\\n' | xargs govc",
                                                     "full",     "ask"),
        ("f(){ govc \"$@\"; }; f vm.destroy my-vm",   "standard", "deny"),
        ("B=/usr/local/bin/govc; $B vm.destroy my-vm",
                                                     "standard", "deny"),
        ("govc $(printf 'vm.des''troy') my-vm",      "standard", "deny"),
        ("govc `echo vm.destroy` my-vm",             "standard", "deny"),
        # ... but a literal token the shell is done with cannot become one:
        # govc just rejects it, so it must not cost more than a mutation
        ("govc -h",                                  "readonly", None),
        ("govc --help",                              "readonly", None),
        ("govc version   # is govc installed?",      "readonly", None),
        ("govc vm.info x # govc vm.destroy y",       "standard", None),
        # a quoted govc still counts — it may be `bash -c "govc ..."` — so it
        # is classified, not skipped; a harmless mention costs one tier
        ("govc vm.info x && echo 'govc done'",       "standard", None),
        ("govc vm.info x && echo 'govc done'",       "readonly", "deny"),
        ("echo '# not a comment' && govc vm.destroy y",
                                                     "standard", "deny"),
        # `govc env` prints GOVC_PASSWORD whatever flags it is given
        ("govc env",                                 "full",     "deny"),
        ("govc env GOVC_PASSWORD",                   "full",     "deny"),
        ("govc env -json",                           "full",     "deny"),
        ("govc env -dump",                           "full",     "deny"),
        ("govc env -x",                              "full",     "deny"),
        ("govc env $VAR",                            "full",     "deny"),
        # naming one non-secret variable is a read
        ("govc env GOVC_URL",                        "full",     None),
        ("govc env GOVC_URL",                        "readonly", None),
        # a path that is not one of the guard's own files is not our business
        ("sed -i s/readonly/full/ /home/someone-else/policy",
                                                     "readonly", None),
        # govc-safe is policed identically
        ("govc-safe vm.destroy VM-0001",             "standard", "deny"),
        ("govc-safe find / -type m",                 "readonly", None),
        # paths and .exe
        ("/usr/local/bin/govc vm.destroy x",         "standard", "deny"),
        ("govc.exe vm.destroy x",                    "standard", "deny"),
        # not govc at all
        ("govcxyz destroy",                          "readonly", None),
        ("echo govc-rehydrate",                      "readonly", None),
    ]
    failed = 0
    for cmd, tier, expected in cases:
        v = decide(cmd, tier, set(), set(), "")
        got = v[0] if v else None
        if got != expected:
            failed += 1
            print(f"FAIL tier={tier:8} expected={expected!r:8} got={got!r:8} "
                  f": {cmd}")
    # policy extras
    v = decide("govc vm.migrate -vm x", "standard", {"vm.migrate"}, set(), "")
    if (v[0] if v else None) != "deny":
        failed += 1; print("FAIL extra deny list not enforced")
    v = decide("govc snapshot.revert -vm x", "standard", set(),
               {"snapshot.revert"}, "")
    if v is not None:
        failed += 1; print("FAIL allow list demotion not applied")

    # self-protection, against the paths this process actually uses
    extra = [
        (f"echo 'tier = full' > {POLICY_PATH}",                    "deny"),
        (f"cd {os.path.dirname(POLICY_PATH)} && echo x >> "
         f"{os.path.basename(POLICY_PATH)}",                       "deny"),
        (f"cp /tmp/mine {__file__}",                               "deny"),
        (f"python3 -c \"open('{POLICY_PATH}','w').write('tier=full')\"",
                                                                   "deny"),
        (f"cat {POLICY_PATH}",                                     None),
        (f"python3 {__file__} --selftest",                         None),
    ]
    # scripts are read through, files that are only read are not
    tmp = tempfile.mkdtemp()
    with open(os.path.join(tmp, "d.sh"), "w") as f:
        f.write("#!/bin/sh\ngovc vm.destroy VM-1\n")
    with open(os.path.join(tmp, "notes.md"), "w") as f:
        f.write("run govc vm.destroy VM-1 by hand\n")
    extra += [
        (f"sh {tmp}/d.sh",                                         "deny"),
        (f"cat {tmp}/notes.md",                                    None),
        (f"sh {tmp}/nonexistent.sh",                               None),
    ]
    for cmd, expected in extra:
        v = decide(cmd, "standard", set(), set(), "")
        got = v[0] if v else None
        if got != expected:
            failed += 1
            print(f"FAIL expected={expected!r:8} got={got!r:8} : {cmd}")
    shutil.rmtree(tmp, ignore_errors=True)

    total = len(cases) + 2 + len(extra)
    print(f"{total - failed}/{total} passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    main()
