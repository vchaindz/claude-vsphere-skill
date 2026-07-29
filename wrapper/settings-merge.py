#!/usr/bin/env python3
"""
settings-merge.py - add or remove the govc-guard hooks in a settings.json.

Editing that file by hand is the step most likely to go wrong, because a real
settings.json is not empty. A live one seen while building this had 14 top-level
keys, five hook events, and a `matcher: "Bash"` group already populated in both
PreToolUse and PostToolUse. Pasting a block over it destroys the lot; appending
blindly leaves two Bash groups that both fire.

So this merges rather than writes:

  * unrelated keys, events and matcher groups are preserved untouched
  * an existing `matcher: "Bash"` group is reused, not duplicated
  * MessageDisplay gets no `matcher` key -- that event does not support one
  * re-running converges instead of accumulating, including after the hook path
    changes, because any command containing "govc-guard" is treated as ours
  * the original is backed up, and a parse error aborts without writing

Usage:
    settings-merge.py --install <settings.json> --hook <path/to/govc-guard.py>
    settings-merge.py --remove  <settings.json>
    settings-merge.py --check   <settings.json>
"""

import argparse
import json
import os
import shutil
import sys
import time

# PreToolUse and PostToolUse are scoped to Bash. MessageDisplay fires for every
# assistant message and rejects a matcher, so its group carries no matcher key.
EVENTS = {
    "PreToolUse": "Bash",
    "PostToolUse": "Bash",
    "MessageDisplay": None,
}

DENY_RULE = "Bash(*GOVC_PASSWORD*)"

# Never add a "Bash(govc:*)" deny rule. Deny rules are evaluated regardless of
# what a hook returns, so it would block the very command the PreToolUse hook
# exists to rewrite. Asserted on the way out, not just documented.
FORBIDDEN_DENY_PREFIX = "Bash(govc:"

OURS = "govc-guard"          # identifies our hook entries across path changes


class Abort(Exception):
    pass


def load(path):
    """Read settings.json, tolerating absent/empty, refusing malformed."""
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return {}
    try:
        with open(path) as fh:
            data = json.load(fh)
    except ValueError as e:
        raise Abort("%s is not valid JSON (%s).\n"
                    "Refusing to touch it -- fix or move it, then re-run." % (path, e))
    if not isinstance(data, dict):
        raise Abort("%s does not contain a JSON object at the top level." % path)
    hooks = data.get("hooks")
    if hooks is not None and not isinstance(hooks, dict):
        raise Abort("%s has a 'hooks' key that is %s, not an object. "
                    "Refusing to guess." % (path, type(hooks).__name__))
    return data


def is_ours(entry):
    return isinstance(entry, dict) and OURS in str(entry.get("command", ""))


def find_group(groups, matcher):
    """The group for this matcher, or None.

    Matches the matcher exactly: a user's `Write|Edit|MultiEdit` or `Edit|Write`
    group must not be mistaken for the Bash one, and position is not a clue --
    in the file that motivated this, Bash was first in one event and third in
    another.
    """
    for g in groups:
        if not isinstance(g, dict):
            continue
        if matcher is None:
            if "matcher" not in g:
                return g
        elif g.get("matcher") == matcher:
            return g
    return None


def install(data, hook_cmd):
    changes = []
    hooks = data.setdefault("hooks", {})

    for event, matcher in EVENTS.items():
        groups = hooks.setdefault(event, [])
        if not isinstance(groups, list):
            raise Abort("hooks.%s is %s, not a list. Refusing to guess."
                        % (event, type(groups).__name__))

        group = find_group(groups, matcher)
        if group is None:
            group = {"hooks": []} if matcher is None else {"matcher": matcher, "hooks": []}
            groups.append(group)
            changes.append("%s: created %s group" %
                           (event, "matcher-less" if matcher is None else repr(matcher)))

        entries = group.setdefault("hooks", [])
        if not isinstance(entries, list):
            raise Abort("hooks.%s[].hooks is not a list." % event)

        mine = [e for e in entries if is_ours(e)]
        if not mine:
            entries.append({"type": "command", "command": hook_cmd})
            changes.append("%s: added hook" % event)
        else:
            # Converge on one entry at the current path, however many stale ones
            # a previous run at a different BIN_DIR left behind.
            for extra in mine[1:]:
                entries.remove(extra)
                changes.append("%s: removed duplicate hook" % event)
            if mine[0].get("command") != hook_cmd:
                old = mine[0].get("command")
                mine[0]["command"] = hook_cmd
                mine[0]["type"] = "command"
                changes.append("%s: updated path (was %s)" % (event, old))

    perms = data.setdefault("permissions", {})
    deny = perms.setdefault("deny", [])
    if not isinstance(deny, list):
        raise Abort("permissions.deny is not a list.")
    if DENY_RULE not in deny:
        deny.append(DENY_RULE)
        changes.append("permissions.deny: added %s" % DENY_RULE)

    bad = [r for r in deny if isinstance(r, str) and r.startswith(FORBIDDEN_DENY_PREFIX)]
    if bad:
        raise Abort(
            "permissions.deny contains %s. Deny rules are evaluated regardless of\n"
            "what a hook returns, so this blocks the very govc command the\n"
            "PreToolUse hook rewrites. Remove it and re-run." % bad[0])

    return changes


def remove(data):
    changes = []
    hooks = data.get("hooks")
    if isinstance(hooks, dict):
        for event in list(EVENTS):
            groups = hooks.get(event)
            if not isinstance(groups, list):
                continue
            for group in list(groups):
                entries = group.get("hooks") if isinstance(group, dict) else None
                if not isinstance(entries, list):
                    continue
                for e in [x for x in entries if is_ours(x)]:
                    entries.remove(e)
                    changes.append("%s: removed hook" % event)
                # Prune only what we emptied; leave a user's empty group alone.
                if not entries and group in groups and set(group) <= {"matcher", "hooks"}:
                    groups.remove(group)
            if not groups:
                del hooks[event]
        if not hooks:
            del data["hooks"]

    perms = data.get("permissions")
    if isinstance(perms, dict) and isinstance(perms.get("deny"), list):
        if DENY_RULE in perms["deny"]:
            perms["deny"].remove(DENY_RULE)
            changes.append("permissions.deny: removed %s" % DENY_RULE)
        if not perms["deny"]:
            del perms["deny"]
        if not perms:
            del data["permissions"]
    return changes


def check(data):
    """Report whether our hooks are wired, and where they point."""
    found = {}
    hooks = data.get("hooks") or {}
    for event in EVENTS:
        for group in hooks.get(event) or []:
            for e in (group.get("hooks") or []) if isinstance(group, dict) else []:
                if is_ours(e):
                    found[event] = e.get("command")
    return found


def write(path, data):
    parent = os.path.dirname(os.path.abspath(path))
    if parent:
        os.makedirs(parent, exist_ok=True)
    backup = None
    if os.path.exists(path) and os.path.getsize(path) > 0:
        backup = "%s.bak.%s" % (path, time.strftime("%Y%m%d-%H%M%S"))
        shutil.copy2(path, backup)
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, path)        # atomic: never leave a half-written settings file
    return backup


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--install", metavar="SETTINGS")
    g.add_argument("--remove", metavar="SETTINGS")
    g.add_argument("--check", metavar="SETTINGS")
    ap.add_argument("--hook", help="absolute path to govc-guard.py (with --install)")
    args = ap.parse_args()

    path = args.install or args.remove or args.check
    try:
        data = load(path)

        if args.check:
            found = check(data)
            for event in EVENTS:
                print("  %-15s %s" % (event, found.get(event, "NOT WIRED")))
            return 0 if len(found) == len(EVENTS) else 1

        if args.install:
            if not args.hook:
                raise Abort("--install needs --hook <path to govc-guard.py>")
            hook = os.path.abspath(os.path.expanduser(args.hook))
            if not os.path.exists(hook):
                raise Abort("hook not found: %s" % hook)
            changes = install(data, hook)
        else:
            changes = remove(data)

        if not changes:
            print("  settings already correct - nothing to change")
            return 0

        backup = write(path, data)
        for c in changes:
            print("  %s" % c)
        print("  wrote %s%s" % (path, " (backup: %s)" % backup if backup else ""))
        return 0

    except Abort as e:
        sys.stderr.write("settings-merge: %s\n" % e)
        return 2


if __name__ == "__main__":
    sys.exit(main())
