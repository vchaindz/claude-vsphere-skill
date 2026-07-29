# Datastores, disks, and networking

## Datastores

```bash
govc datastore.info                              # capacity/free/type for all
govc datastore.ls -ds datastore1                 # browse files
govc datastore.ls -l -ds datastore1 my-vm/       # long listing of a VM folder
govc datastore.upload -ds datastore1 local.iso iso/local.iso
govc datastore.download -ds datastore1 my-vm/vmware.log ./vmware.log
govc datastore.tail -ds datastore1 -n 50 my-vm/vmware.log
govc datastore.tail -ds datastore1 -n 50 -f my-vm/vmware.log   # -f follows the file
govc datastore.mkdir -ds datastore1 iso
govc datastore.cp -ds datastore1 src.iso dst.iso   # copy between paths
govc datastore.mv -ds datastore1 src.iso dst.iso   # move/rename
govc datastore.rm -ds datastore1 old-file.iso    # confirm first
govc datastore.create -type nfs -name nfs1 -remote-host filer -remote-path /vol/nfs1 esx01
govc datastore.remove -ds olddatastore esx01     # unmount — confirm first
govc datastore.maintenance.enter -ds ds1         # storage DRS maintenance
govc datastore.maintenance.exit  -ds ds1
govc datastore.cluster.info                      # datastore clusters (SDRS)
```

Capacity report and orphaned-file hunting are common asks — see `references/inventory-reporting.md` for the jq pattern; for orphans compare `datastore.ls` folders against registered VM paths (`govc find / -type m` + `collect -s ... config.files.vmPathName`).

## Virtual disks

```bash
govc vm.disk.create -vm my-vm -name my-vm/data -size 100GB -thick=false
govc vm.disk.change -vm my-vm -disk.label "Hard disk 2" -size 200GB    # grow only
govc device.ls -vm my-vm                          # find disk labels
govc device.remove -vm my-vm disk-1000-1          # detach+delete — confirm; -keep to detach only
govc datastore.disk.info -ds ds1 my-vm/data.vmdk
govc datastore.disk.extend -ds ds1 -size 200GB my-vm/data.vmdk   # offline vmdk surgery
govc datastore.disk.inflate -ds ds1 my-vm/data.vmdk
govc datastore.disk.shrink  -ds ds1 my-vm/data.vmdk
```
```powershell
govc vm.disk.create -vm my-vm -name my-vm/data -size 100GB -thick=false
govc vm.disk.change -vm my-vm '-disk.label' "Hard disk 2" -size 200GB
```

First-class disks (FCD, used by Kubernetes CNS): `disk.ls`, `disk.create`, `disk.attach`, `disk.detach`, `disk.rm`, `disk.snapshot.*`; CNS volumes: `volume.ls`, `volume.rm`, `volume.snapshot.*`.

## Standard networking (per-host vSwitch)

```bash
govc host.vswitch.info -host esx01
govc host.vswitch.add -host esx01 -nic vmnic2 vSwitch1
govc host.portgroup.info -host esx01
govc host.portgroup.add -host esx01 -vswitch vSwitch1 -vlan 100 PG-App
govc host.portgroup.change -host esx01 -vlan 200 PG-App
govc host.portgroup.remove -host esx01 PG-App     # confirm; check for attached VMs first:
govc find / -type m -network PG-App               # (or collect network per VM)
```

## Distributed switch (DVS)

```bash
govc dvs.create -dc DC1 DSwitch1
govc dvs.add -dvs DSwitch1 -pnic vmnic1 esx01 esx02        # add hosts+uplinks
govc dvs.portgroup.add -dvs DSwitch1 -vlan 100 DPG-App
govc dvs.portgroup.add -dvs DSwitch1 -type earlyBinding -nports 128 DPG-DB
govc dvs.portgroup.change -vlan 200 DPG-App
govc dvs.portgroup.info DSwitch1
```

## VM networking

```bash
govc vm.network.add -vm my-vm -net DPG-App -net.adapter vmxnet3
govc vm.network.change -vm my-vm -net DPG-DB ethernet-0
govc device.connect -vm my-vm ethernet-0
govc device.disconnect -vm my-vm ethernet-0
govc vm.ip my-vm                                  # wait for/print guest IP
```
```powershell
govc vm.network.add -vm my-vm -net DPG-App '-net.adapter' vmxnet3
```

## vmkernel adapters and host network config

```bash
govc host.vnic.info -host esx01
govc host.vnic.service -host esx01 -enable vmotion vmk1
govc host.esxcli -host esx01 network ip interface list      # deeper config via esxcli
govc firewall.ruleset.find -direction inbound -port 22      # which hosts allow SSH
```
