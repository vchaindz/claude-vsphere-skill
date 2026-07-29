#!/usr/bin/env bash
# test-deployment.sh - check that YOUR setup is correct.
#
# test-redaction.sh proves the redaction engine works. This checks the things
# that engine test cannot: that govc-safe is actually installed, that the
# credentials are in the wrapper's file rather than your shell environment, and
# that the policy still refuses what it should when invoked normally.
#
# Run as the user Claude Code runs as, after setup.sh.
set -u
cd "$(dirname "$0")"

CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/govc-safe"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/govc-safe"
CREDS="$CFG_DIR/creds"
GS="${GOVC_SAFE:-govc-safe}"

pass=0; fail=0; warn=0
ok()   { echo "[PASS] $1"; pass=$((pass+1)); }
bad()  { echo "[FAIL] $1"; fail=$((fail+1)); }
note() { echo "[WARN] $1"; warn=$((warn+1)); }
must_fail() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d (succeeded, expected refusal)"; else ok "$d"; fi; }
must_work() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d (failed, expected success)"; fi; }

echo "--- installed ---"
command -v "$GS" >/dev/null 2>&1 && ok "govc-safe on PATH ($(command -v "$GS"))" || bad "govc-safe not on PATH"
command -v govc  >/dev/null 2>&1 && ok "govc on PATH" || bad "govc not on PATH"
[ -d "$HOME/.claude/skills/govc-private" ] && ok "govc-private skill installed" \
    || note "govc-private skill not in ~/.claude/skills"

echo
echo "--- credentials are in the wrapper, not your environment ---"
# This is the point of the whole setup: Claude Code inherits the environment it
# is launched from, so a GOVC_* export there hands the agent working creds and
# the wrapper becomes optional.
if env | grep -q "^GOVC_"; then
    bad "your environment exports GOVC_* - the agent inherits working credentials"
else
    ok "no GOVC_* exported - the agent inherits nothing"
fi
[ -f "$CREDS" ] && ok "creds file present" || bad "no creds file at $CREDS"
m=$(stat -c "%a" "$CREDS" 2>/dev/null || echo "?")
[ "$m" = "600" ] && ok "creds mode 0600" || bad "creds mode $m (want 0600)"
m=$(stat -c "%a" "$DATA_DIR" 2>/dev/null || echo "?")
[ "$m" = "700" ] && ok "token map dir mode 0700" || note "token map dir mode $m (want 0700)"
must_fail "plain govc cannot authenticate from a clean env" \
    env -u GOVC_URL -u GOVC_USERNAME -u GOVC_PASSWORD -u GOVC_INSECURE govc about

echo
echo "--- the wrapper works ---"
# Reachability first. Without this, an unreachable or misconfigured vCenter
# surfaces as three separate failures that all read like wrapper bugs.
if ! "$GS" about >/dev/null 2>&1; then
    note "vCenter is not reachable with the configured credentials - skipping"
    note "the functional checks. Verify GOVC_URL in $CREDS,"
    note "or start a simulator: vcsim -l 127.0.0.1:8989"
    SKIP_FUNCTIONAL=1
fi

if [ "${SKIP_FUNCTIONAL:-0}" = "1" ]; then
    :
elif out=$("$GS" find / -type m 2>&1); then
    echo "$out" | grep -qE "^/[A-Z]+-[0-9]+/" && ok "returns tokenised inventory" \
        || bad "ran but output is not tokenised: $(echo "$out" | head -1)"
else
    bad "wrapper failed: $(echo "$out" | head -1)"
fi
if [ "${SKIP_FUNCTIONAL:-0}" != "1" ]; then
    must_work "about"                "$GS" about
    must_work "datastore.info -json" "$GS" datastore.info -json
fi

echo
echo "--- policy ---"
# These are refused before any vCenter call, so they hold even offline.
must_fail "guest.run refused"               "$GS" guest.run -vm VM-0001 id
must_fail "host.esxcli refused"             "$GS" host.esxcli -host HOST-01
must_fail "-trace refused"                  "$GS" vm.info -trace VM-0001
must_fail "annotation via collect refused"  "$GS" collect -s VM-0001 config.annotation
must_fail "snapshot.remove '*' refused"     "$GS" snapshot.remove -vm VM-0001 "*"
must_fail "unknown verb refused"            "$GS" notaverb

echo
echo "--- the hook routes govc through the wrapper ---"
HOOK="$(dirname "$(command -v "$GS" 2>/dev/null || echo .)")/govc-guard.py"
if [ -x "$HOOK" ]; then
    # Plain `govc` is rewritten, not denied: that is what lets the stock govc
    # skill work unchanged.
    r=$(printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"govc find / -type m"}}' \
        | "$HOOK" 2>/dev/null)
    echo "$r" | grep -q '"command": *"govc-safe find / -type m"' \
        && ok "hook rewrites govc -> govc-safe" \
        || bad "hook did not rewrite plain govc"
    # rehydrate is a legitimate operator subcommand of govc-safe, so the wrapper
    # itself allows it. The hook is the only thing keeping an agent off it.
    r=$(printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"govc-safe rehydrate r.tsv"}}' \
        | "$HOOK" 2>/dev/null)
    echo "$r" | grep -q '"permissionDecision": *"deny"' && ok "hook denies rehydrate" \
        || bad "hook did not deny rehydrate"
    # MessageDisplay is what lets you read cleartext while the model sees tokens.
    r=$(printf '{"hook_event_name":"MessageDisplay","delta":"check VM-0001 now"}' \
        | "$HOOK" 2>/dev/null)
    if echo "$r" | grep -q '"displayContent"'; then
        if echo "$r" | grep -q 'VM-0001'; then
            note "MessageDisplay ran but VM-0001 is not in the token map yet"
        else
            ok "MessageDisplay rehydrates tokens for your screen"
        fi
    else
        note "MessageDisplay produced no rewrite (empty token map?)"
    fi
    grep -rqs "govc-guard" "$HOME/.claude/settings.json" .claude/settings.json 2>/dev/null \
        && ok "hook referenced in a settings.json" \
        || note "hook not wired into settings.json yet - add the block setup.sh printed"
else
    note "hook not installed next to govc-safe"
fi

echo
echo "=== $pass passed, $fail failed, $warn warning(s) ==="
[ "$fail" -eq 0 ] || exit 1
exit 0
