#!/bin/sh
# guard/test-policy.sh — verify the deterministic layer end to end.
#
# Part 1: classifier unit tests (embedded in the hook, no install needed)
# Part 2: hook-protocol tests — feeds real PreToolUse JSON events through
#         the script and checks the decision, including fail-closed
#         behaviour when the policy file is missing or malformed
# Part 3: deployment checks (only if settings.json is wired)

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK="$HERE/govc-policy.py"
FAILS=0

fail() { echo "FAIL: $1"; FAILS=$((FAILS+1)); }
pass() { echo "  ok: $1"; }

echo "== 1. classifier self-test =="
python3 "$HOOK" --selftest || fail "classifier self-test"

echo "== 2. hook protocol =="
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

event() {  # $1 = command
  printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":%s}}' \
    "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")"
}

run() {  # $1 policy-file  $2 command  -> prints decision or "allow"
  event "$2" | GOVC_GUARD_POLICY="$1" python3 "$HOOK" | \
    python3 -c 'import json,sys
raw = sys.stdin.read()
print(json.loads(raw)["hookSpecificOutput"]["permissionDecision"] if raw.strip() else "allow")'
}

# missing policy file -> fail closed to readonly
[ "$(run "$TMP/nonexistent" 'govc vm.create -m 4096 x')" = deny ] \
  && pass "missing policy fails closed (mutate denied)" \
  || fail "missing policy did not fail closed"

[ "$(run "$TMP/nonexistent" 'govc vm.info x')" = allow ] \
  && pass "missing policy still allows read" \
  || fail "read denied under fail-closed readonly"

# malformed policy -> fail closed
echo "tier = quantum" > "$TMP/bad"
[ "$(run "$TMP/bad" 'govc vm.create x')" = deny ] \
  && pass "invalid tier fails closed" \
  || fail "invalid tier did not fail closed"

# each tier
echo "tier = readonly" > "$TMP/ro"
echo "tier = standard" > "$TMP/std"
echo "tier = full"     > "$TMP/full"

[ "$(run "$TMP/ro"   'govc vm.power -on x')"   = deny  ] && pass "readonly denies mutate"    || fail "readonly/mutate"
[ "$(run "$TMP/std"  'govc vm.power -on x')"   = allow ] && pass "standard allows mutate"    || fail "standard/mutate"
[ "$(run "$TMP/std"  'govc vm.destroy x')"     = deny  ] && pass "standard denies destroy"   || fail "standard/destroy"
[ "$(run "$TMP/full" 'govc vm.destroy x')"     = ask   ] && pass "full asks on destroy"      || fail "full/destroy should ask"
[ "$(run "$TMP/full" 'govc env')"              = deny  ] && pass "bare govc env denied everywhere" || fail "govc env leak"
[ "$(run "$TMP/std"  'ls -la && cat /etc/os-release')" = allow ] && pass "non-govc untouched" || fail "non-govc command touched"

# extras
printf 'tier = standard\ndeny = vm.migrate\n' > "$TMP/extra"
[ "$(run "$TMP/extra" 'govc vm.migrate -vm x')" = deny ] && pass "extra deny enforced" || fail "extra deny"
printf 'tier = standard\nallow = snapshot.revert\n' > "$TMP/demote"
[ "$(run "$TMP/demote" 'govc snapshot.revert -vm x')" = allow ] && pass "allow demotes destroy" || fail "allow demotion"

echo "== 3. deployment (skipped unless wired) =="
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ] && grep -q "govc-policy.py" "$SETTINGS" 2>/dev/null; then
  HOOK_PATH=$(python3 -c "
import json
s = json.load(open('$SETTINGS'))
for g in s.get('hooks', {}).get('PreToolUse', []):
    for h in g.get('hooks', []):
        if 'govc-policy.py' in h.get('command',''):
            print(h['command']); break
")
  [ -n "$HOOK_PATH" ] && [ -f "$HOOK_PATH" ] \
    && pass "wired hook exists: $HOOK_PATH" \
    || fail "settings.json points at a missing hook file"
  CONF="${XDG_CONFIG_HOME:-$HOME/.config}/govc-guard/policy"
  [ -f "$CONF" ] && pass "policy file present: $CONF ($(grep -E '^\s*tier' "$CONF"))" \
                 || fail "no policy file — hook will fail closed to readonly"
else
  echo "  not wired into $SETTINGS — run guard/setup.sh (skipping)"
fi

echo
[ $FAILS -eq 0 ] && echo "ALL PASSED" || echo "$FAILS FAILURE(S)"
exit $FAILS
