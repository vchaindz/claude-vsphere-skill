# Inventory, reporting, and monitoring

## Discovering the environment

```bash
govc ls /                        # datacenters
govc ls /DC1                     # vm, host, datastore, network folders
govc tree /DC1                   # whole inventory as a tree
govc find / -type c              # clusters   (aliases: m=VM, h=host, s=datastore,
govc find / -type h              #             n=network, p=resource pool, d=datacenter)
govc find /DC1/vm -name 'web-*'  # glob matching
govc find . -type m -runtime.powerState poweredOn     # filter by property
govc find -l -I /                # long listing with type and MOID
```

```powershell
# identical except that dotted flags must be quoted (PowerShell splits them otherwise)
govc find . -type m '-runtime.powerState' poweredOn
```

`find` filters on any object property (`KEY VAL` pairs); discover property names with `govc collect -s <path>`.

## Object details

```bash
govc vm.info my-vm                       # summary
govc vm.info -r my-vm                    # + resources (host, datastore, network)
govc vm.info -e my-vm                    # + extraConfig
govc vm.info -json my-vm                 # machine-readable, full detail
govc host.info -host esx01
govc datastore.info
govc datacenter.info
govc pool.info '*/Resources'
govc cluster.usage ClusterA              # cluster CPU/mem/storage utilization
```

`collect` (alias `object.collect`) reads arbitrary properties — the fastest way to get one field from many objects:

```bash
govc collect -s vm/my-vm summary.runtime.powerState
govc collect -s vm/my-vm guest.ipAddress
govc collect -s host/cluster1/esx01 summary.quickStats.overallCpuUsage
```

## Fleet-wide reports

Pattern: `find` to enumerate → `-json` to extract → `jq` to shape. Examples:

**VM inventory (name, power, CPU, memory, guest OS, IP):**
```bash
govc find / -type m | tr '\n' '\0' | xargs -0 govc vm.info -json |
  jq -r '.virtualMachines[] | [.name, .runtime.powerState, .config.hardware.numCPU,
         .config.hardware.memoryMB, .guest.guestFullName, (.guest.ipAddress // "-")] | @tsv'
```
```powershell
$vms = govc find / -type m
(govc vm.info -json @vms | ConvertFrom-Json).virtualMachines |
  Select-Object name,
    @{n='Power';e={$_.runtime.powerState}},
    @{n='CPU';e={$_.config.hardware.numCPU}},
    @{n='MemoryMB';e={$_.config.hardware.memoryMB}},
    @{n='GuestOS';e={$_.guest.guestFullName}},
    @{n='IP';e={if ($_.guest.ipAddress) { $_.guest.ipAddress } else { '-' }}}
```

`tr '\n' '\0' | xargs -0` is deliberate: VM paths often contain spaces
(`/DC1/vm/My App Server`), which bare `xargs` would split into separate arguments. Do not
substitute `xargs -d '\n'` — that is a GNU extension and fails on macOS with
`xargs: illegal option -- d`.

**Datastore capacity report:** (in multi-datacenter vCenters, datastore/host commands
error with "please specify a datacenter" — set `GOVC_DATACENTER` or loop with `-dc`
over `govc find / -type d`. An *empty* datacenter returns "datastore '*' not found";
treat that as "no datastores here", not as an error)
```bash
govc datastore.info -json | jq -r '.datastores[] |
  [.name, (.summary.capacity/1073741824|floor), (.summary.freeSpace/1073741824|floor)] | @tsv'
```
```powershell
(govc datastore.info -json | ConvertFrom-Json).datastores |
  Select-Object name,
    @{n='CapacityGB';e={[math]::Round($_.summary.capacity/1GB)}},
    @{n='FreeGB';e={[math]::Round($_.summary.freeSpace/1GB)}}
```

**Powered-off VMs (reclamation candidates):**
```bash
govc find / -type m -runtime.powerState poweredOff
```
```powershell
govc find / -type m '-runtime.powerState' poweredOff
```

**VMs with snapshots (see `references/snapshots.md` for details):**
```bash
govc find / -type m -snapshot.currentSnapshot '*'
```
```powershell
govc find / -type m '-snapshot.currentSnapshot' '*'
```

**Host hardware/version inventory:** (`host.info` without `-host` fails when there are
multiple hosts — enumerate with `find` and pass each explicitly)
```bash
govc find / -type h | tr '\n' '\0' | xargs -0 -n1 -I{} govc host.info -json -host {} |
  jq -r '.hostSystems[] |
  [.name, .summary.config.product.fullName, .summary.hardware.model,
   .summary.hardware.numCpuCores, (.summary.hardware.memorySize/1073741824|floor)] | @tsv'
```
```powershell
govc find / -type h | ForEach-Object {
  (govc host.info -json -host $_ | ConvertFrom-Json).hostSystems
} | Select-Object name,
    @{n='Product';e={$_.summary.config.product.fullName}},
    @{n='Model';e={$_.summary.hardware.model}},
    @{n='Cores';e={$_.summary.hardware.numCpuCores}},
    @{n='MemoryGB';e={[math]::Round($_.summary.hardware.memorySize/1GB)}}
```

For large environments avoid per-VM loops; batch paths into a single `vm.info`/`collect` invocation via `xargs -0` (bash) or array splatting with `@paths` (PowerShell) whenever possible. `host.info` is the exception — it takes one `-host` at a time.

When the user wants a deliverable, format the TSV/JSON into a Markdown table, CSV, or styled HTML file.

## Performance metrics

```bash
govc metric.ls vm/my-vm                          # what metrics exist for this object
govc metric.sample vm/my-vm cpu.usage.average mem.usage.average
govc metric.sample -n 30 vm/my-vm cpu.usage.average      # last 30 samples
govc metric.sample host/cluster1/* cpu.usage.average     # all hosts in a cluster
govc metric.info vm/my-vm cpu.usage.average              # units, rollup, interval
```

Use `-json` for parsing; instance `""` is the aggregate. Real-time samples are 20-second intervals; historical intervals are controlled by vCenter (`metric.interval.info`).

## Events, tasks, alarms, logs

```bash
govc events -n 50                        # last 50 events, whole inventory
govc events vm/my-vm                     # events for one object
govc events -type VmPoweredOffEvent -type VmPoweredOnEvent
govc events -f                           # follow (stream)
govc tasks                               # recent tasks
govc tasks -f                            # follow tasks
govc alarms                              # triggered alarms, whole inventory
govc alarms -ack /DC1/host/cluster1      # acknowledge
govc logs -log vpxd:vpxd.log -n 100      # vCenter logs; govc logs.ls lists log keys
```

Good audit answers: "who deleted VM X?" → `govc events -type VmRemovedEvent`; "why did this
VM reboot?" → `govc events vm/my-vm | grep -i reboot` (PowerShell:
`govc events vm/my-vm | Select-String reboot`).

## Health-check playbook

A quick environment health sweep:

```bash
govc about                                        # version/build
govc alarms                                       # anything red/yellow?
govc find / -type h -runtime.connectionState notResponding   # dead hosts
govc find / -type h -runtime.inMaintenanceMode true          # hosts in maintenance
govc find / -type m -snapshot.currentSnapshot '*' # snapshot sprawl
govc find / -type m -runtime.consolidationNeeded true        # disks needing consolidation
govc events -n 100 -type com.vmware.vc.HA.FailoverEvent      # recent HA events

# datastores over 85% full
govc datastore.info -json | jq -r '.datastores[] |
  select(1 - (.summary.freeSpace / .summary.capacity) > 0.85) |
  [.name, ((1 - .summary.freeSpace / .summary.capacity) * 100 | floor)] | @tsv'
```

```powershell
govc about
govc alarms
govc find / -type h '-runtime.connectionState' notResponding
govc find / -type h '-runtime.inMaintenanceMode' true
govc find / -type m '-snapshot.currentSnapshot' '*'
govc find / -type m '-runtime.consolidationNeeded' true
govc events -n 100 -type com.vmware.vc.HA.FailoverEvent

# datastores over 85% full
(govc datastore.info -json | ConvertFrom-Json).datastores |
  Where-Object { (1 - $_.summary.freeSpace / $_.summary.capacity) -gt 0.85 } |
  Select-Object name,
    @{n='UsedPct';e={[math]::Floor((1 - $_.summary.freeSpace / $_.summary.capacity) * 100)}}
```

Summarize findings by severity; propose (but don't execute) remediation.
