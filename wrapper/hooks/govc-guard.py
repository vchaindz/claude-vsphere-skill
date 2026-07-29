#!/usr/bin/env python3
"""
govc-guard - Claude Code hook for govc-safe.

Handles three events, dispatched on hook_event_name:

  PreToolUse     Rewrites `govc ...` into `govc-safe ...` before it runs, so a
                 skill that documents plain govc needs no changes at all. Also
                 refuses the few commands that would pull real names back into
                 the transcript.

  PostToolUse    Safety net. Rewrites Bash output via updatedToolOutput,
                 scrubbing generic identifier classes (IP, MAC, UUID, email,
                 DOMAIN\\user) from ANY command, not just govc -- so a stray
                 `cat` of a config file does not leak.

  MessageDisplay Rehydrates Claude's replies ON YOUR SCREEN ONLY. Claude writes
                 "VM-0001 is powered on"; you read "ACME-PROD-SQL01 is powered
                 on". This is display-only by design: the transcript and what
                 the model sees keep the tokens, so nothing real is ever sent
                 anywhere. `/verbose` shows the untouched text if you want to
                 confirm what actually left the machine.

That last one is the point of the whole arrangement: the model works in tokens,
you work in cleartext, and no rehydrate command has to be run by hand.

The PostToolUse pass is pattern-only: it does not consult the token map, so it
can redact 10.20.30.41 but not a bare hostname like esx01. It is a backstop for
non-govc commands; the wrapper is what actually anonymises vSphere data.

Install: see wrapper/setup.sh, which prints the settings.json entries.
"""

import ipaddress
import json
import os
import pathlib
import re
import sqlite3
import sys

WRAPPER = "govc-safe"

_DATA = os.environ.get("XDG_DATA_HOME") or os.path.join(
    os.path.expanduser("~"), ".local", "share")
MAP_DB = os.environ.get("GOVC_SAFE_MAP", os.path.join(_DATA, "govc-safe", "map.db"))

# Everything below matches raw command text, not parsed shell words, so it is
# defeatable by quoting tricks (g'ovc', $(printf govc), base64). That is
# accepted: nothing here is a security boundary. govc-safe runs as the same user
# as the agent, so an agent that set out to bypass it could. What this does is
# keep the NORMAL path on the wrapper -- which is where leaks actually come
# from. For a real boundary, run the agent as a separate unix user that cannot
# read the credentials file.

# Matches `govc`, `./govc`, `/usr/local/bin/govc`, `command govc` -- but never
# `govc-safe` or `govc-rehydrate`. Rewritten rather than denied, so a skill that
# documents plain `govc` keeps working untouched.
GOVC_CALL_RE = re.compile(
    r"(?<![\w/.\\-])"                 # not mid-word, mid-path or after a dot
    r"(?:[A-Za-z]:)?"                 # optional Windows drive letter
    r"(?:[\w.\\/-]*[\\/])?"           # optional directory prefix, / or \\
    r"govc(?:\.exe)?"                 # the binary, with or without .exe
    r"(?![\w.-])")                    # not govc-safe, govc-rehydrate, govc.foo

# Commands that must never run: they would de-anonymise or expose credentials.
DENY_PATTERNS = [
    (re.compile(r"\bgovc-safe(?:\.exe)?\s+rehydrate\b|"
                r"(?<![\w/.\\-])(?:[A-Za-z]:)?(?:[\w.\\/-]*[\\/])?"
                r"govc-rehydrate(?:\.exe)?(?![\w.-])"),
     "Rehydration maps tokens back to real names and is for the operator, not "
     "for you -- running it would pull every real identifier into this "
     "transcript, defeating the wrapper. Hand over the tokenised report and "
     "tell them to run `govc-safe rehydrate report.tsv` themselves."),

    (re.compile(r"\bGOVC_(?:PASSWORD|USERNAME|URL|GUEST_LOGIN)\b"),
     "Do not read or set GOVC_* variables. Credentials live only in the "
     "wrapper's protected creds file."),

    (re.compile(r"\bcat\b[^|;&]*\bcreds\b|govc-safe/creds"),
     "The credentials file must not be read. Use the wrapper, which reads it "
     "for you and never prints it."),
]

IP4 = re.compile(r"\b(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}"
                 r"(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\b")
IP6 = re.compile(r"(?<![0-9A-Za-z:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}"
                 r"(?:%[0-9A-Za-z]+)?(?![0-9A-Za-z:])")
MAC = re.compile(r"\b(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b")
UUID = re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                  r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")
EMAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
WINUSER = re.compile(r"\b[A-Za-z0-9_-]+\\[A-Za-z0-9._-]+")

# Already-tokenised text must be left alone.
TOKEN = re.compile(r"\b[A-Z]+-\d+\b")


def deny(reason):
    json.dump({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}, sys.stdout)
    sys.exit(0)


def handle_pre(tool_name, tool_input):
    if tool_name != "Bash":
        sys.exit(0)
    cmd = tool_input.get("command", "") or ""

    for pat, reason in DENY_PATTERNS:
        if pat.search(cmd):
            deny(reason.format(w=WRAPPER))

    # Transparently redirect govc through the anonymising wrapper. The skill can
    # go on documenting plain `govc`; every invocation in the command -- both
    # sides of a pipeline included -- is rewritten before it runs.
    if GOVC_CALL_RE.search(cmd):
        rewritten = GOVC_CALL_RE.sub(WRAPPER, cmd)
        new_input = dict(tool_input)
        new_input["command"] = rewritten
        json.dump({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "updatedInput": new_input,
            "additionalContext":
                "govc was routed through %s, which returns pseudonymised "
                "identifiers (VM-0001, HOST-01). Those tokens are stable and can "
                "be passed straight back in. The operator sees the real names on "
                "their screen." % WRAPPER,
        }}, sys.stdout)
        sys.exit(0)

    sys.exit(0)


def scrub(text):
    if not text:
        return text, 0
    n = [0]

    def sub(pattern, label, s):
        def repl(m):
            if TOKEN.search(m.group(0)):
                return m.group(0)
            n[0] += 1
            return "[redacted-%s]" % label
        return pattern.sub(repl, s)

    text = sub(UUID, "uuid", text)
    # MAC before IPv6: a MAC is colon-separated hex and would otherwise be
    # offered to the IPv6 matcher.
    text = sub(MAC, "mac", text)
    text = sub(EMAIL, "user", text)
    text = sub(WINUSER, "user", text)

    def ip6_repl(m):
        try:
            ipaddress.ip_address(m.group(0).split("%")[0])
        except ValueError:
            return m.group(0)      # a timestamp or version, not an address
        n[0] += 1
        return "[redacted-ip6]"
    text = IP6.sub(ip6_repl, text)

    text = sub(IP4, "ip", text)
    return text, n[0]


def handle_post(tool_name, tool_response):
    if tool_name != "Bash" or not isinstance(tool_response, dict):
        sys.exit(0)
    out, n1 = scrub(tool_response.get("stdout", ""))
    err, n2 = scrub(tool_response.get("stderr", ""))
    if n1 + n2 == 0:
        sys.exit(0)
    json.dump({"hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "updatedToolOutput": {
            "stdout": out,
            "stderr": err,
            "interrupted": bool(tool_response.get("interrupted", False)),
            "isImage": bool(tool_response.get("isImage", False)),
        },
        "additionalContext":
            "govc-guard redacted %d identifier(s) from this output. If you "
            "need to reference those objects, use govc-safe, which returns "
            "stable tokens instead of placeholders." % (n1 + n2),
    }}, sys.stdout)
    sys.exit(0)


def handle_display(ev):
    """Show the operator real names while the model keeps the tokens.

    Display-only: Claude Code renders this in place of the streamed text, but
    the transcript and the model's context keep the original, so nothing real
    is transmitted. Fires per batch of streamed lines, so it must be quick --
    we touch SQLite only when a token is actually present, and look up just the
    tokens in this batch.
    """
    text = ev.get("delta") or ""
    found = set(TOKEN.findall(text))
    if not found or not os.path.exists(MAP_DB):
        sys.exit(0)
    try:
        # as_uri() rather than %-formatting: a Windows path is backslashed and
        # a username with a space or a '#' silently breaks URI parsing -- and
        # the except below would swallow it, leaving rehydration mysteriously
        # dead.
        uri = pathlib.Path(MAP_DB).absolute().as_uri() + "?mode=ro"
        db = sqlite3.connect(uri, uri=True, timeout=2)
        # Prefer the display name; fall back to any other kind (IP, MAC, ...).
        # '_path'/'_moref' exist only for argument resolution and would splice a
        # full inventory path into the middle of an already-pathed token.
        q = ",".join("?" * len(found))
        rows = db.execute(
            "SELECT token, real, kind FROM tok WHERE token IN (%s) "
            "AND kind NOT IN ('_path','_moref')" % q, tuple(found)).fetchall()
    except (sqlite3.Error, ValueError, OSError):
        sys.exit(0)                      # fail open: original text is shown
    best = {}
    for token, real, kind in rows:
        if kind == "_name" or token not in best:
            best[token] = real
    if not best:
        sys.exit(0)
    json.dump({"hookSpecificOutput": {
        "hookEventName": "MessageDisplay",
        "displayContent": TOKEN.sub(lambda m: best.get(m.group(0), m.group(0)), text),
    }}, sys.stdout)
    sys.exit(0)


def main():
    try:
        ev = json.load(sys.stdin)
    except (ValueError, OSError):
        sys.exit(0)          # never break the session on malformed input
    name = ev.get("hook_event_name")
    if name == "PreToolUse":
        handle_pre(ev.get("tool_name"), ev.get("tool_input") or {})
    elif name == "PostToolUse":
        handle_post(ev.get("tool_name"), ev.get("tool_response") or {})
    elif name == "MessageDisplay":
        handle_display(ev)
    sys.exit(0)


if __name__ == "__main__":
    main()
