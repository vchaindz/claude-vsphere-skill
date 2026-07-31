---
name: govc-private
description: Manage and report on VMware vSphere/ESXi through the govc-safe wrapper, which returns pseudonymised data only. Use this skill instead of the plain govc skill whenever the environment has govc-safe installed, or when the user says vSphere data must not leave their network, mentions PII, GDPR, confidentiality, or asks to avoid sharing infrastructure details. Covers inventory, capacity and snapshot reporting, health checks, and VM/host lifecycle actions using stable tokens (VM-0001, HOST-01) rather than real names.
---

# govc-private — vSphere management without exposing real identifiers

This environment routes every vSphere call through **`govc-safe`**, a wrapper that
holds the credentials and replaces real identifiers with stable tokens before you
see anything. You will never see a real VM name, hostname, IP, MAC or username —
and you do not need one to do the work.

Invoke it as:

```bash
govc-safe <verb> [args...]
```

## What you will see

```
$ govc-safe find / -type m
/DC-01/vm/VM-0001
/DC-01/vm/VM-0002
```

`VM-0001` is a **stable token**. The same VM is always `VM-0001`, across commands
and across sessions, so you can correlate freely: if `VM-0001` appears in a
snapshot audit and again in a capacity report, it is the same machine.

**Pass tokens straight back in.** The wrapper resolves them to the real object
before calling vCenter:

```bash
govc-safe vm.info -json VM-0001
govc-safe vm.power -off VM-0017
```

Token prefixes: `DC` datacenter, `VM` virtual machine, `HOST` ESXi host,
`CLUSTER`, `DS` datastore, `NET`/`PG` network/portgroup, `DVS`, `POOL` resource
pool, `FOLDER`, `SNAP` snapshot, `ALARM` alarm, plus `IP`, `MAC`, `UUID`,
`USER`, `FQDN` for values found in output.

**Alarm labels are tokens, alarm identifiers are not.** An alarm can be named
anything an admin typed, including after a customer, so its label comes back as
`ALARM-01`. vCenter's own identifier for the alarms it ships —
`alarm.HostMemoryUsageAlarm` in `.name.systemName` — is a product constant and
passes through. Report the token: `ALARM-02 (red)` counts, correlates and diffs
like any other. Do not reach for `.systemName` when the label is a token; it is
absent on exactly the operator-created alarms whose names were worth hiding.

## Rules

1. **Never try to obtain real names.** Do not ask the user for them, do not try
   to infer them, and do not suggest running plain `govc`. The credentials are
   not in this environment; direct `govc` cannot authenticate and is blocked.

2. **Write tokens freely — the operator already sees real names.** Their terminal
   rehydrates your replies as they render, so when you write "VM-0001 is powered
   on" they read "ACME-PROD-SQL01 is powered on". You do not need to apologise
   for tokens, offer to translate them, or ask which VM they meant. Just use the
   tokens naturally and the operator's screen does the rest.

   **Never run `govc-safe rehydrate` yourself.** That pulls real identifiers into
   this conversation, which is the one thing the setup exists to prevent. For a
   file, write it in tokens and mention they can run
   `govc-safe rehydrate report.tsv` if they want a cleartext copy on disk.

3. **If the user pastes a real name** ("what's wrong with ACME-PROD-SQL01?"),
   tell them plainly that it just entered the transcript, and ask them to use
   the token instead. Then continue with the token.

4. **Count before you list.** A count answers most reporting questions and emits
   no identifiers at all. Reach for the list only once the user needs to act on
   specific objects.

   ```bash
   govc-safe find / -type m -runtime.powerState poweredOff | wc -l
   ```

5. **Aggregate before row-level.** "12 of 340 VMs have snapshots older than 30
   days, worst is 91 days" is usually a better answer than 12 rows, and costs
   nothing in identifiers.

6. **Free text is gone by design.** Annotations, snapshot descriptions and event
   messages are replaced with `[redacted: free text]`, because arbitrary prose
   cannot be reliably pseudonymised. Do not tell the user a VM "has no
   annotation" — say the annotation was withheld.

   **Managed object references survive, as tokens.** `"self"`, `"parent"`,
   `"host"`, `"datastore"` and friends come back as
   `{"type": "VirtualMachine", "value": "VM-0001"}`. That `value` is the same
   token the object carries everywhere else, so it is your join key: use it to
   correlate objects across two JSON outputs rather than matching on names.

7. **Prefer `-json`.** On the JSON path the wrapper walks the parsed document
   and rewrites values only, so keys and structure are exact. Plain-text output
   has no such structure, so a VM named after a field label (`config`, `name`,
   `host`) can cause a label to be tokenised too. That is over-redaction, never a
   leak — but `-json` avoids it.

8. **Safety rules still apply**, exactly as for unrestricted govc: read-only
   first; confirm before anything destructive, naming the affected **tokens**;
   graceful shutdown before hard power-off; snapshots are not backups.

9. **Snapshots: remove by `SNAP-nn` token only.** The wrapper refuses
   `snapshot.remove` by name and refuses `'*'` outright — those are not bugs to
   work around. Get the token from `snapshot.tree -vm VM-0001 -i` and remove one
   snapshot per call:

   ```bash
   govc-safe snapshot.tree -vm VM-0001 -i     # -> [SNAP-01] ...
   govc-safe snapshot.remove -vm VM-0001 SNAP-01
   ```

   A name can resolve to a different snapshot between your audit and the
   operator's approval; the token cannot. `'*'` would delete the whole tree
   rather than the list that was approved. When auditing, recurse into
   `childSnapshotList` — `rootSnapshotList` alone reports a deep chain as a
   single snapshot, hiding exactly the sprawl you are looking for.

   Snapshot names are pseudonymised like everything else, so `SNAP-01` is all
   you will see. If the operator needs the real names, they rehydrate.

## Available verbs

Read: `about`, `ls`, `find`, `tree`, `collect`, `vm.info`, `host.info`,
`datastore.info`, `datacenter.info`, `cluster.usage`, `pool.info`,
`snapshot.tree`, `metric.ls`, `metric.sample`, `metric.info`,
`metric.interval.info`, `events`, `tasks`, `alarms`.

Write: `vm.power`, `vm.migrate`, `snapshot.create`, `snapshot.remove`,
`host.maintenance.enter`, `host.maintenance.exit`.

Anything else is refused with an explanation. **A refusal is not a bug and not a
permissions problem — do not work around it.** `guest.*`, `host.esxcli`, `logs`,
`datastore.tail`, `permissions.ls`, `sso.*` and `about.cert` are excluded
because their output cannot be redacted safely.

Flags fall into two groups, and the difference matters because the same letter
means different things on different verbs:

- **Refused on every verb**: `-trace`, `-verbose`, `-debug`, `-dump`, `-xml`,
  `-password`, `-u`, `-k`, `-cert`, `-key`, `-e`. These either write raw SOAP
  past the redactor or put credentials on a command line.
- **Refused only where they would leak or never return**: `-l` on `events`,
  `tasks` and `alarms`, whose long forms print the free-text message; `-f` on
  `events` and `tasks`, which follows a stream forever. The same letters are
  fine elsewhere and you should use them — `ls -l`, `find -l`, `about -l`,
  `snapshot.tree -f` (full path, not follow), `collect -s`, `metric.sample -i`.

If a question genuinely needs a refused flag, say so and let the user run it
themselves.

## Health check

The same nine checks as the plain govc skill, in the same order, as counts — no
identifiers. Thresholds, severities, the report structure and the baseline diff
are **not** repeated here: they live in the plain skill's
`references/health-check.md`, and if that file and this section ever disagree,
that file wins.

```bash
govc-safe find / -type h | wc -l                                        # 1 hosts total
govc-safe find / -type h -runtime.connectionState connected | wc -l     #   ...connected
govc-safe find / -type h -runtime.inMaintenanceMode true | wc -l        #   ...in maintenance
govc-safe alarms -json | jq '[.[]? | select(.overallStatus == "red")] | length'  # 2 red alarms
govc-safe datastore.info -json | jq '[.datastores[]
  | select(.summary.capacity > 0)
  | select(1 - (.summary.freeSpace / .summary.capacity) > 0.85)] | length'       # 3 over 85%
govc-safe find / -type m -snapshot.currentSnapshot '*' | wc -l          # 4 VMs with snapshots
govc-safe find / -type m -runtime.consolidationNeeded true | wc -l      #   ...needing consolidation
govc-safe find / -type m -runtime.powerState poweredOn | tr '\n' '\0' |
  xargs -0 govc-safe vm.info -json | jq '[.virtualMachines[]
  | select((.guest.toolsRunningStatus // "") != "guestToolsRunning")] | length'  # 5 Tools down
govc-safe find / -type c | while IFS= read -r c; do
  govc-safe collect -json "$c" configurationEx |
  jq -r '.[0].val.dasConfig.enabled'; done | grep -c false                # 6 clusters, HA off
for st in orphaned inaccessible invalid; do                               # 7 all three states
  govc-safe find / -type m -runtime.connectionState "$st" | wc -l; done
govc-safe events -n 1000 -json | jq -s '[.[] | select(.category == "error")] | length'    # 8
# 9 (orphaned-VMDK scan) is slow and opt-in — ask first, never in an unattended run
```

`grep -c false` exits 1 when the count is zero. That is not a failure — it means
every cluster has HA on. Ask for `configurationEx` whole: the nested form
`collect -s "$c" configurationEx.dasConfig.enabled` fails on a real vCenter with
`ServerFaultCode: InvalidProperty`.

Two things about check 8 that a count alone will misrepresent:

- **`-n` is the only window there is.** `govc events` has no time filter, and
  above 1000 it returns nothing at all rather than erroring. On a busy vCenter
  1000 events can span two or three hours, not a day. Report the window you
  actually reached — take `min` and `max` of `.createdTime` and say so — never
  "errors in the last 24 hours".
- **Message text is redacted**, so a per-type breakdown is not available here.
  Counts and the window are what the wrapper can honestly give you, which is
  also why `-l` is refused for this verb.

Two rules override the checklist in token space:

- **Counts before names.** Lead with one number per check, then offer to list the
  tokens for any category the user wants to act on. Printing tokens is safe —
  that is what the wrapper is for — but a nine-check report opening with 400
  tokens is unreadable.
- **`-json` only.** Plain-text output has no structure to redact against, so a VM
  named after a field label can have the label tokenised alongside it.

The report and the baseline file are written in tokens; say so in the footer and
mention `govc-safe rehydrate <file>`.

## Reporting

Deliver reports in tokens and write them to a file, so the user can rehydrate
the file rather than a chat message:

```bash
govc-safe find / -type m | tr '\n' '\0' |
  xargs -0 govc-safe vm.info -json |
  jq -r '.virtualMachines[] |
    [.name, .runtime.powerState, .config.hardware.numCPU,
     .config.hardware.memoryMB] | @tsv' > snapshot-report.tsv
```

Then tell the user: *"Written to `snapshot-report.tsv` in tokens — run
`govc-safe rehydrate snapshot-report.tsv` to see real names."*

## What this does and does not protect

It stops real identifiers reaching the model provider on the normal path, which
is where leaks actually happen. It is an anonymisation tool, not a security
boundary: it runs as the same user you do, so it cannot stop someone determined
to go around it — and it is **not** a substitute for a least-privilege vCenter
role, which is what prevents unwanted changes.

Structure still leaks by design: counts, cluster sizes, guest-OS versions and
ESXi build numbers survive pseudonymisation, because removing them would remove
the point of the reports. If build numbers are themselves sensitive, say so —
they map to published CVEs.

The wrapper is installed and tested on Linux and macOS. On Windows it is run
from WSL or Git Bash; there is no tested native PowerShell installation.
