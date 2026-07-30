# Host patch day — pre-flight, evacuate, verify

## Guard tiers

| Phase | Class | Needs |
|---|---|---|
| 1 pre-flight, 4 post-checks, 5 diagnosis | read | any tier, including `readonly` |
| 2 `host.maintenance.enter` / `.exit` | mutate | `standard` |
| 3 `host.esxcli software vib list` (optional detail) | mutate | `standard` |
| 3 `host.shutdown -r` (the reboot) | destroy | refused at `standard`; asks at `full` |

Check the tier before you start, not at step four. At `readonly` you can produce the entire
go/no-go assessment and the post-patch verification — everything except the evacuation
itself — which is worth saying to the user rather than refusing the whole task.

## One host at a time

Never batch this runbook. One host enters maintenance, gets patched, comes back, and is
verified before the next one starts.

The reason is not caution for its own sake: HA admission control and DRS both reason about
the *current* number of available hosts. Two hosts leaving a four-host cluster at once can
satisfy each evacuation individually and still leave the survivors unable to honour
reservations — and the second evacuation will happily start while the first host is still
draining. If the user asks to prepare a whole cluster, do them in sequence and say so.

## Phase 1 — pre-flight (read-only)

Everything here runs at `readonly`. Produce all of it before anything moves.

### Cluster capacity without this host

```bash
cluster=/DC1/host/ClusterA
host=/DC1/host/ClusterA/esx03

govc collect -json -type h "$cluster" name \
    summary.hardware.numCpuCores summary.hardware.cpuMhz summary.hardware.memorySize \
    summary.quickStats.overallCpuUsage summary.quickStats.overallMemoryUsage \
    runtime.connectionState runtime.inMaintenanceMode |
  jq -s -r 'def v: if type=="object" and has("_value") then ._value else . end;
    .[] | ([.changeSet[] | {(.name): (.val|v)}] | add) as $p |
    [$p.name,
     ($p["summary.hardware.numCpuCores"] * $p["summary.hardware.cpuMhz"]),
     ($p["summary.hardware.memorySize"] / 1048576 | floor),
     $p["summary.quickStats.overallCpuUsage"],
     $p["summary.quickStats.overallMemoryUsage"],
     $p["runtime.connectionState"], $p["runtime.inMaintenanceMode"]] | @tsv'
```

Output columns: `name  cpuCapacityMHz  memCapacityMiB  cpuUsedMHz  memUsedMiB  state  inMaint`.

**Units differ per field and mixing them up is the classic error here.**
`summary.hardware.memorySize` is **bytes**; `summary.quickStats.overallMemoryUsage` is
**MiB**; `overallCpuUsage` is **MHz**. Host CPU capacity is
`numCpuCores × cpuMhz` — cores, not threads — and summing that across the cluster's hosts
reproduces `govc cluster.usage` exactly, which is the cheap way to prove your arithmetic
before you rely on it.

The arithmetic, stated so the report can defend it:

```
remaining_cpu = Σ cpuCapacityMHz over hosts that are connected, not in maintenance, and not this host
remaining_mem = Σ memCapacityMiB over the same set
demand_cpu    = Σ cpuUsedMHz  over ALL hosts in the cluster, including this one
demand_mem    = Σ memUsedMiB  over the same
projected_cpu_pct = demand_cpu / remaining_cpu × 100
projected_mem_pct = demand_mem / remaining_mem × 100
```

Warning at ≥ 80%, critical at ≥ 90% — thresholds live in `references/report-template.md`.

Say plainly what this does **not** account for, because a number presented as more certain
than it is will eventually be wrong in front of a customer: per-VM reservations, the
admission-control policy actually configured (slot-based, percentage, or dedicated
failover host), and HA slot sizing. It is a load projection, not an admission-control
simulation. `govc collect -json "$cluster" summary` gives vCenter's own view —
`totalCpu`, `effectiveCpu`, `numHosts`, `numEffectiveHosts`, `currentFailoverLevel` — and
where it disagrees with your sum, vCenter is right.

### DRS automation level and per-VM overrides

```bash
govc collect -json "$cluster" configurationEx |
  jq -r 'def b(x): if x == null then "not-configured" else (x|tostring) end;
    .[0].val.drsConfig | "DRS enabled=\(b(.enabled))  mode=\(.defaultVmBehavior // "-")"'
govc cluster.override.info -json "$cluster"
```

`fullyAutomated` is what makes `host.maintenance.enter` evacuate by itself. Under
`partiallyAutomated` or `manual`, entering maintenance blocks until *you* migrate the VMs,
and a runbook that does not say so looks like it hung.

Test `enabled` against `null` explicitly rather than with jq's `//`. That operator fires on
`false` as well as `null`, so it reports a cluster with DRS deliberately disabled as one
where DRS was never configured — absent means never set up, `false` means set up and off,
and on patch day those lead to different decisions.

**Read `enabled` before you read the mode, and never the mode alone.** Verified on vCenter
7.0.3: a cluster with `drsConfig.enabled = false` still reports
`defaultVmBehavior: fullyAutomated`, because that is the configured default waiting to be
used rather than a statement that it is in use. A pre-flight that checks only the mode will
report "DRS fullyAutomated, evacuation will be automatic" about a cluster where DRS is
switched off — and then the evacuation sits at zero percent while everyone waits.

Ask for `configurationEx` whole. The nested form
`govc collect -s <cluster> configurationEx.drsConfig.enabled` fails against a real vCenter
with `ServerFaultCode: InvalidProperty`; the PropertyCollector does not traverse into that
property. `references/health-check.md` has the same note for the same reason.

`cluster.override.info` is read-class (it ends in `.info`) and shows per-VM DRS overrides —
a VM pinned to `manual` inside a `fullyAutomated` cluster is the single most common reason
an evacuation stalls at 90%.

### VMs that cannot be evacuated

```bash
# what is registered on this host right now
govc collect -json -type m "$host" name runtime.powerState config.template |
  jq -s -r 'def v: if type=="object" and has("_value") then ._value else . end;
    .[] | ([.changeSet[] | {(.name): (.val|v)}] | add) as $p |
    [$p.name, $p["runtime.powerState"], ($p["config.template"] // false)] | @tsv'

# datastores mounted by exactly one host: a VM with files there cannot move off it
govc datastore.info -json |
  jq -r '.datastores[] | select((.host | length) == 1) | .name'
```

`govc collect -type m <hostPath>` returns exactly the VMs registered on that host, which is
what you want — `find` cannot express "on this host" without a property filter.

The recurring blockers, in the order they actually occur:

- **A per-VM DRS override** set to `manual` or `disabled` (from `cluster.override.info`).
- **Local storage.** A VM whose files sit on a datastore mounted by one host only cannot
  vMotion without Storage vMotion, and maintenance mode will not do that for you.
- **An attached local ISO or floppy.** A CD-ROM backed by a host-local `.iso` path pins the
  VM. Disconnecting it is a config change — `standard` tier, and confirm first.
- **Passthrough or USB devices**, and VMs with an affinity rule that has nowhere else to go.
- **Templates**, which are registered but not migratable; and powered-off VMs, which do not
  need migrating unless you pass `-evacuate`.

### Snapshots and pending consolidation

```bash
govc collect -s -type m "$host" name | tr '\n' '\0' |
  xargs -0 -I{} govc find / -type m -name {} -snapshot.currentSnapshot '*'
govc find / -type m -runtime.consolidationNeeded true
```

A VM with a snapshot migrates fine, so this is not a blocker — it is a *risk note*. A host
that reboots while a VM has a deep snapshot chain and pending consolidation is the shape of
the worst patch-day incidents: consolidation kicks in afterwards, the delta files grow, and
the datastore fills. Flag any VM on this host that needs consolidation and recommend
consolidating **before** the window, not during it. `references/snapshots.md` has the audit.

### Running tasks, alarms, hosts already in maintenance

```bash
govc tasks -n 50 -l                          # anything still running?
govc alarms -json                            # bare form, whole inventory
govc find / -type h -runtime.inMaintenanceMode true
govc find / -type h -runtime.connectionState notResponding
```

A cluster that already has a host in maintenance is a no-go: you are about to take the
second one out. Never pass `-ack` to `alarms` — acknowledging them is a state change, it is
denied at `readonly`, and a runbook that quietly cleared the alarms it was supposed to
report on is worse than useless.

### The go / no-go table

End phase 1 with this, before anything moves. Every row is a verdict, not a measurement:

| Check | Finding | Verdict |
|---|---|---|
| Cluster capacity without `esx03` | CPU 62%, memory 74% projected | go |
| DRS automation | `fullyAutomated` | go |
| Per-VM DRS overrides on this host | `db-01` set to `manual` | **blocker** — migrate by hand or clear the override |
| Single-host datastores in use | none | go |
| Local ISOs / passthrough | `build-agent-2` has a host-local ISO attached | **blocker** — disconnect first |
| Snapshots on this host's VMs | 2 VMs, oldest 4 days | risk — consolidate before the window |
| Pending consolidation | none | go |
| Running tasks | none | go |
| Triggered alarms | 1 yellow (datastore 78%) | risk — note it |
| Other hosts in maintenance | none | go |
| Host build | `8.0.2 build-21997540` | recorded |

**Any blocker means stop.** Present the table, name what has to change, and wait. Do not
"try it and see" — a stalled evacuation holds a DRS lock and is far more disruptive to
unpick than the two minutes it takes to clear an override first.

## Phase 2 — evacuate and enter maintenance

```bash
govc host.maintenance.enter -timeout 3600 esx03      # mutate: needs tier standard
```

The host is a **positional** argument, not `-host` — passing only `-host esx03` fails with
a bare `govc: no argument` that says nothing about the cause. `references/host-cluster.md`
covers that trap and the surrounding command family.

`-timeout` is in seconds; `0` blocks forever, which is the wrong choice unattended and the
right one when you are watching. `-evacuate` additionally moves **powered-off** VMs, which
is usually not what you want on a patch window — it turns a two-minute operation into a
long series of relocations for machines that are not running.

### Watching the evacuation

```bash
govc tasks -f                                        # follow, in another shell
govc collect -s "$host" runtime.inMaintenanceMode    # true when it has finished
govc collect -s -type m "$host" name                 # what is still registered here
```

The third command is the one that tells you *why* it is slow: the list shrinks as VMs
migrate, and whatever is left when it stops shrinking is the thing that is stuck.

### When the evacuation stalls

Work down the phase-1 blockers, since a stall is almost always one you waived: a per-VM DRS
override, an attached local ISO, a single-host datastore, a passthrough device, an affinity
rule with nowhere to place the VM, or DRS not being `fullyAutomated`, in which case nothing
was ever going to move on its own and you migrate manually with `govc vm.migrate`.

If it has not progressed in ten minutes and the remaining VMs are none of those, stop and
escalate rather than cancelling — `host.maintenance.exit` on a half-evacuated host leaves
DRS to rebalance on its own schedule and can take longer than letting it finish.

## Phase 3 — the patching itself (not this skill's job)

govc does not drive vSphere Lifecycle Manager, and there is no route through it to a
baseline remediation. The admin patches the host — VLCM, an image cluster remediation, or
`esxcli software profile update` on the host itself — and this runbook waits. Say that
plainly rather than improvising a patch mechanism out of `host.esxcli`.

### Recording build level before and after

The build number is available **read-class**, which matters: it works at `readonly` and it
works unattended.

```bash
govc collect -s "$host" summary.config.product.fullName   # VMware ESXi 8.0.2 build-21997540
govc collect -s "$host" summary.config.product.build      # 21997540
govc collect -s "$host" summary.rebootRequired            # true once a patch is staged
govc collect -s "$host" runtime.bootTime                  # only changes on a real reboot
```

Capture all four before the admin starts and again afterwards. The pair that proves a patch
actually landed is **`build` changed** *and* **`bootTime` newer**. A changed build with an
unchanged `bootTime` means the patch is staged but not live, and `rebootRequired` will
still be `true` — which is exactly the state someone mistakes for "done" at 2am.

Per-VIB detail is one level deeper and costs a tier:

```bash
# host.esxcli is mutate-class — the hook cannot see that this esxcli verb only reads —
# so this is DENIED at tier readonly and needs `standard`. The build check above does not.
govc host.esxcli -host esx03 software vib list
govc host.esxcli -host esx03 system version get
```

Use the build/`fullName` route as the primary evidence and treat the VIB list as optional
detail for a "which components changed" question. At `readonly`, do **not** report that the
patch level is unknown — report the build numbers and note that per-VIB detail was not
collected because `host.esxcli` requires tier `standard`.

**The reboot.** `govc host.shutdown -r esx03` is destroy-class: refused outright at
`standard`, an explicit confirmation at `full`. At `standard` — the tier this runbook
expects — hand it to the admin by name and say exactly what you are waiting for:

> esx03 is in maintenance mode and reports `rebootRequired = true` (build 21997540, patch
> staged). The policy tier is `standard`, so I cannot reboot it. Reboot esx03 from VLCM or
> the host console, then tell me and I will run the post-checks.

## Phase 4 — post-checks and exit

```bash
govc collect -s "$host" runtime.connectionState            # connected?
govc collect -s "$host" summary.config.product.build       # changed?
govc collect -s "$host" runtime.bootTime                   # newer?
govc collect -s "$host" summary.rebootRequired             # false now?
govc collect -s "$host" summary.overallStatus              # green?

govc host.maintenance.exit esx03                           # mutate: needs standard

govc collect -s "$host" runtime.inMaintenanceMode          # false
govc tasks -n 20 -l                                        # DRS moving VMs back
govc alarms -json                                          # nothing new and red
```

Then check the host against its peers, because a cluster where one host is a build behind
is a cluster with unpredictable vMotion compatibility:

```bash
govc collect -json -type h "$cluster" name summary.config.product.build |
  jq -s -r 'def v: if type=="object" and has("_value") then ._value else . end;
    .[] | ([.changeSet[] | {(.name): (.val|v)}] | add) as $p |
    [$p.name, $p["summary.config.product.build"]] | @tsv'
```

Finish with a health check scoped to this cluster — `references/health-check.md`, checks 1,
2, 6 and 7 — rather than repeating those queries here. DRS will not rebalance instantly;
give it a few minutes before reading anything into an uneven distribution.

## Phase 5 — when the host does not come back

Read-only diagnosis, in order of what it rules out:

```bash
govc collect -s "$host" runtime.connectionState    # notResponding vs disconnected
govc collect -s "$host" runtime.powerState         # does vCenter think it is on?
govc events -n 100 -l "$host"                      # what vCenter saw as it went
govc find / -type h -runtime.connectionState notResponding
```

`notResponding` means vCenter has lost the management agent but the host may well still be
running VMs — **do not** treat it as down and do not power anything on elsewhere. Restarting
management agents needs console or SSH access, which is outside this skill.

`disconnected` is different: someone or something disconnected it from vCenter deliberately.

Stop and escalate when the host has not returned within the window the admin expected, when
`connectionState` is `notResponding` and VMs on it are unreachable, or when HA has started
restarting VMs elsewhere — that last one is a live incident, not a patch window, and it
needs a human who can see the console.

Never respond to a host that has not come back by taking the next one out for patching.

## Reporting the result

For a file deliverable use the standard template with `{{REPORT_TITLE}}` = "Patch readiness
— <host>" for phase 1, or "Patch verification — <host>" for phase 4. Lead with the go/no-go
table as the findings section: blockers are `sev-critical`, risks are `sev-warning`, and
every clean check gets its `sev-ok` row, because "checked and found healthy" is the result
that makes the table trustworthy.

Record build and bootTime before and after in the verification report. That pair is the
audit trail — it is what someone reads in six months to answer "was esx03 actually patched
in July".

## Testing against vcsim

The simulator implements `EnterMaintenanceModeTask` and `ExitMaintenanceModeTask`, so the
phase 2 and 4 round-trip is genuinely testable there — `./test-unix.sh --vcsim` does it on a
simulated host. What is *not* testable is any of the arithmetic: vcsim reports empty
`quickStats` for VMs and a zero-filled cluster `usageSummary`, so a capacity projection
computed against it is a page of zeros. Verify phase 1 against a real vCenter before
trusting a number from it.
