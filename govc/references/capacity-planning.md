# Capacity planning — ratios, N+1 headroom, growth

## Guard tiers

Everything in this file is read-class (`collect`, `find`, `cluster.usage`, `*.info`,
`metric.*`) and runs at any tier including `readonly`. Nothing here changes vSphere state.

## What you need before you start

Two numbers are the user's to choose, not yours to assume. Ask, or state the defaults you
applied — a headroom figure computed against unstated targets is a number nobody can argue
with, which is the opposite of useful.

| Input | Default | Why it is a choice |
|---|---|---|
| Target vCPU : physical core | 4:1 | Depends entirely on workload. A VDI estate lives at 8:1; a latency-sensitive database cluster wants 1:1. |
| Target vRAM : physical RAM | 1:1 of *effective* memory | Memory is not time-sliced the way CPU is. Overcommitting it means ballooning and swap, which is a performance cliff rather than a gradual slope. |
| Datastore ceiling | 80% | Leaves room for snapshot growth and thin-disk inflation. |
| Basis | N+1 | See below — this is the one default you should not change. |

**N+1 is the basis for every ratio and headroom number in this file.** A cluster that only
fits its workload with every host up has no headroom at all: it cannot survive a host
failure, and it cannot be patched without degrading service. Report the all-hosts number as
context and raise the finding against the N+1 number.

## Part 1 — where you are now

### Inputs, in three calls

```bash
cluster=/DC1/host/ClusterA

# 1. the cluster's own view
govc collect -json "$cluster" summary |
  jq -r '.[0].val | "totalCpuMHz=\(.totalCpu) effectiveCpuMHz=\(.effectiveCpu)
totalMemBytes=\(.totalMemory) effectiveMemMB=\(.effectiveMemory)
hosts=\(.numHosts) effectiveHosts=\(.numEffectiveHosts) failoverLevel=\(.currentFailoverLevel)"'

# 2. per-host capacity and current load
govc collect -json -type h "$cluster" name \
    summary.hardware.numCpuCores summary.hardware.numCpuThreads \
    summary.hardware.cpuMhz summary.hardware.memorySize \
    summary.quickStats.overallCpuUsage summary.quickStats.overallMemoryUsage |
  jq -s -r 'def v: if type=="object" and has("_value") then ._value else . end;
    .[] | ([.changeSet[] | {(.name): (.val|v)}] | add) as $p |
    [$p.name,
     $p["summary.hardware.numCpuCores"],
     ($p["summary.hardware.numCpuCores"] * $p["summary.hardware.cpuMhz"]),
     ($p["summary.hardware.memorySize"] / 1048576 | floor),
     $p["summary.quickStats.overallCpuUsage"],
     $p["summary.quickStats.overallMemoryUsage"]] | @tsv'

# 3. what the VMs are configured to want
govc find / -type m | tr '\n' '\0' | xargs -0 govc vm.info -json |
  jq -r '[.virtualMachines[]] |
    "vms=\(length) vCPU=\([.[].config.hardware.numCPU]|add) vRAM_MB=\([.[].config.hardware.memoryMB]|add)",
    "poweredOn=\([.[]|select(.runtime.powerState=="poweredOn")]|length) vCPU_on=\([.[]|select(.runtime.powerState=="poweredOn")|.config.hardware.numCPU]|add) vRAM_on_MB=\([.[]|select(.runtime.powerState=="poweredOn")|.config.hardware.memoryMB]|add)"'
```

**Units differ per field, including inside the same struct.** Verified on vCenter 7.0.3:

| Field | Unit |
|---|---|
| `summary.totalCpu`, `effectiveCpu` | **MHz** |
| `summary.totalMemory` | **bytes** |
| `summary.effectiveMemory` | **MB** — in the same object as `totalMemory` |
| `summary.hardware.memorySize` | **bytes** |
| `summary.quickStats.overallCpuUsage` | **MHz** |
| `summary.quickStats.overallMemoryUsage` | **MiB** |

Mixing `totalMemory` and `effectiveMemory` because they sit side by side is the single
easiest way to be wrong by a factor of a million here.

**Total vs effective.** `totalCpu` is the raw sum of `numCpuCores × cpuMhz`; `effectiveCpu`
is what remains for VMs after virtualisation overhead and reservations. Measured on a
32-core host: 79,840 MHz total against 71,082 MHz effective — about 11% gone before a
single VM runs. **Plan against effective**, and check your arithmetic against
`cluster.usage`, whose `cpu.capacity` equals `totalCpu` exactly. That agreement is the
cheap proof your per-host sum is right before you build anything on it.

**Count cores, not threads.** `numCpuThreads` is double `numCpuCores` on any
hyperthreaded host. Sizing against threads silently doubles your apparent capacity, and
the second thread of a core is not a second core.

### The ratios

```
vCPU : core        = Σ configured vCPU              / Σ numCpuCores
vRAM : memory      = Σ configured memoryMB          / effectiveMemory(MB)
storage provisioned = Σ committed + Σ uncommitted   / Σ datastore capacity
```

Compute each twice — for all VMs, and for powered-on VMs only. The gap between them is
your dormant demand: capacity you are not using today but have already promised.

Worked example, from a single-host cluster (32 cores, ~2.5 GHz, 256 GB):

| Ratio | All VMs (44) | Powered-on (18) |
|---|---|---|
| vCPU : core | 113 / 32 = **3.53:1** | 48 / 32 = **1.50:1** |
| vRAM : effective | 345,472 / 248,896 = **1.39:1** | 191,488 / 248,896 = **0.77:1** |

Read that pair carefully before reporting it. Powered-on memory fits comfortably; the
*configured* total already exceeds physical memory by 39%. Nothing is wrong today, and
nothing will be until enough of those 26 powered-off VMs start at once.

### The same ratios without one host (N+1)

```bash
# capacity with the largest host removed — the worst single failure
govc collect -json -type h "$cluster" name summary.hardware.numCpuCores \
    summary.hardware.cpuMhz summary.hardware.memorySize |
  jq -s -r 'def v: if type=="object" and has("_value") then ._value else . end;
    [.[] | ([.changeSet[] | {(.name): (.val|v)}] | add)
         | {name: .name,
            cpu: (.["summary.hardware.numCpuCores"] * .["summary.hardware.cpuMhz"]),
            cores: .["summary.hardware.numCpuCores"],
            mem: (.["summary.hardware.memorySize"] / 1048576 | floor)}] as $h |
    ($h | max_by(.cpu)) as $biggest |
    "all hosts : cores=\($h|map(.cores)|add) cpuMHz=\($h|map(.cpu)|add) memMiB=\($h|map(.mem)|add)",
    "minus \($biggest.name) : cores=\(($h|map(.cores)|add) - $biggest.cores) cpuMHz=\(($h|map(.cpu)|add) - $biggest.cpu) memMiB=\(($h|map(.mem)|add) - $biggest.mem)"'
```

Remove the **largest** host, not an average one — N+1 has to survive the worst single
failure, and a mixed cluster is exactly where averaging hides the problem.

**A single-host cluster has no N+1 at all.** Removing its only host leaves zero capacity,
so every headroom number is 0 and every ratio is undefined. That is a finding in itself,
not a division error to code around: report "no failure capacity — a single host outage
takes the whole cluster down", and say the headroom question cannot be answered until a
second host exists. The example cluster above is exactly this case.

## Part 2 — how much more fits

### The profile

Ask for one, or state what you assumed: **vCPU, GB RAM, GB disk** per VM. "How many more
VMs fit" is meaningless without it — the answer for a 1-vCPU/2 GB appliance and a
16-vCPU/128 GB database differ by two orders of magnitude.

### The formula

```
remaining_cores = Σ numCpuCores  (N+1 basis)
remaining_mem   = effectiveMemory MB  (N+1 basis)
remaining_disk  = Σ (datastore capacity × ceiling%) − Σ (committed + uncommitted)

fit_cpu   = (remaining_cores × target_vcpu_ratio − Σ configured vCPU) / profile_vcpu
fit_mem   = (remaining_mem   × target_ram_ratio  − Σ configured vRAM) / profile_ram_mb
fit_disk  =  remaining_disk / profile_disk_gb

headroom  = floor(min(fit_cpu, fit_mem, fit_disk))
```

**Report all three, not just the minimum.** The binding constraint is the actionable
result: "12 more VMs, limited by memory" tells an admin what to buy. A bare "12" does not,
and if the three numbers are wildly apart that itself is worth saying.

Show the arithmetic in the report. A consultant has to defend the number in a room, and
"the tool said 12" is not a defence.

### Worked example

Same cluster, profile 4 vCPU / 8 GB / 100 GB, targets 4:1 and 1:1, 80% datastore ceiling.
As a single-host cluster it has no N+1 basis, so this is computed **all-hosts** and labelled
as such — which is precisely the caveat that makes the number honest:

```
fit_cpu  = (32 × 4  − 113)      / 4    = 3.75  → 3
fit_mem  = (248896 × 1 − 345472) / 8192 = negative → 0
fit_disk = (6130 × 0.80 − 5761)  / 100  = 1.14  → 1
headroom = 0, limited by memory
```

Configured memory already exceeds effective memory, so on paper there is no room for
another VM at a 1:1 target — while powered-on memory sits at 0.77:1 and the cluster feels
idle. Both statements are true. Report them together: the estate has run out of *committed*
memory headroom long before it runs out of *used* memory, and that is the number that
matters the day everything powers on at once.

## Part 3 — growth trend (gated)

Only attempt this when the statistics are actually there. `references/metrics.md` has the
gate and the arithmetic; the short version:

```bash
govc metric.interval.info      # is the 86400 interval enabled, and at what level?
govc metric.info "$cluster" cpu.usage.average mem.usage.average
```

If the daily interval is disabled, or the counter sits above the configured statistics
level, report **"not collected — statistics retention insufficient for a trend"** as
`sev-info` and stop. Do not extrapolate from a week of five-minute samples to a year;
per `references/report-template.md`, never fabricate a value, and a degraded check is
`sev-info` — not `sev-ok`, which hides that the analysis did not happen.

When the data is there, sample daily and express the slope as time-to-full, which is the
only form anyone acts on:

```
days_to_threshold = (capacity × ceiling − current) / slope_per_day
```

State the window the samples actually covered, not the window you asked for.

## Rendering the report

`{{REPORT_TITLE}}` = "Capacity Report". KPI cards: current vCPU:core, vRAM ratio, headroom
for the stated profile, and the binding constraint named. Sections:

1. **Inputs** — targets, profile, and the N+1 basis, stated before any result. This is what
   makes the report reproducible and arguable.
2. **Current ratios** — all VMs and powered-on, side by side.
3. **N+1 view** — the same with the largest host removed.
4. **Headroom** — all three fit numbers with the arithmetic shown, minimum highlighted.
5. **Storage** — per datastore, with the thin-provisioning overhang (below).
6. **Growth** — or the "not collected" note with the reason.

Thresholds are in `references/report-template.md`; this file states none of its own.

## Gotchas

- **Thin provisioning is the overhang that bites.** `summary.uncommitted` on a datastore is
  what thin disks would consume if every one inflated. Measured on a real datastore:
  a datastore reporting roughly 500 GB free against nearly 1 TB uncommitted — fully
  inflating its thin disks needs about twice the space that exists. That is a `sev-warning` on provisioned-vs-capacity even though the
  used percentage looks fine, and it is invisible if you only report free space. vcsim does
  not expose `uncommitted` at all, so this can only be checked against a real vCenter.
- **A powered-off VM still holds its storage and its promise.** It contributes to
  provisioned storage and to configured vCPU/vRAM totals, and it will contribute to *load*
  the moment someone starts it. Count it in the configured ratios; the powered-on ratio is
  the second number, not the only one.
- **Reservations are not modelled here.** A VM with a memory reservation removes that
  memory from availability whether or not it uses it, and admission control reasons about
  reservations rather than configured sizes. If the cluster uses reservations heavily, say
  so and treat these numbers as an upper bound.
- **`currentFailoverLevel` is HA's own answer** to "how many host failures can I take". If
  it disagrees with your arithmetic, it is right and you are missing a reservation or an
  admission-control policy. Report both rather than picking one.
- **vcsim cannot exercise any of this.** It reports no VM `quickStats`,
  `summary.storage.committed` of 234 bytes and a zero-filled `usageSummary`, so every ratio
  computed against it is zero or undefined. Parts 1 and 2 are structurally testable there;
  the numbers must come from a real vCenter.
