# Performance history — intervals, retention, and trends

## Guard tiers

Everything in this file is read-class (`metric.ls`, `metric.info`, `metric.sample`,
`metric.interval.info`, `collect`) and runs at any tier including `readonly`. Nothing here
changes vSphere state.

## Intervals and what `-i` actually means

`govc metric.sample -i` takes `real | day | week | month | year`, or the numeric interval
id. The names are vCenter's own and they are **not** sample periods — they are the *window*
each rollup covers:

| `-i` | id | Sample period | Default samples | Covers |
|---|---|---|---|---|
| `real` | 20 | 20 s | — | the last hour, from the host |
| `day` | 300 | **5 min** | 288 | past day |
| `week` | 1800 | 30 min | 336 | past week |
| `month` | 7200 | 2 h | 360 | past month |
| `year` | 86400 | **24 h** | 365 | past year |

**`-i day` is not a daily rollup.** It is the "Past Day" interval sampled every five
minutes, and asking it for 30 samples gets you two and a half hours, not a month. Daily
samples are `-i year`, equivalently `-i 86400`. Getting this wrong produces a trend chart
that looks plausible and covers the wrong period, which is worse than an error.

Read the real values rather than trusting the defaults — an operator can disable an
interval or change its retention:

```bash
govc metric.interval.info
```

Measured on vCenter 7.0.3: all four enabled, sample counts exactly as tabled, with the
5-minute interval at statistics **Level 2** and the other three at **Level 1**.

## Is the data there? The two-step gate

Never infer availability from an empty result — see the three absence signatures below.
Gate explicitly, in this order:

```bash
govc metric.interval.info                                   # 1. is 86400 enabled, at what Level?
govc metric.info /DC1/vm/web-01 cpu.usage.average           # 2. is the counter at or below it?
```

`metric.info` prints the counter's own `Level:` and the `Intervals:` it lives in. A counter
is collected when its level is at or below the interval's level. Measured on 7.0.3:
`cpu.usage.average`, `mem.usage.average`, `net.usage.average` and `disk.usage.average` are
all **Level 1** and all list `Past day,Past week,Past month,Past year` — so on a
default-configured vCenter the four counters a trend or idle analysis needs are present at
daily resolution for a year.

`metric.ls -i` filters on a real vCenter, which makes it a fast availability check:

```bash
govc metric.ls -i real /DC1/vm/web-01 | wc -l     # 122 counters, measured
govc metric.ls -i year /DC1/vm/web-01 | wc -l     #  17 counters, measured
```

That 122 → 17 collapse is the statistics level doing its job. Note vcsim does **not**
filter — it returns the same list for every interval — so this check cannot be exercised
against the simulator.

## Reading samples

```bash
govc metric.sample -i 86400 -n 30 -t -instance - /DC1/vm/web-01 cpu.usage.average
```

`-instance -` restricts output to the aggregate; without it a counter with per-device
instances returns one series per device *plus* the aggregate. `-t` adds timestamps in plain
output.

### You get N-1 samples, and the newest is yesterday

Asking for 30 daily samples returns **29**, ending at yesterday's date. The current day has
not been rolled up yet. Do not treat the short array as missing data, and state the window
you actually got — "29 days to 2026-07-29", not "30 days".

### Percent counters are hundredths; rate counters are not

```
plain :  5.48,5.32,5.65,...,3.90  %
-json :   548, 532, 565,..., 390
```

**Divide by 100 when `unit` is `percent`.** Measured: `cpu.usage.average` came back as
384–565 for a VM that plain output showed as 3.84%–5.65%. Reporting the raw JSON number is
how a report claims a VM is running at 565% CPU.

The correction is per-unit, not global. In the same call, `net.usage.average` and
`disk.usage.average` carry `unit: kiloBytesPerSecond` and their values are literal — 0–22
KBps and 259–354 KBps as measured. Branch on `.unit`, never on the counter name:

```bash
govc metric.sample -i 86400 -n 30 -instance - -json /DC1/vm/web-01 \
    cpu.usage.average mem.usage.average net.usage.average disk.usage.average |
  jq -r '.sample[]?.value[]? |
    (if .unit == "percent" then 100 else 1 end) as $d |
    [.name, .unit, (.value | length),
     ((.value | add) / (.value | length) / $d)] | @tsv'
```

### Entities come back as MoRefs, never names

`metric.sample -json` identifies each series only as `.entity.type` / `.entity.value`
(`VirtualMachine/vm-13019`). Build the mapping once and join:

```bash
govc collect -json -type m / name |
  jq -s -r '.[] | [.obj.value, .changeSet[0].val] | @tsv' > /tmp/moref-name.tsv
```

One call for the whole inventory — 44 rows in 1 s on the test estate. See
`references/inventory-reporting.md` for the `collect -type` traps.

## When the data is not there

Three different absences, and **two of them are silent**:

| Case | Output | Exit |
|---|---|---|
| Counter name does not exist | govc usage text | **1** |
| Counter exists but is above the interval's level | empty | **0** |
| Entity has no data (powered off, newly created) | empty | **0** |

Measured: `bogus.counter.average` printed the usage banner and exited 1;
`virtualDisk.numberReadAveraged.average` (a real counter, per-device Level 3) returned
nothing and exited 0; a powered-off VM returned nothing and exited 0.

So an empty result cannot tell you whether the counter is not collected or the VM simply
has no history. That is why the gate above is mandatory. Report the distinction:

- gate says the counter is not collected at this level → **"not collected — statistics
  level too low for `<counter>` at the 24h interval"**, as `sev-info`;
- gate passes but the entity returned nothing → **"no data for this VM in the window"**,
  which for a powered-off VM is the expected answer, not a fault.

Per `references/report-template.md`, a degraded check is `sev-info` — never `sev-ok`, which
hides that the analysis did not happen, and never `sev-warning`, which blames the
environment for a collection gap.

## Fleet-wide sampling

The batch pattern, with the verb literal after `xargs -0` so the guard classifies it read:

```bash
govc find / -type m -runtime.powerState poweredOn | tr '\n' '\0' |
  xargs -0 govc metric.sample -i 86400 -n 30 -instance - -json cpu.usage.average |
  jq -s -r '.[] | .sample[]? | [.entity.value, ((.value[0].value | add) / (.value[0].value | length) / 100)] | @tsv'
```

`jq -s` because a split batch yields one JSON document per invocation.

Measured cost on a 44-VM estate, 30 daily samples of one counter:

| VMs | Wall time | JSON docs | Entities | Bytes |
|---|---|---|---|---|
| 10 | 5 s | 1 | 10 | 22 KB |
| 20 | 5 s | 1 | 20 | 31 KB |
| 44 | 9 s | 1 | 44 | 70 KB |

`entities == n` exactly, and ARG_MAX did not split the batch at 44 — hence one document.
Roughly 1.6 KB and 0.2 s per VM. **The ceiling above 44 is unmeasured**; on a large estate,
expect ARG_MAX to split the argument list, which is why the recipe slurps with `jq -s`
rather than assuming a single document. Sample a subset first and check that the entity
count matches what you asked for before trusting a fleet-wide number.

## Reducing a series

Mean, p95 and a simple slope, in jq — no extra tooling:

```bash
jq -r '.sample[]?.value[]? |
  (if .unit == "percent" then 100 else 1 end) as $d |
  (.value | map(. / $d)) as $v |
  ($v | length) as $n |
  ($v | add / $n) as $mean |
  ($v | sort | .[($n * 0.95 | floor)]) as $p95 |
  # least-squares slope per sample, x = 0..n-1
  ([range(0; $n)] | add / $n) as $mx |
  ([range(0; $n) as $i | ($i - $mx) * ($v[$i] - $mean)] | add) as $cov |
  ([range(0; $n) as $i | ($i - $mx) * ($i - $mx)] | add) as $varx |
  [.name, $n, $mean, $p95, ($cov / $varx)] | @tsv'
```

With `-i 86400` the slope is per day, so a datastore growing 0.4 %/day fills its remaining
headroom in `remaining / 0.4` days — state it that way in a report rather than as a raw
coefficient.

## Gotchas

- **`-i day` is the past-day window at 5-minute resolution, not daily samples.** Daily is
  `-i year` / `-i 86400`.
- **Percent values are hundredths in `-json`.** Branch on `.unit == "percent"`.
- **You get N-1 samples**, newest being yesterday.
- **Empty is not an error and not proof of absence.** Gate with `metric.interval.info` plus
  `metric.info` before concluding anything.
- **`-json` gives MoRefs only.** Always build the name mapping.
- **vcsim returns synthetic data for every interval and does not filter `metric.ls`**, so
  the command surface is testable there but no value, retention or availability claim is.
  Verify against a real vCenter before shipping a number.
