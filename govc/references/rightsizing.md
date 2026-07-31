# Right-sizing and reclamation

## Guard tiers

Everything in this file is read-class (`find`, `collect`, `vm.info`, `datastore.ls`,
`disk.ls`, `metric.*`) and runs at any tier including `readonly`. Nothing here changes
vSphere state, and nothing here deletes anything.

## Nothing here deletes anything

Every result is a **candidate**, never a confirmed orphan and never a deletion. The scans
below identify files and configurations that *look* reclaimable from the API's point of
view; the API cannot see why a human left something behind. A folder that looks abandoned
may be a rollback point somebody is relying on next Tuesday.

So: produce a list, put it in front of the admin with sizes and the reason each entry was
flagged, and let them decide. Deleting a VMDK is `datastore.rm`, which is destroy-class and
denied outright at `standard` — that is the design working, not an obstacle to route around.

## Check 1 — powered-off VMs still on disk

Cheapest check, and usually the biggest single number.

```bash
vms=$(govc find / -type m -runtime.powerState poweredOff)
[ -n "$vms" ] && printf '%s\n' "$vms" | tr '\n' '\0' | xargs -0 govc vm.info -json |
  jq -r '[.virtualMachines[]] |
    "poweredOff=\(length) committedGB=\(([.[].summary.storage.committed]|add)/1073741824|floor)",
    (.[] | "\(.name)\t\((.summary.storage.committed/1073741824)|floor)G\t\(.config.hardware.numCPU) vCPU\t\(.config.hardware.memoryMB) MB")' |
  sort -k2 -hr
```

On a small production estate this was the largest single figure by a wide margin: well over
half the VMs powered off, holding roughly a terabyte. That is the
headline number for most reclamation reports, and it needs no metric history at all.

A powered-off VM also still counts against configured vCPU and vRAM totals — see
`references/capacity-planning.md`, where the same VMs push the configured memory ratio to
well above 1:1 while powered-on memory sits comfortably below it.

**Age matters more than size.** Off for a week is a maintenance window; off for a year is a
decision nobody made. If event retention reaches back far enough, the last power-off event
gives the date — but retention is usually far too short (`govc events` caps at 1000 and may
reach only hours; see `references/health-check.md` check 8). When it does not reach, say
"age not determinable from retained events" rather than guessing from file timestamps,
which change for reasons unrelated to the VM being used.

## Check 2 — orphaned VMDKs

The one scan worth real care, because it is the one whose false positives cost data.

### The registered set

```bash
govc find / -type m | tr '\n' '\0' | xargs -0 govc vm.info -json |
  jq -r '.virtualMachines[].layoutEx.file[]? |
    select(.type == "diskDescriptor") | .name' |
  sort -u > /tmp/registered.txt
```

`layoutEx.file[]` entries are `{key, name, type, size, uniqueSize, accessible}`, where
`name` is the full `[datastore] folder/file.vmdk`. Filter on `type == "diskDescriptor"`:
the descriptor is the file a VM references, while `diskExtent` is its `-flat` companion.

### The on-disk set

```bash
: > /tmp/ondisk.txt
for ds in $(govc find / -type s | xargs -n1 basename); do
  govc datastore.ls -dc "$dc" -ds "$ds" -R -l -json |
    jq -r '.[] | (.folderPath | capture("^\\[(?<ds>[^]]+)\\]\\s*/?(?<rest>.*)$")) as $f |
      ($f.rest | sub("/$"; "")) as $rest | .file[]? |
      select(.path | test("\\.vmdk$")) |
      select(.path | test("-(flat|delta|ctk|sesparse|digest|rdmp?)\\.vmdk$") | not) |
      select(.path | test("-[0-9]{6}\\.vmdk$") | not) |
      "[" + $f.ds + "] " + (if $rest == "" then "" else $rest + "/" end) + .path' \
    >> /tmp/ondisk.txt
done
sort -u -o /tmp/ondisk.txt /tmp/ondisk.txt
```

**`folderPath` is not the format you expect, and it is not even one format.** Do not build
the path by concatenation — parse the datastore out and rebuild canonically, as above.
Three shapes are known to occur:

| Source | `folderPath` |
|---|---|
| vCenter 7.x, subfolder | `[datastore1] some-vm/` — space after `]`, trailing slash |
| vcsim, subfolder | `[LocalDS_0]/DC0_C0_RP0_VM0` — no space, no trailing slash |
| either, datastore root | `[datastore1]` — no path component at all |

The registered set uses `[datastore] folder/file.vmdk` with a single space, so anything else
matches nothing and *every* file looks orphaned. That failure is silent and confident: the
first real run of this scan flagged **every file on the datastore** as a candidate, with no
error and no clue.
Normalising all three shapes to the canonical form is what makes the diff meaningful — and
what lets the scan be smoke-tested against the simulator at all.

**Two filters exist because of what a real run flagged.** Companion extents
(`-flat`, `-delta`, `-ctk`, `-sesparse`, `-digest`, `-rdm`) are not independent disks and
must never be listed. Snapshot descriptors are numbered `-000001.vmdk`, `-000002.vmdk`;
they belong to a snapshot chain, and reporting them as orphans invites someone to delete a
live delta.

### The diff

```bash
comm -13 /tmp/registered.txt /tmp/ondisk.txt > /tmp/candidates.txt
```

Then size each candidate by summing its companions — the descriptor itself is a few hundred
bytes, and reporting that as the reclaimable figure understates it by three orders of
magnitude:

```bash
# index every file with its size, then attribute companions to their descriptor
for ds in $(govc find / -type s | xargs -n1 basename); do
  govc datastore.ls -dc "$dc" -ds "$ds" -R -l -json |
    jq -r '.[] | (.folderPath | sub("/$"; "")) as $fp | .file[]? |
      (if ($fp | test("\\]$")) then $fp + " " + .path else $fp + "/" + .path end)
      + "\t" + ((.fileSize // 0)|tostring)'
done > /tmp/allfiles.tsv

while IFS= read -r c; do
    base=${c%.vmdk}
    awk -F'\t' -v c="$c" -v b="$base-" \
      '$1==c || index($1,b)==1 {n+=$2} END {printf "%.1f GB\t%s\n", n/1073741824, c}' \
      /tmp/allfiles.tsv
done < /tmp/candidates.txt | sort -hr
```

`fileSize` is **absent** for zero-byte files, hence `// 0`.

On a small production estate the diff came out at a handful of raw candidates, roughly a
dozen after excluding `-digest` and snapshot deltas — mostly old appliance images in folders
whose VMs were removed without deleting the files.

### False positives you must warn about

Every one of these is legitimately on disk and legitimately unregistered:

- **Templates.** Not returned by `find / -type m` in every layout. Cross-check with
  `govc find / -type m -config.template true`.
- **First-class disks**, which exist independently of any VM by design:
  `govc disk.ls -dc "$dc" -ds "$ds"`. They need a datacenter — without one you get
  `govc: please specify a datacenter`.
- **Content library items and ISO/OVA staging folders**, which are storage by intent.
- **Unresolved linked clones and in-flight clone or migration temp files**, where a
  half-finished operation is still holding files it will clean up itself.
- **The vCenter appliance's own disks**, if the appliance runs on the cluster it manages.

State every hit as a candidate with its reason and its size, and recommend the admin
confirm each against their own records before anything is removed.

## Check 3 — oversized VMs

Configured versus actually used. Memory is where the money is: CPU overcommit is absorbed by
scheduling, memory overcommit is absorbed by ballooning and swap, which users feel.

```bash
govc find / -type m -runtime.powerState poweredOn | tr '\n' '\0' | xargs -0 govc vm.info -json |
  jq -r '.virtualMachines[] |
    select((.summary.quickStats.uptimeSeconds // 0) > 604800) |
    [.name,
     .config.hardware.numCPU,
     .config.hardware.memoryMB,
     (.summary.quickStats.guestMemoryUsage // 0),
     (.summary.quickStats.hostMemoryUsage // 0),
     (.summary.quickStats.balloonedMemory // 0),
     (.summary.quickStats.overallCpuUsage // 0)] | @tsv'
```

Flag a VM only when **all** of these hold: uptime over seven days (so the sample means
something), configured memory at least twice guest memory usage, and ballooned memory zero
(a ballooning VM is under memory pressure — the opposite of oversized).

**`balloonedMemory` is absent, not `0`, when nothing is ballooning** — verified across a
real estate where no VM reported the field at all. Hence `// 0` on every quickStats read
here; treating absence as "unknown" and skipping the VM would exclude precisely the healthy
ones you are looking for.

The gap is usually larger than people expect. On VMs with months of uptime it is routine to
find 20 GB configured against a couple of hundred MB in use, and 2 GB against a few dozen.
Those are candidates worth a conversation, not automatic resizes —
a VM sized for a quarterly batch job looks idle for eleven weeks out of twelve.

QuickStats is a point-in-time reading, so this first pass finds candidates, not conclusions.
Confirm with history before recommending a resize: `references/metrics.md` has the daily
sampling and the p95 arithmetic. A VM idle at the moment you looked is not an oversized VM.

**Right-sizing memory downward requires a power cycle** unless hot-add is enabled. Say so in
the recommendation — an admin planning a "quick win" needs to know it is an outage.

## Check 4 — idle VMs (gated on history)

This one genuinely needs metric history and degrades honestly without it.

Definition, over 30 daily samples: mean CPU < 2%, p95 CPU < 5%, network and disk throughput
at or near zero. All four counters and the reduction are in `references/metrics.md` —
including the trap that percent counters arrive as hundredths, so an unconverted comparison
against `2` is comparing 2% against 200.

Gate first with `metric.interval.info` and `metric.info`. If the daily interval is disabled
or the counters sit above the configured statistics level, **do not** fall back to a
point-in-time reading and call it idle. Degrade explicitly:

> Idle detection not performed — the 24-hour statistics interval is disabled, so no 30-day
> history exists. Powered-on VMs showing near-zero CPU *at the moment of collection* are
> listed separately as low-confidence candidates.

Per `references/report-template.md`, a degraded check is `sev-info`: not `sev-ok`, which
hides that the analysis never ran.

## The reclamation report

`{{REPORT_TITLE}}` = "Reclamation Report". The headline KPI is **reclaimable GB**, with
vCPU and vRAM as secondary cards — that is the number the work is justified against.

Report the four checks as separate sections with separate confidence levels, because they
are not equally certain:

| Check | Confidence | Why |
|---|---|---|
| Powered-off VMs | high | Inventory fact, no inference |
| Orphaned VMDKs | **candidate only** | The API cannot know intent |
| Oversized VMs | medium without history, high with | QuickStats is one sample |
| Idle VMs | none without history | Gated, or not reported |

Never present a single summed "reclaimable" figure that mixes them. An admin acting on
a terabyte of powered-off VMs is on solid ground; acting on orphan candidates
without checking is how a restore gets tested.

## Gotchas

- **`datastore.ls` and `disk.ls` need `-dc` on a multi-datacenter vCenter**, or they fail
  with `please specify a datacenter`.
- **`-R` is slow and heavy.** It walks every folder on every datastore — a few seconds on a
  small estate (119 files on one datastore in 1 s, 696 across four), minutes on a large one,
  and it puts load on the storage layer. Ask before running it, and never run it unattended;
  `references/health-check.md` check 9 links here for exactly that reason.
- **`fileSize` is absent for zero-byte files**, so always `// 0`.
- **vcsim cannot exercise this.** Its datastores hold almost no files and VM `quickStats` is
  empty, so the orphan diff and every sizing number are meaningless there. The command
  surface is testable; the results are not.
