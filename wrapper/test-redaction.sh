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

# Name a second VM after a JSON key. Substitution used to run over the
# serialized document with no word boundaries, so this VM rewrote "configStatus"
# to "VM-0002Status" and turned the whole "config" object into "VM-0002" -- valid
# JSON, destroyed meaning. Short names like config, log, name, host and db exist
# in every grown environment, so this is a fixture, not a curiosity.
COLLIDE_VM=/DC0/vm/DC0_H0_VM1
govc vm.info "$COLLIDE_VM" >/dev/null 2>&1 || COLLIDE_VM=/DC0/vm/config
echo "[..] naming a second VM 'config' to collide with govc's own JSON keys"
govc vm.change -vm "$COLLIDE_VM" -name config >/dev/null 2>&1

OUT="$WORK/all-output.txt"
: >"$OUT"
policy_fail=0
shape_fail=0

# The wrapper's token grammar, mirroring TOKEN_RE in govc-safe. Spelled out
# rather than [A-Z]+ so the invariants below do not fire on real strings that
# merely look token-shaped, such as a snapshot named "INC-4471x".
TOK='(DC|VM|HOST|CLUSTER|DS|DSCLUSTER|NET|PG|DVS|POOL|VAPP|FOLDER|SNAP|VMDIR|IP|IP6|MAC|UUID|USER|FQDN|MOREF|OBJ)'

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
# Arity. Every one of these was refused before FLAG_TAKES_VALUE existed, because
# the flag's operand fell through to `positional` and was then graded as a
# property name: "property 'h' is not readable through the wrapper".
run collect -json -type h / name
run collect -json -type m / name runtime.powerState
run collect -json -n 0 VM-0001 name
run collect -json VM-0001 name runtime.powerState summary.quickStats.uptimeSeconds
# Cluster HA/DRS. Only the whole struct resolves -- vCenter answers
# InvalidProperty for every path into it -- so the allowlist has to admit it.
run collect -json CLUSTER-01 configurationEx
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
# Arity must not have become a hole: a flag's operand is skipped, but a real
# property in positional place is still graded, and an unknown flag is still
# refused rather than swallowing the next argument.
refuse collect -json -type m / config.annotation
refuse collect -json -type m / name config.annotation
refuse collect -json -bogus m / name
refuse notaverb
# Flags govc does not define for these verbs -- the object is positional. They used
# to sit in the allowlist, so policy permitted them and govc then rejected them with
# "flag provided but not defined", which reads like a wrapper bug.
refuse vm.info -vm VM-0001
refuse vm.power -off -vm VM-0001
refuse datastore.info -ds DS-01
# Snapshot removal must name exactly one snapshot, unambiguously and stably.
refuse snapshot.remove -vm VM-0001 '*'                       # whole tree in one call
refuse snapshot.remove -vm VM-0001 "$SNAP_A"                 # by name
refuse snapshot.remove -vm VM-0001 rollback                  # by partial name
refuse snapshot.remove -vm VM-0001

# The engine, driven directly against a synthetic document.
#
# The integration pass above cannot grade these two properties: vcsim's fixture
# happens to contain no VALUE in which a short object name sits inside a longer
# identifier, so a wrapper with the boundary bug reintroduced still passes every
# scan below. Both bugs were reported against real inventories, where names like
# config, log, name, host and db are ordinary. Rather than contort the simulator
# fixture into reproducing them, assert on a document that has the shape.
echo "[..] checking the redaction engine against a synthetic document"
if ! python3 - "$PWD/govc-safe" <<'PY'
import importlib.machinery, importlib.util, json, os, sys, tempfile

loader = importlib.machinery.SourceFileLoader("govc_safe", sys.argv[1])
spec = importlib.util.spec_from_loader("govc_safe", loader)
gs = importlib.util.module_from_spec(spec)
loader.exec_module(gs)

db = os.path.join(tempfile.mkdtemp(), "map.db")
tmap = gs.TokenMap(db)
# What learn_inventory would have recorded for a VM that is named after a JSON
# key, plus one ordinary neighbour.
for objtype, moref, name in (("VirtualMachine", "vm-52", "config"),
                             ("VirtualMachine", "vm-53", "DC0_H0_VM0"),
                             ("HostSystem", "host-30", "DC0_H0")):
    tok = tmap.token_for(gs.TYPE_PREFIX[objtype], moref)
    tmap.add_alias("_name", name, tok)
    tmap.add_alias("_moref", moref, tok)
CONFIG_TOK = tmap.db.execute(
    "SELECT token FROM tok WHERE kind='_name' AND real='config'").fetchone()[0]

doc = {"virtualMachines": [{
    "self": {"type": "VirtualMachine", "value": "vm-52"},
    "configStatus": "green",
    "configIssue": None,
    "config": {
        "name": "config",
        "annotation": "owned by ops",
        "guestId": "configuredGuest",
        "files": {"vmPathName": "[LocalDS_0] DC0_H0_VM0/DC0_H0_VM0.vmx"},
    },
    "runtime": {"host": {"type": "HostSystem", "value": "host-30"}},
    "customValue": [{"key": 101, "value": "cost centre 4711"}],
}]}
got = gs.redact_output(json.dumps(doc), tmap)
out = json.loads(got)
vm = out["virtualMachines"][0]

bad = []
def check(cond, msg):
    if not cond:
        bad.append(msg)

# Keys are schema. Substitution must never touch them, whole or partial.
check("configStatus" in vm, "the configStatus key was rewritten")
check("configIssue" in vm, "the configIssue key was rewritten")
check("config" in vm, "the config object key was rewritten")
# Values are data, and a whole-word name in a value must still tokenise.
check(vm["config"]["name"] == CONFIG_TOK,
      "the name VALUE was not tokenised: %r" % vm["config"]["name"])
# ... but only as a whole word. "configuredGuest" is not the VM named "config".
check(vm["config"]["guestId"] == "configuredGuest",
      "a name was substituted inside a longer identifier: %r"
      % vm["config"]["guestId"])
# MoRefs carry the correlation axis and must survive as tokens, not be blanked.
check(vm["self"]["value"] == CONFIG_TOK,
      "the self MoRef did not resolve to the object's own token: %r"
      % vm["self"]["value"])
check(vm["self"]["type"] == "VirtualMachine", "the MoRef type was rewritten")
check(gs.TOKEN_RE.fullmatch(vm["runtime"]["host"]["value"] or ""),
      "the host MoRef was not tokenised: %r" % vm["runtime"]["host"]["value"])
# A "value" with no "type" sibling is still prose.
check(vm["customValue"][0]["value"] == "[redacted: free text]",
      "a free-text value survived: %r" % vm["customValue"][0]["value"])
check(vm["config"]["annotation"] == "[redacted: free text]",
      "an annotation survived")
# The plain-text path shares the alternation and needs the same boundaries.
check(gs.redact_text("configStatus", tmap) == "configStatus",
      "plain text: a name was substituted inside a longer identifier")
check(gs.redact_text("config", tmap) == CONFIG_TOK,
      "plain text: a whole-word name was not tokenised")

# "name" is overloaded in govc's JSON, and the FQDN sweep could not tell the
# readings apart: a property path and a hostname are both dotted identifiers, so
# `collect -json` came back with every property renamed to FQDN-nnn. The values
# survived, which is what made it dangerous rather than merely broken -- the
# document still parsed and still carried the right numbers, it just no longer
# said what any of them were.
collect_doc = [
    {"name": "runtime.connectionState", "op": "assign", "val": "connected"},
    {"name": "name", "op": "assign", "val": "DC0_H0_VM0"},
    {"name": "summary.quickStats.uptime", "op": "assign", "val": 19012128},
]
got = json.loads(gs.redact_output(json.dumps(collect_doc), tmap))
check(got[0]["name"] == "runtime.connectionState",
      "a collect property name was tokenised: %r" % got[0]["name"])
check(got[2]["name"] == "summary.quickStats.uptime",
      "a collect property name was tokenised: %r" % got[2]["name"])
check(got[0]["val"] == "connected", "a property value was mangled: %r" % got[0]["val"])
# The schema exemption is for the NAME slot only. `val` is data, and a real
# object name in it must still be tokenised.
check(gs.TOKEN_RE.fullmatch(got[1]["val"] or ""),
      "an object name in val position was not tokenised: %r" % got[1]["val"])

# Same overload in metric output, where "name" is a counter.
metric_doc = {"sample": [{"value": [
    {"name": "cpu.usage.average", "unit": "percent", "instance": "", "value": [410, 375]}]}]}
got = json.loads(gs.redact_output(json.dumps(metric_doc), tmap))
check(got["sample"][0]["value"][0]["name"] == "cpu.usage.average",
      "a performance counter name was tokenised: %r"
      % got["sample"][0]["value"][0]["name"])

# The mirror image: a name the schema itself marks as operator-written. Cluster
# rules and groups are the only free text reachable through `configurationEx`,
# which the allowlist has to admit whole because vCenter refuses every path into
# it. Both carry `userCreated`, so the rule is structural like the rest.
cluster_doc = [{"name": "configurationEx", "op": "assign", "val": {
    "dasConfig": {"enabled": True, "admissionControlEnabled": True},
    "drsConfig": {"enabled": True, "defaultVmBehavior": "fullyAutomated"},
    "rule": [{"name": "keep ACME-Corp SQL apart", "userCreated": True, "enabled": True}],
    "group": [{"name": "ACME-Corp payroll hosts", "userCreated": True}],
}}]
got = json.loads(gs.redact_output(json.dumps(cluster_doc), tmap))[0]["val"]
check(got["dasConfig"]["enabled"] is True, "an HA boolean was mangled")
check(got["drsConfig"]["defaultVmBehavior"] == "fullyAutomated",
      "a DRS enum was mangled: %r" % got["drsConfig"]["defaultVmBehavior"])
check(got["rule"][0]["name"] == "[redacted: free text]",
      "an operator-written DRS rule name survived: %r" % got["rule"][0]["name"])
check(got["group"][0]["name"] == "[redacted: free text]",
      "an operator-written DRS group name survived: %r" % got["group"][0]["name"])

for m in bad:
    print("[DMG]  %s" % m)
print("[ok]   engine: keys intact, values tokenised, MoRefs preserved"
      if not bad else "")
sys.exit(1 if bad else 0)
PY
then
    shape_fail=1
fi

# Structure must SURVIVE redaction. A leak scan only grades what got through, so
# it scores a wrapper that deletes everything as a perfect pass. These check the
# other direction: that the caller is still left with something to reason about.
echo "[..] checking that structure survives redaction"
SHAPE="$WORK/vm-info.json"
./govc-safe vm.info -json VM-0001 >"$SHAPE" 2>&1

present() {  # present <label> <extended-regex>
    if grep -qE "$2" "$SHAPE"; then
        echo "[ok]   $1"
    else
        echo "[GONE] $1"
        shape_fail=1
    fi
}

# MoRefs are the only stable correlation axis in the JSON. "value" is a
# free-text key, and blanking ran before redaction, so every MoRef -- self,
# parent, datastore, network, recentTask -- became "[redacted: free text]" and
# nothing in the document could be joined to anything else.
present "MoRefs survive as tokens" '"value": "'"$TOK"'-[0-9]+"'
present "the self MoRef is present" '"self":'
if grep -A1 '"type": "' "$SHAPE" | grep -q '"value": "\[redacted'; then
    echo "[GONE] a MoRef was blanked as free text"
    shape_fail=1
else
    echo "[ok]   no MoRef blanked as free text"
fi
# Sparing MoRefs must not have spared prose with it: a "value" with no "type"
# sibling is still free text. Graded over the whole capture, because vcsim's
# fixture VMs carry no annotation -- the prose is in events and tasks.
if grep -q '\[redacted: free text\]' "$OUT"; then
    echo "[ok]   free text is still dropped"
else
    echo "[HOLE] nothing was dropped as free text"
    shape_fail=1
fi

# Scan only what the wrapper emitted. The "--- $ govc-safe ..." lines are this
# script's own record of what it invoked, and the must-refuse cases pass real
# names in deliberately; grading those would be grading the test, not the code.
SCAN="$WORK/wrapper-output.txt"
grep -v '^--- \$ govc-safe' "$OUT" >"$SCAN"

echo "[..] scanning $(wc -c <"$SCAN") bytes of wrapper output for leaks"

fail=0
_scan() {  # _scan <extra-grep-flags> <label> <grep-args...>
    local flags="$1" label="$2"; shift 2
    local hits
    hits=$(grep -o$flags -E "$@" "$SCAN" 2>/dev/null | sort -u | head -8)
    if [ -n "$hits" ]; then
        echo "[LEAK] $label"
        echo "$hits" | sed 's/^/         /'
        fail=1
    else
        echo "[ok]   no $label"
    fi
}
report() { _scan i "$@"; }
# Case-sensitive. The token grammar is upper-case by construction, and matching
# it case-insensitively would flag every lower-case MoRef the wrapper emits.
report_cs() { _scan '' "$@"; }

# vcsim ground-truth object names. "Resources", "vm", "host", "network" and
# "datastore" are structural inventory folders and are intentionally preserved.
report "vcsim object names"  'DC0[A-Za-z0-9_-]*|LocalDS[A-Za-z0-9_]*|DVS0[A-Za-z0-9_-]*|DVUplinks[A-Za-z0-9_-]*'
report "snapshot names"      'ACME-Corp|INC-4471|rollback|migration'
# A token glued to trailing text means a name was only PARTIALLY substituted:
# "DC0_H0_VM0" became "CLUSTER-01_VM0" because the cluster name "DC0_H0" is a
# prefix of it. The remnant carries no literal "DC0", so the scan above cannot
# see it. This invariant can: a token is always a whole word.
#
# The earlier form required an underscore after the token, which only caught the
# one case that had already been found. "VM-0001Status" -- a VM named "config"
# eating the "configStatus" key -- walked straight past it. Any letter or
# underscore after a token is a partial substitution. A trailing DIGIT cannot be
# graded: it is indistinguishable from the token's own counter, which is why the
# remnant class stops short of [0-9].
report_cs "partially substituted names" "\\b$TOK-[0-9]+[A-Za-z_]"
# Redaction walks the parsed tree and rewrites values only, so a token in KEY
# position means substitution ran over the document text again. govc's JSON keys
# come from the vim25 Go structs: they are schema, and nothing about the
# environment can legitimately appear in one.
report_cs "tokens in JSON key position" "^[[:space:]]*\"[^\"]*$TOK-[0-9]+[^\"]*\"[[:space:]]*:"
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
if [ "$shape_fail" -ne 0 ]; then
    echo "[!!] structural failures above: redaction removed something the caller"
    echo "     needs. A leak scan cannot see this -- deleting everything passes it."
fi

if [ "$fail" -eq 0 ] && [ "$policy_fail" -eq 0 ] && [ "$shape_fail" -eq 0 ]; then
    echo "=== PASS: no real identifiers in $(wc -l <"$SCAN") lines, policy intact ==="
    exit 0
fi
[ "$fail" -ne 0 ] && echo "=== FAIL: real identifiers reached the output above ==="
[ "$policy_fail" -ne 0 ] && echo "=== FAIL: allowlist policy is not behaving as specified ==="
[ "$shape_fail" -ne 0 ] && echo "=== FAIL: redaction destroyed structure the caller needs ==="
echo "    full capture kept at: $WORK/all-output.txt"
trap - EXIT
exit 1
