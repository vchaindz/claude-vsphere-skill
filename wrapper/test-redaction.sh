#!/usr/bin/env bash
# test-redaction.sh - prove that no real identifier survives govc-safe.
#
# Runs the full permitted verb surface against vcsim, whose inventory has known
# ground-truth names (DC0, DC0_H0_VM0, LocalDS_0, DVS0 ...), concatenates every
# byte the wrapper would hand to the model, and fails if any real identifier,
# IP, MAC or UUID appears.
#
# Usage: ./test-redaction.sh          (starts its own vcsim)
set -u
set -o pipefail
cd "$(dirname "$0")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; [ -n "${VCSIM_PID:-}" ] && kill "$VCSIM_PID" 2>/dev/null' EXIT

export PATH="$HOME/.local/bin:$PATH"
export GOVC_SAFE_MAP="$WORK/map.db"
export GOVC_SAFE_CREDS=/nonexistent          # dev fallback: creds from env
export GOVC_INSECURE=true

command -v vcsim >/dev/null 2>&1 || { echo "[!!] vcsim not on PATH"; exit 1; }
command -v govc  >/dev/null 2>&1 || { echo "[!!] govc not on PATH";  exit 1; }

# Always start a private simulator on its own port. An earlier version reused
# whatever was already listening on the default 8989, so an unrelated vcsim left
# running elsewhere silently supplied different inventory -- the seeding below
# then no-oped and the leak checks passed against data they never inspected.
PORT="${VCSIM_PORT:-8991}"
export GOVC_URL="https://user:pass@127.0.0.1:$PORT/sdk"
echo "[..] starting a private vcsim on 127.0.0.1:$PORT"
vcsim -l "127.0.0.1:$PORT" >"$WORK/vcsim.log" 2>&1 &
VCSIM_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    govc about >/dev/null 2>&1 && break
    sleep 0.5
done
govc about >/dev/null 2>&1 || { echo "[!!] vcsim not ready on $PORT"; exit 1; }

# Seed snapshots with deliberately identifying names. vcsim ships with none, so
# without this the suite never exercised snapshot output at all -- which is
# exactly how snapshot names (not inventory objects, not free-text keys) leaked
# verbatim past both redaction mechanisms.
SNAP_A="before ACME-Corp migration"
SNAP_B="ticket INC-4471 rollback"

# The first VM in inventory order is the one the checks below inspect as
# VM-0001. Rename it, so its datastore folder (which keeps the ORIGINAL name,
# DC0_H0_VM0) no longer matches its display name. That divergence is how a
# renamed VM leaked its old name through vmPathName: the folder name is not in
# the inventory map, which only holds current names. Idempotent, because vcsim
# keeps state between runs.
SEED_VM=/DC0/vm/DC0_H0_VM0
govc vm.info "$SEED_VM" >/dev/null 2>&1 || SEED_VM=/DC0/vm/RENAMED-VM

echo "[..] seeding snapshots with identifying names"
govc snapshot.remove -vm "$SEED_VM" '*' >/dev/null 2>&1
govc snapshot.create -vm "$SEED_VM" "$SNAP_A" >/dev/null 2>&1
govc snapshot.create -vm "$SEED_VM" "$SNAP_B" >/dev/null 2>&1

echo "[..] renaming it so its datastore path diverges from its name"
govc vm.change -vm "$SEED_VM" -name RENAMED-VM >/dev/null 2>&1

OUT="$WORK/all-output.txt"
: >"$OUT"
policy_fail=0

# Must SUCCEED. A non-zero exit means the wrapper is over-refusing, which would
# otherwise look like a pass: no output, therefore no leaks.
run() {
    echo "--- \$ govc-safe $*" >>"$OUT"
    if ! ./govc-safe "$@" >>"$OUT" 2>>"$OUT"; then
        echo "[BROKE] expected to succeed: govc-safe $*"
        policy_fail=1
    fi
}

# Must be REFUSED. Output is still captured, so a refusal that leaks a real
# name in its error text is caught by the scanner below.
refuse() {
    echo "--- \$ govc-safe $* (expect refusal)" >>"$OUT"
    if ./govc-safe "$@" >>"$OUT" 2>>"$OUT"; then
        echo "[HOLE]  expected refusal but it succeeded: govc-safe $*"
        policy_fail=1
    fi
}

echo "[..] exercising permitted verbs (must all succeed)"
run about
run ls /
run ls -l /
run ls /DC-01
run find /
run find / -type m
run find / -type h
run find / -type s
run find / -type n
run find -l /
run find -l -i /
run find / -type m -runtime.powerState poweredOn
run tree /
run vm.info VM-0001
run vm.info -json VM-0001
run vm.info -r VM-0001
run vm.info /DC-01/vm/VM-0001
run host.info -host HOST-01
run host.info -json -host HOST-01
run datastore.info
run datastore.info -json
run datacenter.info
run pool.info /DC-01/host/CLUSTER-01/Resources
run cluster.usage CLUSTER-02
run collect -s VM-0001 summary.runtime.powerState
run metric.ls VM-0001
run events -n 10
run tasks
run alarms
run snapshot.tree -vm VM-0001
run snapshot.tree -vm VM-0001 -f -s -D
run snapshot.tree -vm VM-0001 -f -s -D -i

echo "[..] exercising the policy boundary (must all be refused)"
# NOTE: `rehydrate` is deliberately NOT refused here. It is a legitimate operator
# subcommand; the PreToolUse hook is what stops an agent running it. That is
# covered by test-deployment.sh, which checks the hook denies it.
refuse guest.run -vm VM-0001 uname    # unredactable in-guest output
refuse host.esxcli -host HOST-01
refuse logs
refuse datastore.tail -ds DS-01 x.log
refuse permissions.ls
refuse about.cert
refuse env
refuse vm.info -e VM-0001             # extraConfig / cloud-init secrets
refuse vm.info -trace VM-0001
refuse about -dump                    # bypasses JSON-aware redaction
refuse about -xml
refuse events -n 5 -f                 # unbounded follow
refuse collect -s VM-0001 config.annotation
refuse collect -s VM-0001 config.extraConfig
refuse notaverb
# Snapshot removal must name exactly one snapshot, unambiguously and stably.
refuse snapshot.remove -vm VM-0001 '*'                       # whole tree in one call
refuse snapshot.remove -vm VM-0001 "$SNAP_A"                 # by name
refuse snapshot.remove -vm VM-0001 rollback                  # by partial name
refuse snapshot.remove -vm VM-0001

# Scan only what the wrapper emitted. The "--- $ govc-safe ..." lines are this
# script's own record of what it invoked, and the must-refuse cases pass real
# names in deliberately; grading those would be grading the test, not the code.
SCAN="$WORK/wrapper-output.txt"
grep -v '^--- \$ govc-safe' "$OUT" >"$SCAN"

echo "[..] scanning $(wc -c <"$SCAN") bytes of wrapper output for leaks"

fail=0
report() {  # report <label> <grep-args...>
    local label="$1"; shift
    local hits
    hits=$(grep -oiE "$@" "$SCAN" 2>/dev/null | sort -u | head -8)
    if [ -n "$hits" ]; then
        echo "[LEAK] $label"
        echo "$hits" | sed 's/^/         /'
        fail=1
    else
        echo "[ok]   no $label"
    fi
}

# vcsim ground-truth object names. "Resources", "vm", "host", "network" and
# "datastore" are structural inventory folders and are intentionally preserved.
report "vcsim object names"  'DC0[A-Za-z0-9_-]*|LocalDS[A-Za-z0-9_]*|DVS0[A-Za-z0-9_-]*|DVUplinks[A-Za-z0-9_-]*'
report "snapshot names"      'ACME-Corp|INC-4471|rollback|migration'
# A token glued to trailing text means a name was only PARTIALLY substituted:
# "DC0_H0_VM0" became "CLUSTER-01_VM0" because the cluster name "DC0_H0" is a
# prefix of it. The remnant carries no literal "DC0", so the scan above cannot
# see it. This invariant can: a token is always a whole word.
report "partially substituted names" '\b[A-Z]+-[0-9]+_[A-Za-z0-9]'
report "IPv6 addresses"     '\b(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{1,4}\b'
report "literal 'VM Network'" 'VM Network'
# Octet-validated: ESXi driver version strings such as "lpfc 10.2.309.8" and
# "scsi-megaraid-sas 6.603.55.00" are dotted quads but not addresses (309 > 255).
# The wrapper declines them for the same reason, so the test must agree.
OCTET='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
report "IPv4 addresses"      "\\b($OCTET\\.){3}$OCTET\\b"
report "MAC addresses"       '\b([0-9a-f]{2}:){5}[0-9a-f]{2}\b'
report "UUIDs"               '\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'
report "email addresses"     '\b[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}\b'
report "the vCenter URL"     '127\.0\.0\.1|:8989|/sdk'
# Match a credential VALUE, not the variable name: policy refusal messages
# legitimately mention GOVC_PASSWORD ("'env' is not available: prints
# GOVC_PASSWORD in cleartext").
report "credentials"         'user:pass|GOVC_PASSWORD[[:space:]]*=[[:space:]]*[^[:space:]]'

echo
if [ "$policy_fail" -ne 0 ]; then
    echo "[!!] policy failures above: a command that must succeed failed, or a"
    echo "     command that must be refused went through."
fi

if [ "$fail" -eq 0 ] && [ "$policy_fail" -eq 0 ]; then
    echo "=== PASS: no real identifiers in $(wc -l <"$SCAN") lines, policy intact ==="
    exit 0
fi
[ "$fail" -ne 0 ] && echo "=== FAIL: real identifiers reached the output above ==="
[ "$policy_fail" -ne 0 ] && echo "=== FAIL: allowlist policy is not behaving as specified ==="
echo "    full capture kept at: $WORK/all-output.txt"
trap - EXIT
exit 1
