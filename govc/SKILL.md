---
name: govc
description: Control, report on, and manage VMware vSphere/ESXi environments using the govc CLI. Use this skill whenever the user mentions vSphere, vCenter, ESXi, VMware, virtual machines on VMware, govc, vMotion, DRS, HA, vSAN, datastores, snapshots, OVA/OVF, or asks for a health check, a morning report, patch-day or maintenance-window preparation, or asks to inventory, report, power on/off, clone, migrate, snapshot, or troubleshoot anything in a VMware environment — even if they don't say "govc" explicitly.
---

# govc — VMware vSphere management from the CLI

govc is the vSphere CLI built on govmomi (https://github.com/vmware/govmomi). It talks to vCenter or standalone ESXi hosts over the vSphere API and is ideal for automation: every command supports `-json` output, entities can be referenced by path or glob pattern, and credentials come from environment variables.

## Before doing anything

1. **Check govc is installed and connected:**
   ```bash
   govc version          # is govc installed?
   govc about            # can we reach vCenter/ESXi? Shows product, version, build
   ```
   If `govc about` fails, walk through connection setup — see `references/setup.md`.

   **Credentials must come from the environment that launched Claude Code.** govc reads
   `GOVC_URL` / `GOVC_USERNAME` / `GOVC_PASSWORD` from the process environment, and each
   shell command you run is a *separate* process — an `export` in one command does **not**
   carry over to the next. So if the vars are missing, do not try to export them yourself
   and do not ask the user to paste a password into the chat. Tell the user to set them in
   their shell and restart Claude Code (`references/setup.md` has the syntax for bash/zsh,
   PowerShell, and cmd). Check what's visible with `govc env GOVC_URL` — always name the
   variable you want, because `govc env` without one prints `GOVC_PASSWORD` in cleartext,
   and so do `govc env -json`, `-dump` and `-x`. Never run those.

2. **Know which shell you're in.** The command syntax below differs between POSIX shells
   and native PowerShell:
   - Linux, macOS, WSL, and Git Bash on Windows → the `bash` examples work as written.
   - Native PowerShell / cmd.exe → use the `powershell` examples; see the Windows section
     below. `jq`, `xargs`, `grep`, and `awk` do not exist there by default.

   If unsure, `$PSVersionTable` succeeds only in PowerShell, and `uname -s` only in a POSIX
   shell.

3. **Verify flags before running unfamiliar commands.** govc has ~300 subcommands and flags evolve between releases. When unsure about exact syntax, run `govc <command> -h` first rather than guessing. This is cheap and prevents failed operations.

4. **Establish context.** Most commands need a datacenter context. If the environment has more than one datacenter, set `GOVC_DATACENTER` or pass `-dc` — otherwise commands like `datastore.info` fail with "please specify a datacenter". For environment-wide reports, loop over `govc find / -type d`. Discover the layout first:
   ```bash
   govc ls /                    # datacenters
   govc find / -type c          # clusters
   govc find / -type h          # hosts
   ```

## Safety rules — important

vSphere operations can take down production workloads. Follow these rules:

- **Read-only first.** Prefer `*.info`, `ls`, `find`, `collect`, `events`, `metric.sample` to answer questions. Never modify state to answer a reporting question.
- **Confirm before destructive operations.** These commands destroy data or disrupt workloads and require explicit user confirmation, naming the exact objects affected: `vm.destroy`, `object.destroy`, `datastore.rm`, `snapshot.remove` (especially with `*`), `host.remove`, `pool.destroy`, `vm.power -off` (hard power-off), `host.shutdown`, `vcsa.shutdown.*`, `device.remove`, `disk.rm`, `volume.rm`.
- **Prefer graceful over hard.** Guest shutdown (`vm.power -s`) before hard power-off (`vm.power -off`); reboot guest (`vm.power -r`) before reset (`vm.power -reset`). Fall back to hard operations only if VMware Tools is unavailable or the guest is hung, and say so.
- **Dry-run mentality.** Before a bulk operation, print the list of objects that will be affected (`govc find ...`) and show it to the user.
- **Never echo credentials.** Don't print `GOVC_PASSWORD` or embed passwords in command lines that end up in logs; use environment variables.
- **Snapshots are not backups.** If asked to "back up" via snapshot, do it, but note the distinction.

If a command is denied with a `[govc-policy tier=...]` message, the operator has the
deterministic policy hook installed. Do not rephrase or obfuscate the command to get
around it — report what you wanted to run and why, and let the user decide whether to
change the tier in their policy file.

The hook classifies every govc call as **read**, **mutate** or **destroy** and compares it
to the operator's tier. Unknown subcommands are never read-class, so a govc verb the hook
has not been taught is treated as a mutation:

| Tier | read | mutate | destroy |
|---|---|---|---|
| `readonly` | runs | denied | denied |
| `standard` | runs | runs | **denied outright** — not a prompt |
| `full` | runs | runs | asks for confirmation |

Two consequences are worth knowing *before* you plan a multi-step operation rather than at
step four: `host.esxcli` is mutate-class even though the verb you pass it may only read
(the hook cannot see inside the esxcli argument), and `host.shutdown` / `host.reboot` are
destroy-class, so at `standard` they are refused outright and the *admin* has to reboot the
host by another route. Runbook reference files declare their own requirements in a
`## Guard tiers` section — read it first.

## Unattended runs

If the prompt says "unattended", "no questions", "use defaults", "scheduled", or names a
directory to write to and nobody to ask, you are running without an operator — and under a
`dontAsk` permission mode you also *cannot* ask, because the question tool is denied. A
question is then not a pause, it is a failed run.

**"Unattended" removes the question, never the boundary.**

Decide these yourself, silently:

- Skip every step a reference file marks optional or slow, and say in the report that you
  skipped it and why.
- Apply the default thresholds from `references/report-template.md`.
- Write to the directory named in the prompt, using the standard filename
  `<report-type>-<environment>-<YYYY-MM-DD>.html`. Use the file-writing tool, not shell
  redirection.
- Overwrite a same-named file from an earlier run today.
- Treat a documented benign error as data: an empty datacenter answering
  `datastore '*' not found` means "no datastores here", not a failure.
- Record a query that failed as "not collected", with the reason, and carry on.

Refuse these, unattended or not:

- **Any command that is not read-only.** Unattended mode authorises no mutation, ever. If
  the prompt asks for remediation, do the read-only part, write the report, and put the
  change in it as a recommendation with the exact command — do not run it.
- **Proceeding when `govc about` fails.** No data is not the same as no findings.
- **Inventing a number** to fill a KPI card or a table cell.
- **Writing outside the directory the prompt named.**

None of this weakens the safety rules above. Those protect *vSphere* — confirm before a
destructive call, list the objects before a bulk operation — and an unattended run cannot
reach them, because it may not issue a non-read command at all. What it decides on its own
is a local file write and a default threshold.

End your output with one machine-readable line, as the very last line, so a wrapper can act
on it without parsing prose:

```
GOVC-REPORT report=health-check env=acme-prod status=critical critical=2 warning=5 ok=4 info=1 baseline=changed path=/var/lib/vsphere-health/health-check-acme-prod-2026-07-30.html
```

- `status` is the worst severity found: `critical`, `warning`, `ok`, or `error` when the run
  could not collect data.
- `baseline` is `first-run`, `unchanged`, or `changed`.
- `path=` comes last and unquoted, so a path containing spaces is everything after `path=`.
  Use `path=-` when no file was written.
- Emit the line even on failure:
  `GOVC-REPORT report=health-check env=acme-prod status=error critical=0 warning=0 ok=0 info=0 baseline=unknown path=-`

The operator's side of this — schedulers, and the permission rules that keep an unattended
run from stalling — is in `docs/scheduled-reports.md` in the project repository.

## Output for reports

Every govc command accepts `-json` (and most `-xml`/`-dump`). For reports:

- Use `-json` piped to `jq` (or parse in Python) rather than scraping human-readable output.
- For fleet-wide data, `govc find` + `govc collect` is far faster than looping `vm.info` per VM. Example — all powered-on VMs with CPU/memory in one call:
  ```bash
  govc find / -type m -runtime.powerState poweredOn |
    tr '\n' '\0' | xargs -0 govc vm.info -json |
    jq -r '.virtualMachines[] | [.name, .config.hardware.numCPU, .config.hardware.memoryMB] | @tsv'
  ```
  ```powershell
  $vms = govc find / -type m '-runtime.powerState' poweredOn
  (govc vm.info -json @vms | ConvertFrom-Json).virtualMachines |
    Select-Object name,
      @{n='CPU';e={$_.config.hardware.numCPU}},
      @{n='MemoryMB';e={$_.config.hardware.memoryMB}}
  ```
  **Always use `tr '\n' '\0' | xargs -0`, never bare `xargs`.** VM paths routinely contain
  spaces (`/DC1/vm/My App Server`), which bare `xargs` splits into separate arguments. Do
  not use `xargs -d '\n'` either — that is a GNU extension and fails on macOS.
- Deliver quick answers as Markdown tables in chat. When the user wants a report **as a
  file** (to keep, share, or send to a client), use the standard HTML template — see
  `references/report-template.md` and `assets/report-template.html`.

## Domain references

Read the reference file matching the task — each contains commands, tested patterns, and gotchas:

| Task | File |
|---|---|
| Install, auth, TLS, env vars, session handling | `references/setup.md` |
| Inventory, reporting, performance metrics, events, alarms, capacity | `references/inventory-reporting.md` |
| VM create/clone/power/migrate/destroy, guest ops, templates, OVA import | `references/vm-lifecycle.md` |
| Snapshots: create, revert, remove, tree, audit | `references/snapshots.md` |
| Hosts and clusters: maintenance, DRS/HA, rules, resource pools, esxcli | `references/host-cluster.md` |
| Host patch day: pre-flight, evacuate, verify, roll back | `references/patching.md` |
| Performance history: intervals, retention, trends, idle detection | `references/metrics.md` |
| Capacity planning: overcommit ratios, N+1 headroom, growth | `references/capacity-planning.md` |
| Datastores, disks, networking (vSwitch/DVS/portgroups) | `references/storage-network.md` |
| Environment health check: the fixed nine-check list, severities, baseline diff | `references/health-check.md` |
| HTML report deliverables: template, severity rules, structure | `references/report-template.md` |

## Quick command map

- Inventory: `ls`, `find`, `tree`, `object.collect` (alias `collect`)
- Info: `about`, `vm.info`, `host.info`, `datastore.info`, `cluster.usage`, `pool.info`, `datacenter.info`
- VM lifecycle: `vm.create`, `vm.clone`, `vm.instantclone`, `vm.customize`, `vm.power`, `vm.change`, `vm.migrate`, `vm.destroy`
- Snapshots: `snapshot.create`, `snapshot.tree`, `snapshot.revert`, `snapshot.remove`
- Guest ops (needs VMware Tools + `GOVC_GUEST_LOGIN`): `guest.run`, `guest.ps`, `guest.upload`, `guest.download`, `guest.df`
- Monitoring: `events`, `tasks`, `alarms`, `metric.sample`, `metric.ls`, `logs`
- Host/cluster: `host.add`, `host.maintenance.enter/exit`, `host.esxcli`, `cluster.create`, `cluster.change`, `cluster.rule.*`, `cluster.group.*`, `pool.*`
- Storage: `datastore.*`, `disk.*`, `import.ova`, `import.ovf`, `export.ovf`, `library.*`
- Network: `host.vswitch.*`, `host.portgroup.*`, `dvs.*`, `vm.network.*`
- Security/access: `permissions.*`, `role.*`, `sso.*`, `tags.*`

## Windows / PowerShell notes

These apply to **native PowerShell and cmd.exe only**. Under Git Bash or WSL, use the bash
examples unchanged.

- **Quote every flag that contains a dot.** PowerShell splits an unquoted argument like
  `-runtime.powerState` at the dot before govc ever sees it, producing a usage error. This
  is not limited to `find` filters — it affects *any* dotted flag:
  `-runtime.powerState`, `-runtime.connectionState`, `-runtime.inMaintenanceMode`,
  `-runtime.consolidationNeeded`, `-snapshot.currentSnapshot`, `-vm.ipath`, `-disk.label`,
  `-cpu.shares`, `-mem.limit`, `-mem.reservation`, `-net.adapter`, `-net.address`.
  ```powershell
  govc find / -type m '-runtime.powerState' poweredOn
  govc find / -type m '-snapshot.currentSnapshot' '*'
  govc vm.disk.change -vm my-vm '-disk.label' "Hard disk 2" -size 200GB
  govc pool.create '-cpu.shares' high '-mem.limit' 16384 /DC1/host/ClusterA/Resources/prod
  ```
  Rule of thumb: if the flag has a `.` in it, wrap it in single quotes.
- **No jq, xargs, grep, or awk by default.** Use `ConvertFrom-Json` and the object pipeline:
  ```powershell
  (govc datastore.info -json | ConvertFrom-Json).datastores |
    Select-Object name,
      @{n='CapacityGB';e={[math]::Round($_.summary.capacity/1GB)}},
      @{n='FreeGB';e={[math]::Round($_.summary.freeSpace/1GB)}}
  ```
  To pass many paths to one command, splat the array with `@` instead of piping to `xargs`:
  ```powershell
  $vms = govc find / -type m
  govc vm.info -json @vms | ConvertFrom-Json
  ```
  Text-filtering equivalents: `grep foo` → `Select-String foo`, `awk '{print $2}'` →
  `ForEach-Object { ($_ -split '\s+')[1] }`.
- **Redirection encoding.** In Windows PowerShell 5.1, `cmd > file.json` writes UTF-16LE
  with a BOM, which govc cannot read back. Use `| Out-File -Encoding utf8 file.json`
  (PowerShell 7+ defaults to UTF-8 and is fine either way).
- **Backgrounding.** `cmd &` is a POSIX idiom and is a syntax error in PowerShell 5.1. Use
  `Start-Process`.

## Environment quick reference

Set these in the shell **before** starting Claude Code — see step 1 above.

```bash
# bash / zsh (Linux, macOS, WSL, Git Bash)
export GOVC_URL='vcenter.example.com'        # https:// and /sdk are implied
export GOVC_USERNAME='administrator@vsphere.local'
export GOVC_PASSWORD='...'
export GOVC_INSECURE=true                    # lab only — skips TLS verification
export GOVC_DATACENTER='DC1'                 # default datacenter
```

```powershell
# PowerShell — current session only
$env:GOVC_URL        = 'vcenter.example.com'
$env:GOVC_USERNAME   = 'administrator@vsphere.local'
$env:GOVC_PASSWORD   = '...'
$env:GOVC_INSECURE   = 'true'
$env:GOVC_DATACENTER = 'DC1'
```

Full per-shell syntax, including persistent `setx` on Windows, is in `references/setup.md`.

For testing without real infrastructure, `vcsim` (the vCenter simulator, also from govmomi) responds to nearly all govc commands — useful for validating scripts safely.
