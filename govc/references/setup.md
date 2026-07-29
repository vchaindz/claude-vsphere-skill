# Setup, authentication, and connection

## Install govc

Release binaries live at https://github.com/vmware/govmomi/releases. Published archive
names are `govc_{Darwin,Linux,Freebsd}_{x86_64,arm64,arm}.tar.gz` and
`govc_Windows_{x86_64,arm64}.zip`, plus `.deb`/`.rpm` packages and a `checksums.txt`.

### macOS

```bash
brew install govc
```

Or download directly (see the Linux block below — the same script covers macOS, and
`uname -m` already reports `arm64` on Apple Silicon).

### Linux

```bash
OS=$(uname -s); ARCH=$(uname -m)
[ "$ARCH" = "aarch64" ] && ARCH=arm64      # Linux reports aarch64; the asset is arm64
[ "$ARCH" = "armv7l" ]  && ARCH=arm
curl -fL "https://github.com/vmware/govmomi/releases/latest/download/govc_${OS}_${ARCH}.tar.gz" \
  | sudo tar -C /usr/local/bin -xzf - govc
```

`curl -f` matters: without it a wrong architecture name returns a 404 HTML page that gets
piped into `tar`, producing a confusing "Error opening archive" instead of a clean failure.

`.deb` and `.rpm` packages are also published on the releases page if you prefer your
package manager.

### Windows

```powershell
scoop install govc
```

Or download manually, which also puts it on PATH permanently:

```powershell
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x86_64' }
$dir  = "$env:LOCALAPPDATA\govc"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12  # PS 5.1 needs this
Invoke-WebRequest -UseBasicParsing `
  -Uri "https://github.com/vmware/govmomi/releases/latest/download/govc_Windows_$arch.zip" `
  -OutFile "$dir\govc.zip"
Expand-Archive -Path "$dir\govc.zip" -DestinationPath $dir -Force
Remove-Item "$dir\govc.zip"

# add to PATH permanently (new terminals only — the current one keeps the old PATH)
setx PATH "$dir;$env:PATH"
$env:Path = "$dir;$env:Path"    # also fix the current session
```

### Any platform

```bash
go install github.com/vmware/govmomi/govc@latest    # needs a Go toolchain
docker run --rm -e GOVC_URL -e GOVC_USERNAME -e GOVC_PASSWORD vmware/govc about
```

Verify: `govc version` (and `govc version -l` for build details).

### jq

The reporting patterns in `references/inventory-reporting.md` pipe `-json` output through
`jq`. Install it with `brew install jq` (macOS), `apt install jq` / `dnf install jq`
(Linux), or `scoop install jq` (Windows). Native PowerShell does not need it — use
`ConvertFrom-Json` instead.

## Connection environment variables

govc reads its credentials from the process environment. **Set them in your shell before
starting Claude Code** — Claude Code inherits the environment of the terminal that launched
it, and a variable exported inside one Claude tool call does not survive to the next one.
If you change them, restart Claude Code.

```bash
# bash / zsh — Linux, macOS, WSL, Git Bash
export GOVC_URL='vcenter.example.com'     # scheme defaults to https, path to /sdk
export GOVC_USERNAME='administrator@vsphere.local'
export GOVC_PASSWORD='secret'
```

To persist, add those lines to `~/.zshrc` (the default shell on macOS) or `~/.bashrc`
(most Linux distributions).

```powershell
# PowerShell — current session only
$env:GOVC_URL      = 'vcenter.example.com'
$env:GOVC_USERNAME = 'administrator@vsphere.local'
$env:GOVC_PASSWORD = 'secret'

# persistent across reboots — takes effect in NEW terminals, not the current one
setx GOVC_URL      "vcenter.example.com"
setx GOVC_USERNAME "administrator@vsphere.local"
setx GOVC_PASSWORD "secret"
```

```bat
REM cmd.exe — current session
set GOVC_URL=vcenter.example.com
set GOVC_USERNAME=administrator@vsphere.local
set GOVC_PASSWORD=secret
```

`setx` writes the value to the registry in cleartext and it shows up in
`Get-ChildItem Env:` for every process you start. On a shared or audited machine, prefer
setting `GOVC_PASSWORD` per-session, or use `GOVC_TLS_KNOWN_HOSTS` with a least-privilege
service account.

Keep username/password out of `GOVC_URL` if they contain special characters (`\`, `#`, `:`) — use the separate variables.

Other useful defaults:

| Variable | Purpose |
|---|---|
| `GOVC_DATACENTER` | Default datacenter (`-dc`) |
| `GOVC_DATASTORE` | Default datastore (`-ds`) |
| `GOVC_NETWORK` | Default network (`-net`) |
| `GOVC_RESOURCE_POOL` | Default resource pool (`-pool`) |
| `GOVC_HOST` | Default host (`-host`) |
| `GOVC_CLUSTER` | Default cluster (`-cluster`) |
| `GOVC_FOLDER` | Default inventory folder (`-folder`) |
| `GOVC_GUEST_LOGIN` | `user:pass` for guest operations |
| `GOVC_INSECURE` | `true` disables TLS verification (lab/testing only) |

Check one variable at a time: `govc env GOVC_URL`.

> **Do not run a bare `govc env`** — it prints every `GOVC_*` variable including
> `GOVC_PASSWORD` in cleartext, which then lands in your terminal scrollback and in the
> Claude Code transcript. Always name the variable you want.

## TLS with self-signed certificates

Production-appropriate options instead of `GOVC_INSECURE=true`:

```bash
# Option A: trust the CA
export GOVC_TLS_CA_CERTS=~/.govc_ca.crt      # colon-separate multiple files

# Option B: pin the thumbprint
export GOVC_TLS_KNOWN_HOSTS=~/.govc_known_hosts
govc about.cert -u vcenter.example.com -k -thumbprint | tee -a $GOVC_TLS_KNOWN_HOSTS
```

```powershell
# Option A: trust the CA
$env:GOVC_TLS_CA_CERTS = "$env:USERPROFILE\.govc_ca.crt"   # semicolon-separate on Windows

# Option B: pin the thumbprint
$env:GOVC_TLS_KNOWN_HOSTS = "$env:USERPROFILE\.govc_known_hosts"
govc about.cert -u vcenter.example.com -k -thumbprint |
  Out-File -Append -Encoding utf8 $env:GOVC_TLS_KNOWN_HOSTS
```

## Sessions

govc persists sessions to disk by default (`~/.govmomi/sessions`, or
`%USERPROFILE%\.govmomi\sessions` on Windows), so repeated commands don't re-authenticate. Related commands: `session.login`, `session.ls`, `session.logout`, `session.rm`. Disable persistence with `-persist-session=false` if needed.

## Connectivity troubleshooting

```bash
govc about                       # basic reachability + product info
govc about.cert -k               # inspect the server certificate
govc env GOVC_URL                # verify one var (never bare `govc env` — leaks password)
env | grep -i proxy              # proxies often break SOAP connections
```

```powershell
govc about
govc about.cert -k
govc env GOVC_URL
Get-ChildItem Env: | Where-Object Name -match 'proxy'
```

Common failures:
- `x509: certificate signed by unknown authority` → self-signed cert; see TLS section.
- `incorrect user name or password` → check for shell-escaping issues in the password; prefer `GOVC_PASSWORD`.
- Timeouts → firewall/proxy blocking 443 to vCenter, or wrong URL.
- `datacenter '...' not found` → wrong `GOVC_DATACENTER`; list with `govc ls /`.

## Debugging API calls

- `-verbose` — compact request/response summary to stderr
- `-trace` — full HTTP request/response bodies to stderr
- `-debug` — save all SOAP traffic to `~/.govmomi/debug/<timestamp>/`
  (`%USERPROFILE%\.govmomi\debug\<timestamp>\` on Windows)

## Testing safely with vcsim

The vCenter simulator ships with govmomi and lets you validate any govc workflow without touching real infrastructure:

```bash
go install github.com/vmware/govmomi/vcsim@latest      # or download vcsim_<OS>_<ARCH> from releases
vcsim &                          # listens on https://127.0.0.1:8989/sdk
export GOVC_URL=https://user:pass@127.0.0.1:8989/sdk
export GOVC_INSECURE=true
govc find / -type m              # simulator comes pre-populated with inventory
```

```powershell
# trailing `&` is a syntax error in Windows PowerShell 5.1 — use Start-Process
Start-Process vcsim -ArgumentList '-l','127.0.0.1:8989' -WindowStyle Hidden
$env:GOVC_URL      = 'https://user:pass@127.0.0.1:8989/sdk'
$env:GOVC_INSECURE = 'true'
govc find / -type m
```

The simulator accepts any username/password. Stop it with `kill %1` (bash) or
`Stop-Process -Name vcsim` (PowerShell).
