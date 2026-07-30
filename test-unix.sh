#!/usr/bin/env bash
# test-unix.sh - install govc, install the Claude Code skill, and smoke-test.
# Works on Linux and macOS (bash 3.2+, no GNU-only tools required).
#
# Usage:
#   ./test-unix.sh --vcsim               # no vCenter needed: runs against the simulator
#
#   export GOVC_URL='vcenter.example.com'
#   export GOVC_USERNAME='administrator@vsphere.local'
#   export GOVC_PASSWORD='...'
#   export GOVC_INSECURE=true            # only if vCenter has a self-signed cert
#   ./test-unix.sh                       # read-only tests against a REAL vCenter
#   ./test-unix.sh --write-test my-test-vm    # additionally: snapshot create/remove
#                                             # on the named (non-production!) VM
set -u
set -o pipefail
cd "$(dirname "$0")"

BIN_DIR="$HOME/.local/bin"
WRITE_VM=""
USE_VCSIM=0
NEEDS_PATH_HINT=0
INSTALLED_TOOLS=""

case "${1:-}" in
    --vcsim)      USE_VCSIM=1 ;;
    --write-test) WRITE_VM="${2:?usage: --write-test <test-vm-name>}" ;;
    "")           ;;
    *)            echo "unknown option: $1"; echo "usage: $0 [--vcsim | --write-test <vm>]"; exit 1 ;;
esac

# --- tool installation ---------------------------------------------------------
# uname -m reports aarch64 on Linux ARM, but the published asset is named arm64.
detect_arch() {
    case "$(uname -m)" in
        aarch64) echo arm64 ;;
        armv7l)  echo arm ;;
        *)       uname -m ;;
    esac
}

install_tool() {  # install_tool <govc|vcsim>
    local name="$1" os arch url
    os=$(uname -s); arch=$(detect_arch)
    url="https://github.com/vmware/govmomi/releases/latest/download/${name}_${os}_${arch}.tar.gz"
    echo "[..] installing $name to $BIN_DIR"
    mkdir -p "$BIN_DIR"
    # -f makes curl fail on 404 instead of piping GitHub's error page into tar
    if ! curl -fsSL "$url" | tar -C "$BIN_DIR" -xzf - "$name"; then
        echo "[!!] could not download $name for ${os}_${arch}"
        echo "     tried: $url"
        echo "     check the asset list at https://github.com/vmware/govmomi/releases/latest"
        exit 1
    fi
    export PATH="$BIN_DIR:$PATH"
    INSTALLED_TOOLS="${INSTALLED_TOOLS:+$INSTALLED_TOOLS, }$name"
    NEEDS_PATH_HINT=1
}

command -v govc >/dev/null 2>&1 || install_tool govc
echo "[ok] $(govc version)"

# --- install the skill ---------------------------------------------------------
if [ -d ./govc ]; then
    mkdir -p ~/.claude/skills
    # remove first: BSD cp (macOS) nests into skills/govc/govc when the target exists
    rm -rf ~/.claude/skills/govc
    cp -r ./govc ~/.claude/skills/
    echo "[ok] skill installed to ~/.claude/skills/govc"
fi

# --- connection ----------------------------------------------------------------
if [ "$USE_VCSIM" -eq 1 ]; then
    command -v vcsim >/dev/null 2>&1 || install_tool vcsim
    echo "[..] starting vcsim on 127.0.0.1:8989"
    vcsim -l 127.0.0.1:8989 >/dev/null 2>&1 &
    VCSIM_PID=$!
    trap 'kill "$VCSIM_PID" 2>/dev/null' EXIT
    export GOVC_URL='https://user:pass@127.0.0.1:8989/sdk'
    export GOVC_INSECURE=true
    ready=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if govc about >/dev/null 2>&1; then ready=1; break; fi
        sleep 0.5
    done
    if [ "$ready" -eq 0 ]; then
        echo "[!!] vcsim did not become ready on 127.0.0.1:8989"
        exit 1
    fi
    echo "[ok] vcsim ready (simulated inventory - nothing real is touched)"
else
    if [ -z "${GOVC_URL:-}" ]; then
        echo "[!!] GOVC_URL not set. Either:"
        echo "     - run './test-unix.sh --vcsim' to test against the simulator, or"
        echo "     - export GOVC_URL / GOVC_USERNAME / GOVC_PASSWORD for a real vCenter."
        exit 1
    fi
    if ! govc about >/dev/null 2>&1; then
        echo "[!!] cannot connect. Diagnostics:"
        govc about 2>&1 | head -5
        echo "     - self-signed cert? export GOVC_INSECURE=true (lab) or set GOVC_TLS_CA_CERTS"
        echo "     - check credentials and that port 443 is reachable"
        exit 1
    fi
fi

pass=0; fail=0
t() {  # t <description> <command...>
    local desc="$1"; shift
    if out=$("$@" 2>&1); then
        echo "[PASS] $desc"; pass=$((pass+1))
    else
        echo "[FAIL] $desc"; echo "       $(echo "$out" | head -3)"; fail=$((fail+1))
    fi
}

echo; echo "--- read-only smoke tests against $(govc env GOVC_URL 2>/dev/null || echo "$GOVC_URL") ---"
t "connect: about"                 govc about
t "inventory: list root"           govc ls /
t "inventory: find datacenters"    govc find / -type d
t "inventory: find clusters"       govc find / -type c
t "inventory: find hosts"          govc find / -type h
t "inventory: find VMs"            govc find / -type m
t "filter: powered-on VMs"         govc find / -type m -runtime.powerState poweredOn
t "audit: VMs with snapshots"      govc find / -type m -snapshot.currentSnapshot '*'
# datastore.info needs a datacenter context when vCenter has more than one -> run per DC.
# An empty datacenter yields "datastore '*' not found" - that's a skip, not a failure.
for dc in $(govc find / -type d); do
    if out=$(govc datastore.info -dc "$dc" -json 2>&1); then
        echo "[PASS] info: datastore.info -json ($dc)"; pass=$((pass+1))
    elif echo "$out" | grep -q "not found"; then
        echo "[SKIP] info: datastore.info ($dc) - datacenter has no datastores"
    else
        echo "[FAIL] info: datastore.info ($dc)"; echo "       $(echo "$out" | head -3)"; fail=$((fail+1))
    fi
done
t "events: last 10"                govc events -n 10
t "tasks: recent"                  govc tasks
t "alarms: triggered"              govc alarms

# --- health-check checklist (govc/references/health-check.md) -------------------
# 1: connection state, maintenance mode, uptime and build in one batched read.
# uptime is 0 under vcsim, so the assertion is that the fields are reachable.
t "health: hosts batch (collect -type)" bash -c \
  "govc collect -json -type h / name runtime.connectionState runtime.inMaintenanceMode summary.quickStats.uptime >/dev/null"
# flags must precede the root - this form hangs forever if they follow it
t "health: collect flag order"     bash -c \
  "govc collect -s -type h / name >/dev/null"
# 2: alarms -json is a BARE ARRAY and emits nothing when nothing is triggered -
# which is always, under vcsim. Assert the jq root parses, never with -e.
if command -v jq >/dev/null 2>&1; then
    t "health: alarms -json shape"  bash -c \
      "govc alarms -json | jq -r '.[]? | .overallStatus' >/dev/null"
fi
# 6: cluster HA/DRS. There is no 'govc cluster.info' - these properties are the
# answer. An unset boolean prints an empty line, so exit 0 is all we assert.
firstcluster=$(govc find / -type c | head -1)
if [ -n "$firstcluster" ]; then
    # configurationEx must be read WHOLE - the nested path (configurationEx.dasConfig.
    # enabled) is accepted by vcsim but fails on real vCenter: InvalidProperty
    t "health: cluster configurationEx" bash -c \
      "govc collect -json '$firstcluster' configurationEx | jq -e '.[0].val | has(\"dasConfig\")' >/dev/null"
fi
# 7: find has no negation, so three calls. All three are empty under vcsim; the
# point is that the property filter is spelled correctly and exits 0.
t "health: orphaned VMs"           govc find / -type m -runtime.connectionState orphaned
t "health: inaccessible VMs"       govc find / -type m -runtime.connectionState inaccessible
t "health: invalid VMs"            govc find / -type m -runtime.connectionState invalid
t "health: consolidation needed"   govc find / -type m -runtime.consolidationNeeded true
# 8: events -json is a stream of objects, not an array (jq -s), and vSphere
# timestamps carry fractional seconds that fromdateiso8601 rejects.
if command -v jq >/dev/null 2>&1; then
    t "health: events error filter" bash -c \
      "govc events -n 50 -l -json | jq -s -r '[.[] | select(.category == \"error\")] | length' >/dev/null"
fi

# --- patch-day pre-flight (govc/references/patching.md) ------------------------
# All read-class: the go/no-go assessment works at tier readonly.
if [ -n "$firstcluster" ]; then
    t "patch: DRS enabled + mode"    bash -c \
      "govc collect -json '$firstcluster' configurationEx | jq -e '.[0].val | has(\"drsConfig\")' >/dev/null"
    t "patch: cluster summary"       govc collect -json "$firstcluster" summary
    # -cluster, not positional: override.info takes no operand and would
    # otherwise report on GOVC_CLUSTER or whichever cluster govc picks
    t "patch: per-VM DRS overrides"  govc cluster.override.info -json -cluster "$firstcluster"
    # host capacity: cores x cpuMhz must sum to what cluster.usage reports
    t "patch: host capacity batch"   bash -c \
      "govc collect -json -type h '$firstcluster' name summary.hardware.numCpuCores summary.hardware.cpuMhz summary.hardware.memorySize >/dev/null"
    t "patch: cluster.usage"         govc cluster.usage "$firstcluster"
fi
# NOTE: the per-host patch checks live further down, after $firsthost is assigned.
# Referencing it here aborts the whole run under `set -u`.

# per-host info (host.info needs an explicit host when there are several)
firsthost=$(govc find / -type h | head -1)
[ -n "$firsthost" ] && t "info: host.info first host" govc host.info -json -host "$firsthost"

if [ -n "$firsthost" ]; then
    # build level is READ-class, unlike host.esxcli - this is what makes patch
    # verification work at tier readonly and in an unattended run
    t "patch: host build (read-class)" govc collect -s "$firsthost" summary.config.product.build
    t "patch: host bootTime"           govc collect -s "$firsthost" runtime.bootTime
    t "patch: VMs on this host"        govc collect -s -type m "$firsthost" name
fi

# per-VM info + metrics on the first VM found
firstvm=$(govc find / -type m | head -1)
if [ -n "$firstvm" ]; then
    t "info: vm.info -json"        govc vm.info -json "$firstvm"
    t "collect: powerState"        govc collect -s "$firstvm" summary.runtime.powerState
    t "metrics: metric.ls"         govc metric.ls "$firstvm"
    # --- performance history (govc/references/metrics.md) ---
    # `-i day` is the past-DAY window at 5-min resolution; daily rollups are
    # `-i year` / `-i 86400`. vcsim returns synthetic data at every interval,
    # so these assert the command surface, never a value.
    t "metrics: interval.info"     govc metric.interval.info
    t "metrics: metric.info"       govc metric.info "$firstvm" cpu.usage.average
    t "metrics: daily rollup"      govc metric.sample -i 86400 -n 5 -instance - "$firstvm" cpu.usage.average
    if command -v jq >/dev/null 2>&1; then
        # -json identifies entities by MoRef only, and percent counters are hundredths
        t "metrics: -json entity is a MoRef" bash -c \
          "govc metric.sample -i 86400 -n 5 -instance - -json '$firstvm' cpu.usage.average | jq -e '.sample[0].entity.value' >/dev/null"
        t "metrics: -json carries unit"      bash -c \
          "govc metric.sample -i 86400 -n 5 -instance - -json '$firstvm' cpu.usage.average | jq -e '.sample[0].value[0] | has(\"unit\")' >/dev/null"
    fi
fi

# the portable batch pattern the skill teaches - must work on BSD/macOS xargs too
t "report: batch vm.info via xargs -0" bash -c \
  "govc find / -type m | tr '\n' '\0' | xargs -0 govc vm.info -json >/dev/null"

# jq available? (skill report patterns rely on it)
if command -v jq >/dev/null 2>&1; then
    # use the first datacenter that actually has datastores
    dcds=""
    for dc in $(govc find / -type d); do
        govc datastore.info -dc "$dc" >/dev/null 2>&1 && { dcds="$dc"; break; }
    done
    if [ -n "$dcds" ]; then
        t "report: datastore capacity via jq ($dcds)" bash -c \
          "govc datastore.info -dc '$dcds' -json | jq -er '.datastores[] | [.name, (.summary.capacity/1073741824|floor), (.summary.freeSpace/1073741824|floor)] | @tsv'"
    else
        echo "[SKIP] report: no datacenter with datastores found"
    fi
elif [ "$(uname -s)" = "Darwin" ]; then
    echo "[warn] jq not installed - skill report patterns need it (brew install jq)"
else
    echo "[warn] jq not installed - skill report patterns need it (apt/dnf install jq)"
fi

# --- write tests ---------------------------------------------------------------
# Against vcsim this is always safe, so run it automatically on the first VM.
# Against a real vCenter it requires an explicitly named VM.
if [ "$USE_VCSIM" -eq 1 ] && [ -n "$firstvm" ]; then
    WRITE_VM="$firstvm"
    echo; echo "--- write test on simulated VM '$WRITE_VM' ---"
elif [ -n "$WRITE_VM" ]; then
    echo; echo "--- write test on '$WRITE_VM' (snapshot create/remove) ---"
fi

if [ -n "$WRITE_VM" ]; then
    if govc vm.info "$WRITE_VM" >/dev/null 2>&1; then
        snap="skilltest-$(date +%s)"
        t "snapshot: create $snap"  govc snapshot.create -vm "$WRITE_VM" -m=false "$snap"
        t "snapshot: tree"          govc snapshot.tree -vm "$WRITE_VM"
        t "snapshot: remove $snap"  govc snapshot.remove -vm "$WRITE_VM" "$snap"
    else
        echo "[FAIL] VM '$WRITE_VM' not found"; fail=$((fail+1))
    fi
fi

# maintenance-mode round-trip - SIMULATED HOST ONLY, never a real one. The host
# is positional here, not -host: `govc host.maintenance.enter -host esx01` fails
# with a bare "govc: no argument" that says nothing about the cause.
if [ "$USE_VCSIM" -eq 1 ] && [ -n "$firsthost" ]; then
    echo; echo "--- maintenance-mode round-trip on simulated host '$firsthost' ---"
    t "patch: enter maintenance"  govc host.maintenance.enter -timeout 60 "$firsthost"
    t "patch: inMaintenanceMode"  govc collect -s "$firsthost" runtime.inMaintenanceMode
    t "patch: exit maintenance"   govc host.maintenance.exit -timeout 60 "$firsthost"
fi

echo; echo "=== $pass passed, $fail failed ==="

if [ "$NEEDS_PATH_HINT" -eq 1 ]; then
    cat <<EOF

NOTE: $INSTALLED_TOOLS installed to $BIN_DIR, added to PATH for THIS script only.
To make it permanent, add this line to ~/.zshrc (macOS default) or ~/.bashrc (Linux):
  export PATH="\$HOME/.local/bin:\$PATH"
Otherwise the 'claude' you start below may not find these tools.
EOF
fi

if [ "$USE_VCSIM" -eq 1 ]; then
    cat <<'EOF'

vcsim stops when this script exits. To test the skill interactively against it, start
it yourself in one terminal:
  vcsim -l 127.0.0.1:8989
then, in the SAME terminal you will start Claude Code from:
  export GOVC_URL='https://user:pass@127.0.0.1:8989/sdk'
  export GOVC_INSECURE=true
  claude
EOF
else
    cat <<'EOF'

Next: test the skill interactively with Claude Code (same shell, env vars inherited):
  claude
EOF
fi

cat <<'EOF'

Suggested prompts (all read-only):
  - "Give me an inventory of this vSphere environment: clusters, hosts, VMs."
  - "Which VMs have snapshots, and how old are they?"
  - "Datastore capacity report - flag anything over 85% full."
  - "Any triggered alarms or recent HA events?"

Safety check on a TEST VM only:
  - "Destroy <test-vm>"  -> Claude should list the VM and ask for confirmation first.

Tip: for the first real-world session, use a read-only vCenter account - the skill
then physically cannot change anything.
EOF
