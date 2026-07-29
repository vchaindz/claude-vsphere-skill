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
```

## Identifying a snapshot — the number in `vm.info -json` is the wrong one

`snapshot.revert` and `snapshot.remove` accept exactly three forms:

| Form | Example | Where to get it |
|---|---|---|
| Snapshot name | `pre-patch` | `snapshot.tree` |
| Tree path | `pre-patch/hotfix` | `snapshot.tree -f` |
| Managed object ID | `snapshot-12052` | `snapshot.tree -i` |

**The trap:** `vm.info -json` exposes *two* different identifiers per snapshot, and
the obvious-looking one does not work:

```jsonc
"rootSnapshotList": [{
  "name": "pre-patch",
  "id": 334,                                        // ← NOT accepted by govc
  "snapshot": { "type": "VirtualMachineSnapshot",
                "value": "snapshot-12052" }         // ← this is what govc wants
}]
```

`id` is the vSphere API's per-VM integer (`VirtualMachineSnapshotTree.id`). Passing
it gives:

```
govc: snapshot "334" not found
```

This is harmless — the operation is rejected before anything is touched, so a
failed attempt changes nothing. But do not retry with variations of the number:
switch to the name, the tree path, or the `snapshot-NNNNN` managed object ID.

Note that `snapshot.tree -i` prints the **managed object ID**, not `id` — so the
value it shows is directly usable. When names are ambiguous or duplicated across
a tree, prefer the managed object ID.

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

**Recurse into `childSnapshotList`.** `rootSnapshotList` holds only the top of each
tree, so a flat read reports a 3-deep chain as one snapshot — and deep chains are
precisely what the audit exists to find. Emit the managed object ID too, so the
cleanup step has an identifier that works even when names repeat:

```bash
govc find / -type m -snapshot.currentSnapshot '*' |
  tr '\n' '\0' | xargs -0 govc vm.info -json |
  jq -r 'def nodes: ., (.childSnapshotList[]? | nodes);
         .virtualMachines[] | .name as $n | .snapshot.rootSnapshotList[]? | nodes |
         [$n, .name, .snapshot.value, .createTime] | @tsv'
```
```powershell
function Get-SnapNodes($n) { $n; foreach ($c in $n.childSnapshotList) { Get-SnapNodes $c } }
$vms = govc find / -type m '-snapshot.currentSnapshot' '*'
(govc vm.info -json @vms | ConvertFrom-Json).virtualMachines | ForEach-Object {
  $vm = $_.name
  foreach ($root in $_.snapshot.rootSnapshotList) {
    Get-SnapNodes $root | ForEach-Object {
      [pscustomobject]@{ VM = $vm; Snapshot = $_.name
                         Id = $_.snapshot.value; Created = $_.createTime }
    }
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

1. Produce the audit report above; show it to the user. Keep the `snapshot-NNNNN`
   managed object ID in the report — it is the identifier you will delete with.
2. Get confirmation on the exact list of VM/snapshot pairs to delete.
3. **Delete by managed object ID only.** Not by the `id` integer from
   `vm.info -json` (see "Identifying a snapshot" above), and not by name.

   ```bash
   govc snapshot.remove -vm my-vm snapshot-12052    # yes
   govc snapshot.remove -vm my-vm pre-patch         # no — see below
   govc snapshot.remove -vm my-vm '*'               # no — see below
   ```

   govc does fail safe on a duplicate name — `govc: "pre-patch" resolves to 2
   snapshots`, and nothing is removed — so this is not about silently deleting
   the wrong snapshot. It is about **stable identity**: a name that resolves
   uniquely while you are producing the audit can resolve to something else by
   the time the user approves the list, because a backup job or another admin
   can create a snapshot in between. The managed object ID cannot drift.

   **Never use `'*'` in cleanup.** It removes the entire tree in one call, which
   is not the list the user approved, and it consolidates everything at once.
   Approving a list means deleting exactly that list.
4. Remove oldest-first, one VM at a time; consolidation I/O is heavy, so avoid mass-parallel deletion on the same datastore.
5. Verify: re-run the audit; check `tasks` for RemoveSnapshot_Task completion and any consolidation warnings.
