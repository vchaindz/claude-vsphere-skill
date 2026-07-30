#!/bin/sh
# guard/setup.sh — install the deterministic policy hook.
#
#   ./setup.sh [readonly|standard|full]   default: standard
#   ./setup.sh --no-settings [tier]       install only, wire nothing
#   ./setup.sh --project [tier]           wire ./.claude/settings.json
#
# What it does:
#   1. copies govc-policy.py to ~/.local/bin (0755)
#   2. writes ~/.config/govc-guard/policy with the chosen tier (0644) —
#      only if the file does not already exist (never overwrites a policy)
#   3. merges a PreToolUse hook entry and a deny rule protecting the policy
#      file into settings.json (backup taken first; merge is additive and
#      idempotent — re-running converges)
#
# Coexists with the privacy wrapper: both hooks can be wired; this one
# decides *whether* a command may run, the wrapper decides *what the model
# sees*. Order does not matter — a deny from either stands.

set -eu

TIER=standard
SETTINGS="$HOME/.claude/settings.json"
WIRE=yes

for arg in "$@"; do
  case "$arg" in
    readonly|standard|full) TIER=$arg ;;
    --no-settings) WIRE=no ;;
    --project) SETTINGS=./.claude/settings.json ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

BIN="$HOME/.local/bin"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/govc-guard"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

mkdir -p "$BIN" "$CONF"
install -m 0755 "$HERE/govc-policy.py" "$BIN/govc-policy.py"
echo "installed $BIN/govc-policy.py"

if [ -f "$CONF/policy" ]; then
  echo "kept existing policy: $CONF/policy ($(grep -E '^\s*tier' "$CONF/policy" || echo 'no tier line!'))"
else
  cat > "$CONF/policy" <<EOF
# govc-guard policy — the deterministic security layer reads this file.
# The agent is blocked from editing it (settings.json deny rule).
#
#   readonly  read-class commands only
#   standard  read + mutate; destroy-class commands are hard-denied
#   full      everything; destroy-class commands always require your
#             confirmation in the UI
tier = $TIER

# Optional extras, space or comma separated govc subcommands:
# deny  = vm.migrate datastore.upload    # always denied on top of the tier
# allow = snapshot.revert                # treat as mutate instead of destroy
EOF
  echo "wrote policy: $CONF/policy (tier = $TIER)"
fi

[ "$WIRE" = no ] && { echo "--no-settings: not touching $SETTINGS"; exit 0; }

mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"

POLICY_FILE="$CONF/policy" HOOK_CMD="$BIN/govc-policy.py" SETTINGS_FILE="$SETTINGS" python3 - <<'PYEOF'
import json, os, sys

path = os.environ["SETTINGS_FILE"]
hook_cmd = os.environ["HOOK_CMD"]
policy = os.environ["POLICY_FILE"]

try:
    with open(path, encoding="utf-8") as f:
        s = json.load(f)
except Exception as e:
    sys.exit(f"refusing to touch malformed settings file: {e}")

# deny rules: agent must not edit or read-modify the policy file
perms = s.setdefault("permissions", {})
deny = perms.setdefault("deny", [])
for rule in (f"Edit({policy})", f"Write({policy})", f"Bash(* {policy}*)"):
    if rule not in deny:
        deny.append(rule)

# PreToolUse hook, reuse an existing Bash matcher group if present
hooks = s.setdefault("hooks", {})
pre = hooks.setdefault("PreToolUse", [])
entry = {"type": "command", "command": hook_cmd}
for grp in pre:
    if grp.get("matcher") == "Bash":
        if entry not in grp.setdefault("hooks", []):
            grp["hooks"].append(entry)
        break
else:
    pre.append({"matcher": "Bash", "hooks": [entry]})

with open(path, "w", encoding="utf-8") as f:
    json.dump(s, f, indent=2)
print(f"wired hook + policy-file deny rules into {path}")
PYEOF

echo "done — restart Claude Code for the hook to take effect"
echo "verify with: ./test-policy.sh"
