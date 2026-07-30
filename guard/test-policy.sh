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
[ "$(run "$TMP/full" 'govc env -json')"        = deny  ] && pass "govc env -json denied too"   || fail "govc env -json leak"
[ "$(run "$TMP/ro"   'govc env GOVC_URL')"     = allow ] && pass "govc env NAME still allowed" || fail "govc env NAME"
[ "$(run "$TMP/std"  'ls -la && cat /etc/os-release')" = allow ] && pass "non-govc untouched" || fail "non-govc command touched"

# indirection: subcommand not literally present after `govc`
[ "$(run "$TMP/std"  'printf "vm.destroy\n" | xargs govc')" = deny ] \
  && pass "xargs-from-stdin denied" || fail "xargs-from-stdin fails open"
[ "$(run "$TMP/full" 'B=/usr/local/bin/govc; $B vm.destroy x')" = ask ] \
  && pass "\$VAR indirection asks at full" || fail "\$VAR indirection fails open"
[ "$(run "$TMP/std"  'govc vm.power -off=true x')" = deny ] \
  && pass "-off=true denied" || fail "-off=true fails open"
[ "$(run "$TMP/std"  'govc vm.power -s x')" = deny ] \
  && pass "guest shutdown is destroy-class" || fail "vm.power -s"

# scripts are read through: a govc call the model wrote with the Write tool
# is never in the Bash command, but the file is right there on disk
printf '#!/bin/sh\ngovc vm.destroy VM-1\n' > "$TMP/destroy.sh"
printf '#!/bin/sh\ngovc vm.info VM-1\n'    > "$TMP/read.sh"
printf '#!/bin/sh\nsh %s/destroy.sh\n' "$TMP" > "$TMP/outer.sh"
printf 'notes: run govc vm.destroy VM-1 by hand\n' > "$TMP/notes.md"
chmod +x "$TMP"/*.sh

[ "$(run "$TMP/std" "sh $TMP/destroy.sh")" = deny ] \
  && pass "script contents are classified" || fail "script bypass still open"
[ "$(run "$TMP/full" "$TMP/destroy.sh")" = ask ] \
  && pass "directly executed script asks at full" || fail "direct script exec"
[ "$(run "$TMP/std" "sh $TMP/outer.sh")" = deny ] \
  && pass "nested script followed" || fail "nested script not followed"
[ "$(run "$TMP/std" "sh $TMP/read.sh")" = allow ] \
  && pass "read-only script allowed" || fail "read-only script denied"
[ "$(run "$TMP/std" "cat $TMP/notes.md")" = allow ] \
  && pass "files that are only read are not judged" || fail "cat was judged"
[ "$(run "$TMP/std" "sh $TMP/missing.sh")" = allow ] \
  && pass "missing script is not an error" || fail "missing script"

# a checkout of this repo stays editable — only the installed paths are the
# guard's own files
[ "$(run "$TMP/std" 'python3 guard/govc-policy.py --selftest')" = allow ] \
  && pass "repo copy is not the installed hook" || fail "repo copy blocked"
[ "$(run "$TMP/std" 'git checkout guard/govc-policy.py')" = allow ] \
  && pass "repo copy is revertable" || fail "git checkout blocked"

# the guard protects its own files at every tier
[ "$(run "$TMP/full" "echo 'tier = full' > $TMP/full")" = deny ] \
  && pass "policy file is write-protected" || fail "policy file writable"
[ "$(run "$TMP/full" "cd $TMP && echo 'allow = vm.destroy' >> full")" = deny ] \
  && pass "cd + relative path still resolves" || fail "cd-relative write allowed"
[ "$(run "$TMP/full" "cat > $HOOK <<EOF
pass
EOF")" = deny ] && pass "hook script is write-protected" || fail "hook script writable"
[ "$(run "$TMP/full" "cat $TMP/full")" = allow ] \
  && pass "reading the policy is fine" || fail "policy unreadable"

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
