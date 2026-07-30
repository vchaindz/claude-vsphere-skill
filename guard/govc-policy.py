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
  mutate   everything else (fail-closed default for unknown subcommands)
  destroy  explicit set + suffix heuristic (rm / remove / destroy /
           shutdown / reboot / wipe / unregister), so destructive
           subcommands added in future govc releases are still caught;
           vm.power is classified per flag (-off / -reset / -suspend are
           destroy, -on / -s / -r are mutate)

Honesty note, same as the privacy wrapper: this matches command text. It is
deterministic — the same command always gets the same decision, and the
normal path cannot slip a vm.destroy through — but a deliberately hostile
agent could obfuscate its way around text matching. For a hard boundary use
a least-privilege vCenter role; the two compose (see README).

Policy file: ~/.config/govc-guard/policy  (override: GOVC_GUARD_POLICY set
in the environment that launched Claude Code — env assignments inside the
Bash command itself cannot retarget the hook, which reads its own process
environment).

Format:
    tier = standard
    # optional, space/comma separated govc subcommands:
    deny  = vm.migrate datastore.upload      # always denied on top of tier
    allow = snapshot.revert                  # demote destroy -> mutate

The installer also writes a settings.json deny rule so the agent cannot
edit the policy file through file tools.

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
    "about", "version", "ls", "find", "tree", "collect", "object.collect",
    "events", "tasks", "alarms", "logs", "logs.ls",
    "metric.ls", "metric.info", "metric.sample", "metric.interval.info",
    "snapshot.tree", "session.ls", "cluster.usage",
    "datastore.disk.info", "guest.ps", "guest.df", "guest.ls",
    "export.ovf",  # reads vSphere, writes only local files
}

DESTROY_EXACT = {
    "vm.destroy", "object.destroy", "datastore.rm", "snapshot.remove",
    "snapshot.revert", "host.remove", "host.shutdown", "host.reboot",
    "pool.destroy", "device.remove", "disk.rm", "volume.rm",
    "vm.unregister", "library.rm", "vcsa.shutdown.poweroff",
    "vcsa.shutdown.reboot", "vcsa.shutdown.stop",
}

DESTROY_SUFFIXES = ("rm", "remove", "destroy", "shutdown", "reboot",
                    "wipe", "unregister")

# vm.power flags that hard-stop or disrupt a workload
POWER_DESTROY_FLAGS = {"-off", "-reset", "-suspend"}

# `govc env` with no args prints GOVC_PASSWORD in cleartext
ENV_SENSITIVE = re.compile(r"\bGOVC_PASSWORD\b", re.I)

# matches govc, ./govc, /path/govc, govc.exe, AND govc-safe — policy applies
# to the privacy wrapper too, but not to govc-rehydrate (handled elsewhere)
CALL_RE = re.compile(
    r"(?<![\w/.\\-])"
    r"(?:[A-Za-z]:)?"
    r"(?:[\w.\\/-]*[\\/])?"
    r"govc(?:-safe)?(?:\.exe)?"
    r"(?![\w.-])")


def classify(subcommand, args, allow):
    """-> 'read' | 'mutate' | 'destroy'."""
    sc = subcommand.lower()

    if sc == "vm.power":
        cls = "destroy" if (set(a.lower() for a in args)
                            & POWER_DESTROY_FLAGS) else "mutate"
    elif sc in DESTROY_EXACT or sc.rsplit(".", 1)[-1] in DESTROY_SUFFIXES:
        cls = "destroy"
    elif sc in READ_EXACT or sc.endswith(".info") or sc.endswith(".ls"):
        cls = "read"
    else:
        cls = "mutate"  # unknown never passes as read — fail closed

    if cls == "destroy" and sc in allow:
        cls = "mutate"
    return cls


def extract_invocations(cmd):
    """Yield (subcommand, args) for each govc/govc-safe call in the text."""
    for m in CALL_RE.finditer(cmd):
        tail = cmd[m.end():]
        # cut at the next shell separator so one invocation's args don't
        # bleed into the next
        tail = re.split(r"[|;&`)]|&&|\|\|", tail, 1)[0]
        try:
            toks = shlex.split(tail)
        except ValueError:
            toks = tail.split()
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


def decide(cmd, tier, extra_deny, allow, note):
    """Pure decision function -> (decision, reason) or None (no opinion)."""
    if not CALL_RE.search(cmd):
        return None  # not a govc command — no opinion

    prefix = f"[govc-policy tier={tier}] "
    if note:
        prefix += note + ". "

    worst = None  # deny > ask > allow
    for sub, args in extract_invocations(cmd):
        sc = sub.lower()

        if sc == "env" and (not args or any(ENV_SENSITIVE.search(a)
                                            for a in args)):
            return ("deny", prefix + "`govc env` prints GOVC_PASSWORD in "
                    "cleartext. Query a specific non-secret variable "
                    "instead, e.g. `govc env GOVC_URL`.")

        if sc in extra_deny:
            return ("deny", prefix + f"`{sc}` is denied by the local policy "
                    f"file. Ask the operator to change {POLICY_PATH} if this "
                    "is needed.")

        cls = classify(sc, args, allow)

        if cls == "read":
            continue
        if tier == "readonly":
            return ("deny", prefix + f"`govc {sc}` is {cls}-class and this "
                    "environment is locked to read-only. Answer with "
                    "read-only commands (*.info, find, collect, events, "
                    "metric.sample). If a change is truly required, the "
                    "operator must raise the tier in the policy file.")
        if cls == "destroy":
            if tier == "standard":
                return ("deny", prefix + f"`govc {sc}` is destroy-class and "
                        "the policy tier is `standard`. This is a hard stop, "
                        "not a confirmation prompt. Tell the user what you "
                        "wanted to run and why; only the operator can raise "
                        "the tier to `full` in the policy file.")
            worst = ("ask", prefix + f"`govc {sc}` is destroy-class. "
                     "Confirm the exact objects affected before approving.")
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
    verdict = decide(cmd, tier, extra_deny, allow, note)
    if verdict:
        out(*verdict)
    sys.exit(0)


# -------------------------------------------------------------- selftest --

def selftest():
    cases = [
        # cmd, tier, expected (None = allow / no opinion)
        ("ls -la /tmp",                              "readonly", None),
        ("govc about",                               "readonly", None),
        ("govc find / -type m",                      "readonly", None),
        ("govc vm.info -json my-vm",                 "readonly", None),
        ("govc snapshot.tree -vm x",                 "readonly", None),
        ("govc vm.create -m 4096 new-vm",            "readonly", "deny"),
        ("govc vm.power -on my-vm",                  "readonly", "deny"),
        ("govc vm.create -m 4096 new-vm",            "standard", None),
        ("govc vm.power -on my-vm",                  "standard", None),
        ("govc vm.power -s my-vm",                   "standard", None),
        ("govc vm.power -off my-vm",                 "standard", "deny"),
        ("govc vm.power -reset my-vm",               "standard", "deny"),
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
        # bare `govc env` leaks the password at every tier
        ("govc env",                                 "full",     "deny"),
        ("govc env GOVC_PASSWORD",                   "full",     "deny"),
        ("govc env GOVC_URL",                        "full",     None),
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
    total = len(cases) + 2
    print(f"{total - failed}/{total} passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    main()
