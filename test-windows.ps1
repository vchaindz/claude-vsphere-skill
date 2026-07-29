# test-windows.ps1 - set up govc + vcsim on Windows and smoke-test the govc Claude Code skill
# Run from the govc-claude-skill folder:  powershell -ExecutionPolicy Bypass -File .\test-windows.ps1
# NOTE: keep this file ASCII-only; Windows PowerShell 5.1 misreads BOM-less UTF-8.
$ErrorActionPreference = 'Stop'
$tools = Join-Path $env:LOCALAPPDATA 'govc-tools'
New-Item -ItemType Directory -Force -Path $tools | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Windows on ARM (Surface, Dev Kit, Windows VMs on Apple Silicon) needs the arm64 build.
if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $arch = 'arm64' } else { $arch = 'x86_64' }

function Get-Tool($name) {
    $exe = Join-Path $tools "$name.exe"
    if (Test-Path $exe) { Write-Host "[ok] $name already installed" -ForegroundColor Green; return }
    Write-Host "[..] downloading $name ($arch)..." -ForegroundColor Cyan
    $url = "https://github.com/vmware/govmomi/releases/latest/download/${name}_Windows_${arch}.zip"
    $zip = Join-Path $env:TEMP "$name.zip"
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $tools -Force
    Remove-Item $zip
    Write-Host "[ok] $name installed to $tools" -ForegroundColor Green
}

Get-Tool 'govc'
Get-Tool 'vcsim'
$env:Path = "$tools;$env:Path"

# --- install the skill for Claude Code ---
$skillSrc = Join-Path $PSScriptRoot 'govc'
$skillDst = Join-Path $env:USERPROFILE '.claude\skills\govc'
if (Test-Path $skillSrc) {
    New-Item -ItemType Directory -Force -Path (Split-Path $skillDst) | Out-Null
    # remove first: Copy-Item -Recurse nests into ...\skills\govc\govc when the target exists
    if (Test-Path $skillDst) { Remove-Item $skillDst -Recurse -Force }
    Copy-Item $skillSrc $skillDst -Recurse -Force
    Write-Host "[ok] skill installed to $skillDst" -ForegroundColor Green
} else {
    Write-Host "[!!] skill folder not found next to this script - skipping install" -ForegroundColor Yellow
}

# --- start vcsim ---
Write-Host "[..] starting vcsim on https://127.0.0.1:8989/sdk" -ForegroundColor Cyan
$vcsim = Start-Process -FilePath (Join-Path $tools 'vcsim.exe') -ArgumentList '-l','127.0.0.1:8989' -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 3
$env:GOVC_URL      = 'https://user:pass@127.0.0.1:8989/sdk'
$env:GOVC_INSECURE = 'true'

# --- smoke tests: the command patterns the skill relies on ---
$pass = 0
$fail = 0
function Test-Cmd($desc, [scriptblock]$cmd) {
    $ErrorActionPreference = 'Continue'   # native tools may write to stderr; not an error
    try {
        $out = & $cmd 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[PASS] $desc" -ForegroundColor Green
            $script:pass++
        } else {
            Write-Host "[FAIL] $desc" -ForegroundColor Red
            Write-Host "       $out" -ForegroundColor DarkGray
            $script:fail++
        }
    } catch {
        Write-Host "[FAIL] $desc : $_" -ForegroundColor Red
        $script:fail++
    }
}

Test-Cmd 'connect: govc about'                    { govc about }
Test-Cmd 'inventory: list root'                   { govc ls / }
Test-Cmd 'inventory: find VMs'                    { govc find / -type m }
# NOTE: dotted property flags must be quoted in PowerShell, or PS splits them before govc sees them
Test-Cmd 'inventory: filter powered-on VMs'       { govc find / -type m '-runtime.powerState' poweredOn }
Test-Cmd 'info: vm.info -json'                    { govc vm.info -json DC0_H0_VM0 }
Test-Cmd 'info: datastore.info -json'             { govc datastore.info -json }
Test-Cmd 'info: host.info -json (first host)'     { $h = govc find / -type h | Select-Object -First 1; govc host.info -json -host "$h" }
Test-Cmd 'collect: single property read'          { govc collect -s /DC0/vm/DC0_H0_VM0 summary.runtime.powerState }
Test-Cmd 'power: off then on'                     { govc vm.power -off DC0_H0_VM1; govc vm.power -on DC0_H0_VM1 }
Test-Cmd 'snapshot: create'                       { govc snapshot.create -vm DC0_H0_VM0 test-snap }
Test-Cmd 'snapshot: tree'                         { govc snapshot.tree -vm DC0_H0_VM0 }
Test-Cmd 'snapshot: audit pattern (find)'         { govc find / -type m '-snapshot.currentSnapshot' '*' }
Test-Cmd 'snapshot: remove'                       { govc snapshot.remove -vm DC0_H0_VM0 test-snap }
Test-Cmd 'events: last 10'                        { govc events -n 10 }
Test-Cmd 'metrics: metric.ls'                     { govc metric.ls /DC0/vm/DC0_H0_VM0 }

if ($fail -eq 0) { $color = 'Green' } else { $color = 'Yellow' }
Write-Host ""
Write-Host "=== $pass passed, $fail failed ===" -ForegroundColor $color

Write-Host @"

vcsim is still running (PID $($vcsim.Id)). To test the skill interactively, open a NEW
terminal, set these env vars, and start Claude Code:

  `$env:GOVC_URL='https://user:pass@127.0.0.1:8989/sdk'
  `$env:GOVC_INSECURE='true'
  `$env:Path="$tools;`$env:Path"
  claude

Then try prompts like:
  - "Which VMs are running in this vSphere environment? Give me a table."
  - "Create a snapshot of DC0_H0_VM0, then show me all VMs that have snapshots."
  - "Give me a datastore capacity report."
  - "Destroy DC0_C0_RP0_VM0"   <- it should ask for confirmation first!

Stop the simulator when done:  Stop-Process -Id $($vcsim.Id)

This script only validates against the simulator. To check your REAL vCenter
credentials, open a new terminal and run these read-only commands by hand:

  `$env:GOVC_URL      = 'vcenter.example.com'
  `$env:GOVC_USERNAME = 'administrator@vsphere.local'
  `$env:GOVC_PASSWORD = '...'
  `$env:GOVC_INSECURE = 'true'     # only for a self-signed cert
  govc about                       # reachability + credentials
  govc ls /                        # datacenters
  govc find / -type m '-runtime.powerState' poweredOn

Use setx instead of `$env: to persist the values, and remember that Claude Code
inherits the environment of the terminal it is started from - set the variables
BEFORE running 'claude'.
"@
