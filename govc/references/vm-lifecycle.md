# VM lifecycle: create, clone, power, migrate, guest ops, destroy

## Power operations

```bash
govc vm.power -on  my-vm
govc vm.power -s   my-vm      # graceful guest shutdown (needs VMware Tools)
govc vm.power -off my-vm      # HARD power off — confirm with user first
govc vm.power -r   my-vm      # graceful guest reboot
govc vm.power -reset my-vm    # hard reset
govc vm.power -suspend my-vm
govc vm.power -on $(govc find /DC1/vm/app -type m)   # bulk
```

```powershell
# same commands; only the bulk form differs (no $(...) word-splitting in PowerShell)
$vms = govc find /DC1/vm/app -type m
govc vm.power -on @vms
```

Prefer graceful (`-s`, `-r`); fall back to hard (`-off`, `-reset`) only when Tools is missing/hung, and tell the user. Verify result: `govc vm.info my-vm` or `govc collect -s vm/my-vm summary.runtime.powerState`. Wait for an IP after boot: `govc vm.ip my-vm`.

## Create

```bash
govc vm.create -m 4096 -c 2 -g ubuntu64Guest -disk 40GB \
  -net "VM Network" -ds datastore1 -pool /DC1/host/ClusterA/Resources \
  -on=false new-vm
```
```powershell
# line continuation is a backtick, not a backslash
govc vm.create -m 4096 -c 2 -g ubuntu64Guest -disk 40GB `
  -net "VM Network" -ds datastore1 -pool /DC1/host/ClusterA/Resources `
  -on=false new-vm
```

Check `-h` for the current guest ID list source; common IDs: `ubuntu64Guest`, `rhel8_64Guest`, `windows2019srv_64Guest`, `otherLinux64Guest`. Attach an ISO with `-iso path/to.iso`, then `govc device.cdrom.*` to manage media.

## Clone and templates

```bash
govc vm.clone -vm template-ubuntu -on=false new-vm          # clone from VM/template
govc vm.clone -vm src -snapshot current -link linked-vm     # linked clone
govc vm.instantclone -vm running-src fast-copy              # instant clone (running VM)
govc vm.markastemplate my-vm                                # VM -> template
govc vm.markasvm -host esx01 my-template                    # template -> VM
```

Guest customization after clone: `govc vm.customize -vm new-vm -name newhost -ip 10.0.0.42 -netmask 255.255.255.0 -gateway 10.0.0.1 -dns-server 10.0.0.2` (check `-h`; Linux needs Perl + Tools, Windows uses sysprep).

## OVA/OVF and content library

```bash
govc import.spec ./app.ova > spec.json         # inspect/edit deployment options
govc import.ova -options spec.json ./app.ova
govc import.ovf -name my-vm ./app.ovf
govc export.ovf -vm my-vm ./export-dir

govc library.create my-lib
govc library.import my-lib ./app.ova
govc library.deploy /my-lib/app my-new-vm
govc library.ls '/my-lib/*'
```

```powershell
# Windows PowerShell 5.1 writes UTF-16LE with a BOM on `>`, which govc cannot read back.
# Use Out-File -Encoding utf8 instead (PowerShell 7+ defaults to UTF-8 and is fine either way).
govc import.spec ./app.ova | Out-File -Encoding utf8 spec.json
govc import.ova -options spec.json ./app.ova
```

## Reconfigure

```bash
govc vm.change -vm my-vm -m 8192 -c 4                 # memory MB / vCPU (VM usually must be off
                                                      # unless hot-add enabled)
govc vm.change -vm my-vm -name renamed-vm
govc vm.change -vm my-vm -annotation "owner: dennis"
govc vm.change -vm my-vm -e guestinfo.mykey=myvalue   # extraConfig
govc vm.disk.create -vm my-vm -name my-vm/data -size 100GB
govc vm.disk.change -vm my-vm -disk.label "Hard disk 2" -size 200GB   # grow only
govc vm.network.add -vm my-vm -net "VM Network"
govc vm.network.change -vm my-vm -net PG-App ethernet-0
govc device.ls -vm my-vm                              # enumerate devices first
govc vm.upgrade -vm my-vm                             # VM hardware version
```
```powershell
# quote the dotted flags; the rest are identical
govc vm.disk.change -vm my-vm '-disk.label' "Hard disk 2" -size 200GB
```

## Migrate (vMotion / storage vMotion)

```bash
govc vm.migrate -host /DC1/host/ClusterA/esx02 my-vm      # compute vMotion
govc vm.migrate -ds datastore2 my-vm                      # storage vMotion
govc vm.migrate -host ... -ds ... my-vm                   # both
govc vm.migrate -pool /DC1/host/ClusterB/Resources my-vm  # cross-cluster
```

Pre-checks worth doing: target host connected and not in maintenance (`host.info`), target datastore has space (`datastore.info`), no local devices (ISO mounted from local datastore blocks vMotion — `device.ls`).

## Guest operations (inside the OS, via VMware Tools)

```bash
export GOVC_GUEST_LOGIN='root:guestpass'      # or -l flag
govc guest.run -vm my-vm uname -a             # run + capture output
govc guest.run -vm my-vm -d 'stdin data' cat  # pass stdin
govc guest.ps -vm my-vm                       # process list
govc guest.df -vm my-vm                       # disk usage in guest
govc guest.upload -vm my-vm ./local.txt /tmp/remote.txt
govc guest.download -vm my-vm /var/log/app.log ./app.log
govc guest.start -vm my-vm /bin/sh -c "long-running &"    # start w/o waiting
```

```powershell
$env:GOVC_GUEST_LOGIN = 'root:guestpass'      # or -l flag
govc guest.run -vm my-vm uname -a
govc guest.upload -vm my-vm .\local.txt /tmp/remote.txt
govc guest.download -vm my-vm /var/log/app.log .\app.log
```

Local paths follow the *admin's* OS; the remote paths follow the *guest's* OS.

Requires running VMware Tools and valid guest credentials. `guest.run` needs Tools; on Windows guests use full paths (`C:\Windows\System32\...`).

## Destroy / unregister

`vm.destroy` **deletes the VM and its disks permanently**. Always:
1. Show the user exactly which VM(s): `govc vm.info <name>` (check for duplicates/globs!)
2. Get explicit confirmation.
3. Consider alternatives: `govc vm.unregister my-vm` removes from inventory but keeps files on the datastore (reversible via `govc vm.register`).

```bash
govc vm.destroy my-vm         # powers off if needed, then deletes from disk
govc vm.unregister my-vm      # inventory only; files remain
govc vm.register -host esx01 -pool ... path/to/my-vm.vmx
```
