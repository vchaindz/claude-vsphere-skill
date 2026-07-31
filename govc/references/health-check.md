# Environment health check

## What makes this a checklist (and not a query)

A health check is a **fixed, ordered list**: the same nine checks, in the same order, with
the same thresholds, every time. That is the whole point. An improvised sweep answers
"is anything wrong right now"; a checklist answers "what changed since yesterday", which
is the question an admin actually has — and it is only answerable if yesterday's run
asked the same questions.

So: do not skip a check because it seems unlikely to fire, and do not add one because
something looks interesting. Report the extra finding, by all means, but keep the nine.
A category that comes back clean is a `sev-ok` row, not silence.

This file carries **no threshold numbers**. Every one of them lives in
`references/report-template.md` under `## Severity thresholds`, so that the health check,
the capacity report and the patch-day runbook cannot drift apart. Read that file too —
it is short, and without it you cannot assign a severity.

Every command here is read-class: it runs at guard tier `readonly` and changes nothing.
Two rules keep it that way, and both matter:

- **Never let a `$VAR` or `$( )` sit in the govc subcommand position.** The policy hook
  cannot see what an unresolved verb will become, so it treats it as destroy-class and
  denies it. Write `xargs -0 govc vm.info -json`, never `xargs -0 $GOVC vm.info`.
- **Never pass `-ack` to `govc alarms`.** That acknowledges the alarms — it clears the
  operator's own warning signal, and a report that silently did it is worse than no
  report. The guard classifies `alarms -ack` as a mutation and denies it at `readonly`,
  including through a variable, but do not rely on that to keep yourself honest.

## Order of work

1. `govc about` — product, version, build. **If this fails, stop.** No data is not the
   same as no findings; report the connection failure and emit nothing else.
2. Discover scope: `govc ls /`, `govc find / -type c`, `govc find / -type h`,
   `govc find / -type m`. The counts become `{{SCOPE}}`.
3. Run checks 1–8 in order. Each is one batched call, not a per-object loop.
4. Ask about check 9 only if the user is present and the environment is small enough to
   be worth it.
5. Read the baseline file (below) and compute the diff.
6. Emit the report, then write the baseline.

## 1. Hosts — connection state, maintenance mode, uptime

```bash
govc collect -json -type h / name runtime.connectionState runtime.inMaintenanceMode \
    summary.quickStats.uptime summary.config.product.build |
  jq -s -r 'def v: if type=="object" and has("_value") then ._value else . end;
    .[] | ([.changeSet[] | {(.name): (.val|v)}] | add) as $p |
    [$p.name, $p["runtime.connectionState"], $p["runtime.inMaintenanceMode"],
     (($p["summary.quickStats.uptime"] // 0) / 86400 | floor),
     $p["summary.config.product.build"]] | @tsv'
```
```powershell
# no jq: ConvertFrom-Json per line, then flatten the changeSet into a hashtable
govc collect -json -type h / name runtime.connectionState runtime.inMaintenanceMode |
  ForEach-Object { $_ | ConvertFrom-Json } | ForEach-Object {
    $p = @{}; $_.changeSet | ForEach-Object { $p[$_.name] = $_.val }
    [pscustomobject]$p }
```

Anything other than `connected` is critical. A host in maintenance mode is critical *if
nobody put it there on purpose* — say so as a question in the finding rather than
guessing. Uptime is in seconds; a host whose uptime dropped below a day since the last
run rebooted, and an unexplained reboot is worth a warning.

`collect -type` reads one property set from every object of a type in a single call —
see `references/inventory-reporting.md` for the two traps it carries (flags before the
root, and the `{"_value":[…]}` wrapper on array properties).

**Do not quote these property names with a leading dash**, in PowerShell or anywhere else.
The usage is `collect [OPTIONS] [MOID] [PROPERTY]...`, so properties are *positional*; a
token beginning with `-` is parsed as an option and rejected. The skill's rule about
quoting dotted flags applies to `find` filters like `'-runtime.powerState'`, which really
are flags — writing `'-runtime.inMaintenanceMode'` here breaks the call instead of
protecting it.

## 2. Triggered alarms

```bash
govc alarms -json |
  jq -r '.[]? | [(.overallStatus // "-"), (.path // .entity.value // "-"),
                 (.name.name // .name.systemName // "-"),
                 (.name.systemName // .name.name // "-"),
                 (.acknowledged | tostring)] | @tsv'
```

**The shape is not what the field names suggest.** `.entity` and `.alarm` are both bare
MoRefs (`{"type":"Folder","value":"group-d1"}`) — neither carries a name. The alarm's
definition sits at the **top level** as `.name`, an AlarmInfo object with `.name`,
`.systemName` and `.description`. Neither `.alarm.info.name` nor `.entity.name` exists at
all, and getting this wrong yields a table of `-` in every column rather than an error.
`.path` is a `Type:value` pair (`Folder:group-d1`), not an inventory path — useful as a
stable identifier, not as something to show a human on its own.

**Print `.name.name`; key on `.name.systemName`. They are different fields for different
jobs, and the fourth column above exists to keep them apart.**

- `.name.name` is the human-readable label — *"Host memory usage"*, *"Root user password
  expired."* This is what belongs in a report.
- `.name.systemName` is vCenter's own identifier for its built-in alarms —
  `alarm.HostMemoryUsageAlarm`. Stable across triggers, so it is the right baseline key,
  but printing it puts a dotted constant in front of a human.

**`.systemName` is absent on any alarm vCenter did not define itself** — verified against a
live 7.x vCenter, where the triggered appliance alarms carried `.name.name` and no
`.systemName` at all. So both readings need the fallback shown above, in opposite orders,
and a baseline key built on `.systemName` alone silently collapses every operator-created
alarm into one.

Through `wrapper/govc-safe` the two fields also behave differently: `.name.name` is
operator text and is redacted, while `.systemName` is a vSphere constant and passes
through. That is the reverse of what you might expect, and it is why the wrapper's own
health check leads with the status and the entity rather than the label.

Use the **bare form**. Triggered alarms propagate up the inventory hierarchy and `PATH`
already defaults to `/`, so one call returns every triggered alarm in the environment —
a per-datacenter loop adds nothing, and a path passed through a variable is denied at
tier `readonly` anyway (the variable could expand to `-ack`).

`red` is critical, `yellow` is warning. `alarms -json` is a **bare array**, not an object
with a named key, and it emits nothing at all when nothing is triggered — so
`jq '.[]?'` with the `?`, and never `jq -e`, which would exit non-zero on the empty case
and read as a failed command.

## 3. Datastore capacity and accessibility

```bash
govc datastore.info -json |
  jq -r '.datastores[] |
    [.name, .summary.accessible,
     (.summary.capacity/1073741824|floor),
     (.summary.freeSpace/1073741824|floor),
     (if (.summary.capacity // 0) > 0
      then ((1 - .summary.freeSpace/.summary.capacity) * 100 | floor)
      else "n/a" end)] | @tsv'
```

**Never filter on capacity.** An unmounted or unreachable datastore reports capacity `0`,
so `select(.summary.capacity > 0)` drops exactly the rows this check exists to raise — the
inaccessible ones — before `accessible` is ever read. Guard the *division* instead, which
is the only thing capacity `0` actually breaks: without the guard it yields `null`
percentages that sort to the top of the report looking like the healthiest volume in the
estate.

`accessible: false` is critical regardless of capacity, and a datastore reporting `n/a`
usage is a finding, not a gap in the data. With more than one datacenter,
`datastore.info` needs a context — set `GOVC_DATACENTER` or loop `-dc` over
`govc find / -type d`, and treat `datastore '*' not found` from an empty datacenter as
"no datastores here", not as an error.

## 4. Snapshots — age, chain depth, size

```bash
vms=$(govc find / -type m -snapshot.currentSnapshot '*')
[ -n "$vms" ] && printf '%s\n' "$vms" | tr '\n' '\0' |
  xargs -0 govc vm.info -json |
  jq -r 'def nodes: ., (.childSnapshotList[]? | nodes);
    def depth: 1 + ([.childSnapshotList[]? | depth] | max // 0);
    .virtualMachines[] | . as $vm |
    [$vm.name,
     ([$vm.snapshot.rootSnapshotList[]? | nodes]     | length),
     ([$vm.snapshot.rootSnapshotList[]? | depth]     | max),
     ([$vm.snapshot.rootSnapshotList[]? | nodes | .createTime] | min)] | @tsv'
```

Columns: name, **total snapshots**, **deepest chain**, oldest `createTime` — and the two
numbers are not the same question. Counting every node answers "how much sprawl"; the
`> 3 in a chain` threshold is about *depth*, because it is a long delta chain that makes
consolidation slow and risky. A VM with four independent root snapshots one level deep
counts 4 and has depth 1; reporting the count against the depth threshold raises a
critical that is not there.

**Guard the empty case.** With no matching VMs, GNU `xargs` still runs the command once
with no arguments, so `vm.info` is invoked bare and fails — turning a clean result into a
failed check. BSD `xargs` skips it, so this only breaks on Linux. The `[ -n "$vms" ]` test
is the portable fix; `xargs -r` is GNU-only and would fail on macOS.

The recursion is the point. `rootSnapshotList` holds only the top of each tree, so a flat
read reports a three-deep chain as one snapshot — and deep chains are exactly what the
check exists to find. `references/snapshots.md` has the full treatment.

Snapshot **size** is not reported per snapshot by this endpoint. Do not infer it. For the
VMs this check flags, `govc snapshot.tree -vm.ipath <path> -f -s -D` gives sizes one VM at
a time; if you do not run it, the report says "not collected" and says why.

Also fold in the VMs that need consolidation, which are a different failure:

```bash
govc find / -type m -runtime.consolidationNeeded true
```

## 5. VMware Tools on powered-on VMs

```bash
vms=$(govc find / -type m -runtime.powerState poweredOn)
[ -n "$vms" ] && printf '%s\n' "$vms" | tr '\n' '\0' |
  xargs -0 govc vm.info -json |
  jq -r '.virtualMachines[] |
    select((.guest.toolsRunningStatus // "") != "guestToolsRunning") |
    [.name, (.guest.toolsRunningStatus // "-"), (.guest.toolsVersionStatus2 // "-")] | @tsv'
```

Powered-on only — Tools not running on a powered-off VM is not a finding. `tr '\n' '\0' |
xargs -0` is mandatory: VM paths routinely contain spaces (`/DC1/vm/My App Server`), which
bare `xargs` splits into separate arguments, and `xargs -d '\n'` is a GNU extension that
fails on macOS with `xargs: illegal option -- d`. The `[ -n "$vms" ]` guard is the same
empty-input protection as check 4 — an estate with everything powered off would otherwise
run `vm.info` with no arguments and report a failure instead of a clean result.

## 6. Cluster HA / DRS / admission control

**There is no `govc cluster.info`.** It does not exist in any govc release; the cluster's
configuration comes from its `configurationEx` property — read as **one whole struct**:

```bash
govc find / -type c | while IFS= read -r c; do
    govc collect -json "$c" configurationEx |
      jq -r --arg c "$c" 'def b(x): if x == null then "not-configured" else (x|tostring) end;
        .[0].val |
        [$c, b(.dasConfig.enabled), b(.dasConfig.admissionControlEnabled),
         b(.drsConfig.enabled), (.drsConfig.defaultVmBehavior // "-")] | @tsv'
done
```
```powershell
govc find / -type c | ForEach-Object {
  $x = (govc collect -json $_ configurationEx | ConvertFrom-Json)[0].val
  [pscustomobject]@{
    Cluster = $_
    HA      = $x.dasConfig.enabled
    AdmCtl  = $x.dasConfig.admissionControlEnabled
    DRS     = $x.drsConfig.enabled
    DrsMode = $x.drsConfig.defaultVmBehavior
  } }
```

**Do not ask for a nested path.** `govc collect -s <cluster> configurationEx.dasConfig.enabled`
looks like it should work and fails on real vCenter with `ServerFaultCode: InvalidProperty` —
the PropertyCollector will not traverse into `configurationEx`. It costs nothing to get
wrong in a simulator, which accepts the nested form happily, and then fails against every
real vCenter. Ask for `configurationEx` and pick the fields out of the JSON. That is also
one API call per cluster instead of four.

**Three states, not two — and jq's `//` destroys the distinction.** A property that is
absent is `null` (never configured); one that is present and `false` is configured and
switched off. Those are different findings. The alternative operator `//` fires on `false`
as well as `null`, so `.dasConfig.enabled // "not-configured"` reports a cluster with HA
deliberately *disabled* as one where HA was never set up. Test for `null` explicitly, as the
`def b(x)` above does. This is not hypothetical: real vCenter 7.x returns
`dasConfig.enabled = false`, while vcsim returns `dasConfig` as an empty object, so the two
environments exercise both branches.

**`defaultVmBehavior` is populated even when DRS is off.** Verified on vCenter 7.x: a
cluster with `drsConfig.enabled = false` still reports `defaultVmBehavior: fullyAutomated`,
because that is the configured default waiting to be used, not a statement that it is in
use. Read `enabled` first and only then the mode; reporting the mode alone says DRS is
fully automated on a cluster where it is switched off.

Judge HA and DRS only on clusters with more than one host; a single-host cluster has
nothing to fail over to, and flagging it is noise the reader learns to ignore. Get the host
count from `govc collect -s -type h "$c" name`, which returns empty for an empty cluster.

`collect` is read-class and the subcommand is literal in every call above, so this passes
at tier `readonly` — the `"$c"` in argument position is fine, because the guard only treats
an unresolved *subcommand* as dangerous.

## 7. Orphaned, inaccessible and invalid VMs

```bash
govc find / -type m -runtime.connectionState orphaned
govc find / -type m -runtime.connectionState inaccessible
govc find / -type m -runtime.connectionState invalid
```
```powershell
govc find / -type m '-runtime.connectionState' orphaned
govc find / -type m '-runtime.connectionState' inaccessible
govc find / -type m '-runtime.connectionState' invalid
```

Three calls, because `govc find` has no negation and no `or` — a property filter takes one
value. All three are critical: the VM exists in vCenter but its files are unreachable or
its configuration is unreadable, which means it is neither running nor recoverable without
intervention.

## 8. Recent errors — over the window you can actually reach

**Do not call this check "the last 24 hours".** On a real vCenter you almost certainly
cannot see that far, and the heading is the first thing a reader trusts.

```bash
# NEVER exceed -n 1000. Above the cap this returns ZERO events, not an error and not a
# truncated list, so `jq -s` computes "0 errors" and the report says all clear.
ev=$(govc events -n 1000 -l -json | jq -s '.')

# state the window that actually came back, before reporting anything about it
printf '%s' "$ev" | jq -r '"window covered: \([.[].createdTime]|min) .. \([.[].createdTime]|max)  (\(length) events)"'

printf '%s' "$ev" | jq -r '
    [.[] | select(.category == "error")]
    | group_by(.eventTypeId // .type) | sort_by(-length)
    | .[] | [length, (.[0].eventTypeId // .[0].type // "-")] | @tsv'

# tasks DO take a real time window, so this half genuinely covers 24 hours
govc tasks -b 24h -n 1000 -l -json |
  jq -s -r '[.[] | select(.state == "error")] | "failed tasks (24h): \(length)"'
```

Measured on a vCenter 7.x with a few dozen VMs: **1000 events reached back about three
hours**, and 500 reached half that. A busier estate reaches less. So this check answers "has anything gone
wrong recently", not "in the last day", and the report must name the real window —
`sev-info`, with the span in the `.desc`.

Three traps, each of which produces a confidently empty report:

- **`-n` above 1000 returns nothing at all.** Verified: 1000 → 1000 events, 1001 → 0, 1500
  → 0, with no error on stderr and exit 0. Asking for "more than a day's worth" is exactly
  the instinct that yields a silent all-clear. The cap is the ceiling, not a suggestion.
- **`govc events` has no time window** — only `-n`. There is no flag that fixes the above;
  the reach is whatever 1000 events happens to span, which is a property of how busy the
  vCenter is. `govc tasks` is different and does take `-b` / `-e`, which is why the failed
  task count above can honestly claim 24 hours.
- **`fromdateiso8601` rejects vSphere timestamps.** Every one carries fractional seconds,
  which jq's parser will not accept; strip them (`sub("\\.[0-9]+"; "")`) or compare the
  strings lexically, which works because the format is fixed-width UTC. If you do filter by
  time, note that a `date`-derived cutoff needs the GNU/BSD fallback
  (`date -u -d '24 hours ago'` vs `date -u -v-24H`) — but with a 3-hour reach the cutoff
  rarely excludes anything, and reporting the true span is more useful than filtering.

Escalate only on a pattern — the same object named repeatedly, or a count far above the
usual — and say what the finding corroborates rather than raising it alone.

## 9. Orphaned VMDK scan (optional, slow — ask first)

**Ask before running this, and never run it unattended.** It walks every folder on every
datastore; on a large estate it takes minutes and produces load on the storage layer that
an admin did not agree to.

The scanner itself lives in `references/rightsizing.md`, where the same diff is used for
the reclamation report — it is written once there rather than twice. That file carries the
path-joining trap that makes every file look orphaned if you get it wrong. Follow the pointer if
the user says yes. Whatever it returns is a **candidate**, never a confirmed orphan, and
this report never proposes deleting one.

If you skip it — which is the default, and always the case in an unattended run — say so
in the report: skipped, and why.

## Baseline diff — "changed since last run"

Write one small JSON file next to the report, with a **fixed name and no date**:

```
health-check-<environment>.baseline.json
```

The fixed name is what makes discovery possible: read that one path, and "file not found"
means first run. A dated name would force you to list a directory and reason about which
file is second-newest. The dated audit trail already exists — it is the reports.

```jsonc
{
  "schema": 1,
  "environment": "acme-prod",
  "generatedAt": "2026-07-30T06:32:11+02:00",
  "report": "health-check-acme-prod-2026-07-30.html",
  "eventWindowCovered": "2026-07-29T04:12:00Z..2026-07-30T06:31:00Z",
  "scope":      { "datacenters": 2, "clusters": 3, "hosts": 14, "vms": 412 },
  "thresholds": { "datastoreWarnPct": 75, "datastoreCritPct": 85,
                  "snapshotWarnDays": 3, "snapshotCritDays": 7, "snapshotCritChain": 3 },
  "counts":     { "critical": 2, "warning": 5, "ok": 4, "info": 1,
                  "hostsConnected": 13, "hostsTotal": 14,
                  "alarmsRed": 1, "alarmsYellow": 3,
                  "datastoresOverWarn": 2, "datastoresInaccessible": 0,
                  "vmsWithSnapshots": 12, "maxSnapshotAgeDays": 91, "maxChainDepth": 4,
                  "toolsNotRunning": 7, "clustersHaOff": 1,
                  "vmsOrphaned": 1, "errorEvents": 18, "failedTasks": 3 },
  "findings": {
    "host-state:/DC1/host/ClusterA/esx03":                             "critical",
    "vm-state:/DC1/vm/old-app":                                        "critical",
    "alarm:/DC1/host/ClusterA/esx03:alarm.HostConnectionFailureAlarm": "critical",
    "ds-capacity:/DC1/datastore/LocalDS_0":                            "warning",
    "snapshot:/DC1/vm/sql01":                                          "warning",
    "tools:/DC1/vm/web-07":                                            "warning",
    "cluster-ha:/DC1/host/ClusterB":                                   "warning"
  },
  "skipped": { "orphaned-vmdk": "slow, not requested" }
}
```

`findings` is an **object, not an array**: a map cannot churn on ordering, and the diff is
three set operations — keys that are new, keys that are gone, keys whose value changed.

Key scheme is `<check-slug>:<inventory-path>`, with `alarm:` taking a third field:

| Check | Key |
|---|---|
| 1 hosts | `host-state:<host path>` |
| 2 alarms | `alarm:<.path>:<.name.systemName // .name.name>` — `.path` is the `Type:value` MoRef pair. The fallback is not optional: `.systemName` is absent on every alarm vCenter did not define itself, so keying on it alone collapses all of them into one |
| 3 datastores | `ds-capacity:<datastore path>` · `ds-access:<datastore path>` |
| 4 snapshots | `snapshot:<vm path>` · `consolidate:<vm path>` |
| 5 Tools | `tools:<vm path>` |
| 6 clusters | `cluster-ha:` · `cluster-ac:` · `cluster-drs:` + `<cluster path>` |
| 7 VM state | `vm-state:<vm path>` |
| 8 events | none — counts only |
| 9 VMDK | `vmdk:<datastore path>/<file>`, only when the scan ran |

Three rules make the keys stable, and stability is the whole value of the file:

- **Identity is the inventory path** as `govc find` prints it. Cost: a rename or a folder
  move shows up as one resolved finding plus one new one. Say that in the report rather
  than letting the reader think a VM was rebuilt. In an estate that renames routinely,
  switch to MoRefs (`govc find -i`) and say so in the file.
- **Never put a measured value in a key.** `ds-capacity:/DC1/datastore/LocalDS_0`, not
  `…:94%`. Severity is the map *value*, so a warning escalating to critical is visible
  without the key changing — which is exactly the transition worth reporting.
- **Never key on a transient identifier.** An alarm's `.key` is per-trigger, an event's is
  per-event, and snapshot MoRefs come and go with the chain. Key alarms on
  `.alarm.info.systemName`, and snapshots per VM rather than per snapshot.

Check 8 gets no per-item keys deliberately: individual events are transient, so keying
them would churn 100% every run and drown the diff. Store the counts and the top three
event types, and compare those numerically.

**Order of operations:** read the baseline, emit the report, *then* overwrite the baseline.
Never write it first — a crash in between would destroy the comparison point and the next
run would silently report "first run".

Render the diff without touching `assets/report-template.html`:

- one extra card in `{{KPI_CARDS}}`, and it leads: `<div class="kpi sev-critical"><div
  class="n">+2 / &minus;1</div><div class="l">Findings vs 2026-07-29</div></div>`, neutral
  class unless the diff contains a new critical;
- a `<section id="changes">` emitted **first** inside `{{SECTIONS}}`, with New / Worse /
  Resolved badge rows and a `.desc` naming the baseline file and its date;
- the baseline filename in `{{FOOTER_NOTE}}`.

Not `{{FINDINGS_ROWS}}` — a *Resolved* row has no severity, and mixing it in would break
the critical → warning → ok → info ordering the findings table guarantees.

## Output

File deliverable → the HTML template, `{{REPORT_TITLE}}` = "Environment Health Check". KPI
cards: hosts connected, triggered alarms, datastores over threshold, oldest snapshot, plus
the baseline-diff card. Everything else about structure, escaping and severity is in
`references/report-template.md`.

No file asked for → a Markdown summary in chat: one line per check with its severity, worst
first, then the detail for anything critical. Do not write a file nobody asked for.

## Unattended runs

If the prompt says unattended — see `SKILL.md` § Unattended runs for the full contract —
then: skip check 9, apply the default thresholds, write to the directory named in the
prompt, and end with the `GOVC-REPORT` line. Ask nothing. A question in an unattended run
is not a pause, it is a failed run.

## Testing against vcsim

Checks 1, 3, 4, 5, 6 and 7 work against vcsim and return real (if small) results. Checks 2
and 8 do not: vcsim's alarm and event logs are essentially empty, so the assertion worth
writing is that the command parses and exits 0, **not** that findings appear. Check 9 is
not worth running there at all — vcsim's datastores have almost no files.

`./test-unix.sh --vcsim` covers exactly that split.
