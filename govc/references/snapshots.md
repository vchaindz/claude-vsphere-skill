# Snapshots

Snapshots are point-in-time delta disks — **not backups**. They grow with every write and degrade performance when old or deep. Say this when users treat them as backups.

## Commands

```bash
govc snapshot.create -vm my-vm "pre-upgrade $(date +%F)"
govc snapshot.create -vm my-vm -d "before patch 7.0u3" -m=false pre-patch
#   -m   include memory state (default true; false = crash-consistent but fast)
#   -q   quiesce filesystem via VMware Tools (for app consistency)

govc snapshot.tree -vm my-vm                 # hierarchy; current marked
govc snapshot.tree -vm my-vm -f -s -D -i     # full paths, size, created date, id

govc snapshot.revert -vm my-vm pre-patch     # revert to named snapshot
govc snapshot.revert -vm my-vm               # revert to current snapshot

govc snapshot.remove -vm my-vm pre-patch     # deletes/consolidates that snapshot
govc snapshot.remove -vm my-vm '*'           # remove ALL — confirm first!
#   ambiguous names: use snapshot ID from snapshot.tree -i
```

```powershell
# only the date-stamped name differs; the rest of the commands above work as written
govc snapshot.create -vm my-vm "pre-upgrade $(Get-Date -Format yyyy-MM-dd)"
```

Reverting discards all changes since the snapshot — confirm with the user and note whether the VM will come back powered off (memoryless snapshots restore to powered-off state).

## Snapshot audit (common reporting request)

Find all VMs with snapshots:

```bash
govc find / -type m -snapshot.currentSnapshot '*'
```
```powershell
govc find / -type m '-snapshot.currentSnapshot' '*'
```

Detailed report with age and size:

```bash
govc find / -type m -snapshot.currentSnapshot '*' |
  tr '\n' '\0' | xargs -0 -I{} govc snapshot.tree -vm.ipath {} -f -s -D
```
```powershell
govc find / -type m '-snapshot.currentSnapshot' '*' |
  ForEach-Object { govc snapshot.tree '-vm.ipath' $_ -f -s -D }
```

Or via JSON for precise data:

```bash
govc find / -type m -snapshot.currentSnapshot '*' |
  tr '\n' '\0' | xargs -0 govc vm.info -json |
  jq -r '.virtualMachines[] | .name as $n | .snapshot.rootSnapshotList[]? |
         [$n, .name, .createTime] | @tsv'
```
```powershell
$vms = govc find / -type m '-snapshot.currentSnapshot' '*'
(govc vm.info -json @vms | ConvertFrom-Json).virtualMachines | ForEach-Object {
  $n = $_.name
  $_.snapshot.rootSnapshotList | ForEach-Object {
    [pscustomobject]@{ VM = $n; Snapshot = $_.name; Created = $_.createTime }
  }
}
```

`tr '\n' '\0' | xargs -0` rather than `xargs -d '\n'`: the `-d` form is GNU-only and fails
on macOS. Both handle VM paths containing spaces; bare `xargs` does not.

Flag as problems: snapshots older than 72 hours, chains deeper than 2–3, snapshot delta size over ~10% of VM disk. Also check consolidation-needed state:

```bash
govc find / -type m -runtime.consolidationNeeded true
```
```powershell
govc find / -type m '-runtime.consolidationNeeded' true
```

## Cleanup workflow

1. Produce the audit report above; show it to the user.
2. Get confirmation on the exact list of VM/snapshot pairs to delete.
3. Remove oldest-first, one VM at a time; consolidation I/O is heavy, so avoid mass-parallel deletion on the same datastore.
4. Verify: re-run the audit; check `tasks` for RemoveSnapshot_Task completion and any consolidation warnings.
