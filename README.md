# claude-vsphere-skill

A [Claude Code](https://docs.claude.com/en/docs/claude-code) skill that turns Claude into a vSphere administrator using [govc](https://github.com/vmware/govmomi/tree/main/govc) — inventory, reporting, snapshot audits, root-cause analysis, and safe VM/host/cluster management for VMware vCenter and ESXi.

Ask in plain language:

> "Which VMs have snapshots, and how old are they?"
> "VM web-01 was down last night. Find out what happened and when."
> "Datastore capacity report — flag anything over 85% full."
> "Prepare esx02 for patching."

And Claude picks the right govc commands, batches queries efficiently, parses the JSON, and answers like a colleague — including pushing back when your premise is wrong:

![Claude disproving an outage claim using vmware.log forensics](images/claude4.png)

*(Real session against a real vCenter: asked about an outage "last night", Claude proved from rotated `vmware.log` files — beyond vCenter's event retention — that the VM had been down since December, and reconstructed the host outage that caused it. All read-only.)*

## Safety first

Instructions the skill enforces on every session:

- **Read-only first** — reporting questions are answered with `*.info`, `find`, `collect`, `events`, `metric.sample`; never by changing state.
- **Confirmation for destructive operations** — `vm.destroy`, `snapshot.remove '*'`, `datastore.rm`, `host.shutdown` and friends require Claude to show the exact objects affected and get an explicit yes.
- **Dry-run mentality** — before bulk operations, Claude prints the object list so you approve a list, not a pattern.
- **Graceful before hard** — guest shutdown before power-off, guest reboot before reset.

These are instructions, not a permission system. For defense in depth, run govc with a least-privilege vCenter role — with a read-only account the skill physically cannot change anything.

## Requirements

- [Claude Code](https://docs.claude.com/en/docs/claude-code)
- `govc` on PATH (step 1 below) — or let `test-unix.sh` / `test-windows.ps1` install it for you
- A vCenter or ESXi endpoint — or none at all: the test scripts can run against the bundled simulator
- `jq` is recommended for the report patterns on bash-like shells; native PowerShell uses `ConvertFrom-Json` and doesn't need it

## Installation

### Step 1 — install `govc`

| Platform | Command |
|---|---|
| macOS | `brew install govc` |
| Windows | `scoop install govc` |
| Linux | download below, or `.deb`/`.rpm` from [releases](https://github.com/vmware/govmomi/releases) |
| Any | `go install github.com/vmware/govmomi/govc@latest` |

Linux/macOS direct download. Note the `aarch64` → `arm64` mapping — `uname -m` reports
`aarch64` on ARM, but the published asset is named `arm64`, so the naive one-liner 404s:

```bash
OS=$(uname -s); ARCH=$(uname -m)
[ "$ARCH" = "aarch64" ] && ARCH=arm64
curl -fL "https://github.com/vmware/govmomi/releases/latest/download/govc_${OS}_${ARCH}.tar.gz" \
  | sudo tar -C /usr/local/bin -xzf - govc
```

Verify with `govc version`. For `jq`: `brew install jq` / `apt install jq` / `scoop install jq`.

### Step 2 — install the skill

Copy the `govc/` folder — that's the whole skill — into your skills directory:

```bash
git clone https://github.com/vchaindz/claude-vsphere-skill.git
cd claude-vsphere-skill

# personal (all projects)
mkdir -p ~/.claude/skills && cp -r govc ~/.claude/skills/

# or per-project
mkdir -p /path/to/project/.claude/skills && cp -r govc /path/to/project/.claude/skills/
```

```powershell
git clone https://github.com/vchaindz/claude-vsphere-skill.git
cd claude-vsphere-skill

$dst = "$env:USERPROFILE\.claude\skills\govc"
New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }   # avoid nesting on re-install
Copy-Item .\govc $dst -Recurse -Force
```

### Step 3 — set the connection variables *before* starting Claude Code

Claude Code inherits the environment of the terminal that launches it, and each command it
runs is a separate process — so a variable exported mid-session does not stick. Set these
in your shell first, then run `claude`. If you change them, restart Claude Code.

```bash
# bash / zsh — Linux, macOS, WSL, Git Bash
export GOVC_URL='vcenter.example.com'
export GOVC_USERNAME='administrator@vsphere.local'
export GOVC_PASSWORD='...'
export GOVC_INSECURE=true     # lab only, for self-signed certs; prefer GOVC_TLS_CA_CERTS
```

```powershell
# PowerShell — this session
$env:GOVC_URL      = 'vcenter.example.com'
$env:GOVC_USERNAME = 'administrator@vsphere.local'
$env:GOVC_PASSWORD = '...'
$env:GOVC_INSECURE = 'true'

# or persistently (applies to NEW terminals — the current one keeps the old values)
setx GOVC_URL      "vcenter.example.com"
setx GOVC_USERNAME "administrator@vsphere.local"
setx GOVC_PASSWORD "..."
```

```bat
REM cmd.exe
set GOVC_URL=vcenter.example.com
set GOVC_USERNAME=administrator@vsphere.local
set GOVC_PASSWORD=...
```

Confirm with `govc about`. To inspect a single variable use `govc env GOVC_URL` — a bare
`govc env` prints `GOVC_PASSWORD` in cleartext.

To persist on Linux/macOS, add the `export` lines to `~/.zshrc` (macOS default shell) or
`~/.bashrc`.

## Platform support

| Platform | Shell | Status |
|---|---|---|
| Linux (x86_64, arm64) | bash / zsh | Tested against a real vCenter and against the simulator |
| macOS (Intel, Apple Silicon) | zsh / bash | Same commands as Linux; no GNU-only flags in any pipeline |
| Windows | PowerShell 5.1 / 7+ | Tested against the simulator; every reference file carries PowerShell examples |
| Windows | Git Bash / WSL | Use the bash examples unchanged |

## Try it without touching production

`vcsim`, the vCenter simulator from the govmomi project, answers nearly all govc calls with a simulated inventory. The included test scripts set everything up and validate the skill's command patterns:

```powershell
# Windows: installs govc + vcsim, installs the skill, runs 15 smoke tests against the simulator
powershell -ExecutionPolicy Bypass -File .\test-windows.ps1
```

```bash
# Linux/macOS: installs govc + vcsim + the skill, runs 21 smoke tests against the simulator.
# No vCenter and no credentials needed — nothing real is touched.
./test-unix.sh --vcsim

# Or against your real vCenter: ~18 READ-ONLY tests
./test-unix.sh
# optional snapshot create/remove cycle on an explicitly named non-production VM:
./test-unix.sh --write-test my-test-vm
```

Recommended first interactive test: start `claude`, ask for an inventory report, then ask it to destroy a test VM — it should list the VM and ask for confirmation before doing anything.

## What's in the skill

```
govc/
├── SKILL.md                      # workflow, safety rules, command map, Windows notes
└── references/                   # loaded on demand (progressive disclosure)
    ├── setup.md                  # install, auth, TLS, sessions, troubleshooting, vcsim
    ├── inventory-reporting.md    # find/collect/jq patterns, metrics, events, health checks
    ├── vm-lifecycle.md           # create, clone, power, migrate, guest ops, destroy
    ├── snapshots.md              # create, audit, revert, cleanup workflow
    ├── host-cluster.md           # maintenance mode, DRS/HA rules, pools, esxcli
    └── storage-network.md        # datastores, disks, vSwitch/DVS/portgroups
```

Battle-tested details baked in from real-world runs: PowerShell splits unquoted dotted flags like `-runtime.powerState` (quote them), `host.info` needs an explicit host when there's more than one, multi-datacenter vCenters need `-dc`/`GOVC_DATACENTER` context, an empty datacenter answers `datastore.info` with a misleading "not found", `snapshot.remove` rejects the `id` integer that `vm.info -json` shows and wants the `snapshot-NNNNN` managed object ID instead, and a snapshot audit must recurse into `childSnapshotList` or it reports a deep chain as a single snapshot.

Every reference file is cross-platform: bash examples work on Linux, macOS, WSL, and Git Bash, and each command that behaves differently under native PowerShell carries a `powershell` twin. Batch pipelines use `tr '\n' '\0' | xargs -0` rather than the GNU-only `xargs -d '\n'`, so they run unmodified on macOS and survive VM names containing spaces.

## Repository layout

| Path | Purpose |
|---|---|
| `govc/` | **The skill** — the only thing you need to copy |
| `test-windows.ps1` | Windows setup + smoke test against vcsim |
| `test-unix.sh` | Linux/macOS setup + smoke test against vcsim (`--vcsim`) or a real vCenter |
| `images/` | Screenshots |

## Contributing

Issues and PRs welcome — especially additional gotchas from real environments, missing command patterns, and improvements to the safety rules. If Claude ever executes a destructive operation without confirmation, please file an issue with the transcript.

## License

Apache License 2.0 — see [LICENSE](LICENSE). `govc` and `vcsim` are part of the [govmomi](https://github.com/vmware/govmomi) project (also Apache 2.0), © Broadcom. Not affiliated with Broadcom/VMware or Anthropic.
