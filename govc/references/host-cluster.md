# Hosts, clusters, DRS/HA, resource pools

## Host information and lifecycle

```bash
govc host.info                                   # default/all hosts
govc host.info -host esx01
govc host.date.info -host esx01                  # NTP/time config
govc host.storage.info -host esx01               # HBAs/LUNs
govc host.vnic.info -host esx01                  # vmkernel NICs
govc host.service.ls -host esx01                 # services (ssh, ntpd, ...)
govc host.service -host esx01 start TSM-SSH      # start/stop/restart/status
govc host.option.ls -host esx01 Config.HostAgent # advanced settings
```

Add / remove hosts:

```bash
# get thumbprint, then add to cluster
thumbprint=$(govc about.cert -k -u esx-new.example.com -thumbprint | awk '{print $2}')
govc cluster.add -cluster ClusterA -hostname esx-new.example.com \
  -username root -password '...' -thumbprint "$thumbprint"
govc host.add -hostname esx02 -username root -password '...' -noverify   # standalone
govc host.disconnect -host esx01
govc host.reconnect -host esx01
govc host.remove -host esx01                     # confirm first
```

```powershell
# no awk in PowerShell — split the line instead
$thumbprint = (govc about.cert -k -u esx-new.example.com -thumbprint) -split '\s+' |
  Select-Object -Last 1
govc cluster.add -cluster ClusterA -hostname esx-new.example.com `
  -username root -password '...' -thumbprint $thumbprint
```

## Maintenance mode (patching workflow)

```bash
govc host.maintenance.enter esx01                # DRS should evacuate VMs first
govc host.maintenance.exit  esx01
```

The host is a **positional** argument here, not `-host`. Verbs whose usage line ends in
`HOST...` (`host.maintenance.enter`/`.exit`, `host.shutdown`) require at least one
positional host and fail with a bare `govc: no argument` if you pass only `-host esx01` —
an error that says nothing about the cause. `-host` is the selector only for verbs that
take no host positionally (`host.info`, `host.esxcli`, `host.portgroup.*`). Check with
`govc <verb> -h`: the usage line is authoritative. The same trap exists for
`vm.info`/`vm.power` (VM is positional; there is no `-vm` flag) and `datastore.info`
(no `-ds` flag).

Safe sequence for one host: check cluster has capacity (`cluster.usage`), enter maintenance (this blocks until VMs are evacuated — with DRS in fullyAutomated it's automatic; otherwise migrate VMs manually with `vm.migrate`), do the work (or `host.shutdown esx01 [-r]` for reboot — confirm first), exit maintenance, verify with `host.info` and `alarms`.

## esxcli passthrough

Anything govc lacks natively can often be done via esxcli on the host:

```bash
govc host.esxcli -host esx01 system version get
govc host.esxcli -host esx01 network ip connection list
govc host.esxcli -host esx01 storage core device list
govc host.esxcli -host esx01 software vib list
```

## Clusters

```bash
govc cluster.create ClusterB
govc cluster.change -drs-enabled -drs-mode fullyAutomated ClusterA
govc cluster.change -ha-enabled ClusterA
govc cluster.change -drs-vmotion-rate=3 ClusterA
govc cluster.usage ClusterA                      # capacity/utilization
govc cluster.mv -cluster ClusterA esx01          # move host into cluster
```

## DRS rules and groups (affinity/anti-affinity)

```bash
# VM groups and host groups
govc cluster.group.create -cluster ClusterA -name web-vms -vm web-01 web-02
govc cluster.group.create -cluster ClusterA -name rack1-hosts -host esx01 esx02
govc cluster.group.ls -cluster ClusterA

# anti-affinity: keep VMs apart
govc cluster.rule.create -cluster ClusterA -name web-anti -enable -anti-affinity web-01 web-02
# affinity: keep together
govc cluster.rule.create -cluster ClusterA -name app-db -enable -affinity app-01 db-01
# VM-host rule: pin group to hosts
govc cluster.rule.create -cluster ClusterA -name pin-web -enable -vm-host \
  -vm-group web-vms -host-affine-group rack1-hosts
govc cluster.rule.ls -cluster ClusterA
govc cluster.rule.remove -cluster ClusterA -name web-anti
```

Per-VM DRS/HA overrides: `cluster.override.info/change/remove`.

## Resource pools

```bash
govc pool.create -cpu.shares high -mem.limit 16384 /DC1/host/ClusterA/Resources/prod
govc pool.info /DC1/host/ClusterA/Resources/*
govc pool.change -mem.reservation 8192 /DC1/host/ClusterA/Resources/prod
govc pool.destroy /DC1/host/ClusterA/Resources/prod   # confirm; VMs move to parent
```
```powershell
govc pool.create '-cpu.shares' high '-mem.limit' 16384 /DC1/host/ClusterA/Resources/prod
govc pool.info /DC1/host/ClusterA/Resources/*
govc pool.change '-mem.reservation' 8192 /DC1/host/ClusterA/Resources/prod
govc pool.destroy /DC1/host/ClusterA/Resources/prod
```

## Permissions, roles, tags (governance reporting)

```bash
govc permissions.ls
govc role.ls                                     # defined roles
govc role.usage                                  # where each role is assigned
govc tags.category.ls                            # tag categories
govc tags.ls                                     # tags
govc tags.attach -c env prod vm/my-vm
govc tags.attached.ls -r prod                    # objects with tag
govc fields.ls                                   # custom attributes
```
