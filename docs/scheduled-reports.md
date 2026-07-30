# Scheduled and unattended reports

Run the skill's fixed health check on a schedule and get a report file plus a
machine-readable summary line, with no permission prompt for anyone to answer.

Two things make this work, and both are cheap:

1. **Pre-authorise, do not bypass.** Give the run an allowlist and
   `--permission-mode dontAsk`.
2. **Pair it with guard tier `readonly`.** A reporting job needs no write access to
   vSphere, so remove the possibility rather than trusting it not to be used.

This file is for the operator setting the job up. The behaviour contract the agent
follows once it is running — what it may decide alone, what it must still refuse — is in
the skill itself, under `## Unattended runs` in `govc/SKILL.md`.

## Why not `--dangerously-skip-permissions`

That mode disables permission prompts and safety checks, which is the opposite of what an
unattended job wants: an unforeseen command should *fail loudly*, not execute with nobody
watching. It also has three properties that break scheduled runs outright:

- On Linux and macOS it refuses to start as root or under `sudo`. A root crontab entry
  never runs at all.
- A backgrounded session is refused until the liability dialog has been accepted once in
  an interactive session.
- Explicit `ask` rules still force a prompt in that mode — and in a session that cannot
  prompt, the call is denied anyway. You gained nothing.

`--permission-mode dontAsk` is the mode for this job. It auto-denies every tool call that
would otherwise prompt, runs only what matches your `permissions.allow` rules, read-only
shell commands, and calls a PreToolUse hook approved — and the session never waits for
input. It also denies the question-asking tool outright, which enforces the skill's "never
ask when unattended" rule structurally rather than by asking the model nicely.

## Permission rules

Put these in the **service account's own user settings** (`~/.claude/settings.json`), not
in a project `.claude/settings.json`. Allow rules in project settings grant capability, so
they apply only after the workspace trust dialog has been accepted for that workspace —
and an unattended run never sees that dialog. It would silently get none of them.

```json
{
  "permissions": {
    "allow": [
      "Bash(govc *)",
      "Bash(tr *)",
      "Bash(jq *)",
      "Bash(xargs -0 govc *)",
      "Bash(xargs -0 -n1 -I{} govc *)",
      "Read(//var/lib/vsphere-health/**)",
      "Edit(//var/lib/vsphere-health/**)"
    ]
  }
}
```

Five things in that block are easy to get wrong:

- **`Bash(govc *)` alone is not enough.** Bash rules are matched per subcommand — a rule
  like `Bash(safe-cmd *)` does not grant `safe-cmd && other-cmd`. The separators are
  `&&`, `||`, `;`, `|`, `|&`, `&` and newlines, and a rule must match each subcommand
  independently. The skill's batch pattern is a four-stage pipe, so `tr`, `xargs` and `jq`
  each need their own rule.
- **`xargs` needs a rule because ours carries flags.** Bare `xargs` is stripped before
  matching, but only when it has no flags — `xargs -0 …` is matched as an `xargs` command.
  Both shapes the skill uses are listed above; a new pipeline shape needs a new rule.
- **`grep`, `wc`, `head`, `tail`, `ls`, `cat` and `find` need no rule.** They are in the
  built-in read-only command set. `tr`, `jq` and `awk` are not.
- **It is `Edit(...)`, not `Write(...)`.** File permissions are checked against `Edit(path)`
  and `Read(path)` rules only. A `Write(path)` rule is accepted, never consulted, and warns
  at startup. `Edit` rules already cover every file-editing tool.
- **Absolute paths need `//`.** A single leading `/` anchors at the settings file's own
  directory, so `Edit(/var/lib/...)` protects nothing you meant.

No `deny` rules are needed here. Everything not allowlisted is already denied under
`dontAsk`, and the boundary that matters is the guard tier below — a deny list in this file
would be a third, drifting copy of the same policy.

## Guard tier

```ini
# ~/.config/govc-guard/policy   — of the account the scheduled job runs as
tier = readonly
```

Create it for the **service account**, not for your own login: the hook reads the policy of
the user running the job, and it fails closed to `readonly` when the file is missing —
which is the right default here, but a silent one.

Do not pair a scheduled job with tier `full`. There a destroy-class command returns an
"ask" decision, and in a session that cannot prompt the call is denied with no operator in
the loop. You get a silent gap in the audit trail instead of a clear
`[govc-policy tier=readonly]` refusal that the agent can put in the report.

If you pass a `--settings` file, **omit the `hooks` key** — values there override the same
keys for the session, and a `hooks` block would replace the guard hook. Permission `deny`
rules are safe to include: if a tool is denied at any level, no other level can allow it.

## Turn limits

```
--max-turns 40      # nine checks + report + baseline, with headroom
--max-turns 60      # if you enable the optional orphaned-VMDK scan
```

The limit applies to agentic turns in print mode and **exits with an error when reached**.
An exceeded limit means no report and no `GOVC-REPORT` line — so treat a missing
`GOVC-REPORT` line as a failed run, never as a clean one.

Do **not** pass `--bare`. It skips auto-discovery of hooks, skills, plugins and memory —
including the govc skill and the guard hook, which is the whole safety story.

## cron

```cron
# /etc/cron.d/vsphere-health-check   — one line, no line continuations
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
MAILTO=vsphere-ops@example.com
30 6 * * 1-5 vsphere set -a; . /etc/vsphere-health/govc.env; set +a; cd /var/lib/vsphere-health && claude -p "/govc Run the fixed environment health check. Unattended: no questions, use defaults, write the HTML report to /var/lib/vsphere-health." --permission-mode dontAsk --max-turns 40 >> /var/log/vsphere-health/run.log 2>&1
```

`/etc/vsphere-health/govc.env`, mode `0600`, owned by the `vsphere` user:

```sh
GOVC_URL=vcenter.example.com
GOVC_USERNAME=svc-vsphere-ro@vsphere.local
GOVC_PASSWORD=...
GOVC_DATACENTER=DC1
```

Use a **read-only vCenter account**. That is the hard boundary; the guard tier and the
allowlist are the two softer ones above it.

Naming the skill explicitly with `/govc` in the prompt invokes it by name rather than
relying on the description matching — the expansion happens before the run starts, which
is one less thing to vary between nights.

## systemd timer

```ini
# /etc/systemd/system/vsphere-health-check.service
[Unit]
Description=vSphere environment health check
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=vsphere
Environment=HOME=/home/vsphere
WorkingDirectory=/var/lib/vsphere-health
EnvironmentFile=/etc/vsphere-health/govc.env
ExecStart=/usr/local/bin/claude -p "/govc Run the fixed environment health check. Unattended: no questions, use defaults, write the HTML report to /var/lib/vsphere-health." --permission-mode dontAsk --max-turns 40
StandardOutput=append:/var/log/vsphere-health/run.log
StandardError=inherit
TimeoutStartSec=1800
```

```ini
# /etc/systemd/system/vsphere-health-check.timer
[Unit]
Description=Run the vSphere health check on weekday mornings

[Timer]
OnCalendar=Mon..Fri 06:30
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
```

```bash
systemctl daemon-reload
systemctl enable --now vsphere-health-check.timer
systemctl start vsphere-health-check.service    # test it once, now
journalctl -u vsphere-health-check.service -n 50
```

`Environment=HOME=` is not optional cargo. If the run produces a report with no vSphere
data, or behaves as though the skill is not installed, `$HOME` is not what you assume:
skills are looked up under `~/.claude/skills`, and systemd resolves `$HOME` from the user
database. Pin it, then confirm `/home/vsphere/.claude/skills/govc/SKILL.md` exists.

## Windows Task Scheduler

Credentials come from the service account's own user environment (`setx`), not from the
task definition — a scheduled task starts a fresh process, so `setx` values are visible.

```powershell
$prompt = '/govc Run the fixed environment health check. Unattended: no questions, use defaults, write the HTML report to C:\ProgramData\vsphere-health.'
$cmd    = "cd C:\ProgramData\vsphere-health; claude -p '$prompt' --permission-mode dontAsk --max-turns 40 *>> C:\ProgramData\vsphere-health\run.log"

$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
             -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`""
$trigger = New-ScheduledTaskTrigger -Daily -At 06:30
$set     = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
             -StartWhenAvailable

# -Password takes a plain string, not a SecureString: passing the result of
# `Read-Host -AsSecureString` registers the literal text System.Security.SecureString
# as the account password, and the task then fails to start with a logon error.
$cred = Get-Credential -UserName 'DOMAIN\svc-vsphere' -Message 'Service account password'

Register-ScheduledTask -TaskName 'vSphere health check' -Action $action -Trigger $trigger `
  -Settings $set -User $cred.UserName `
  -Password $cred.GetNetworkCredential().Password `
  -RunLevel Limited
```

`-RunLevel Limited`, not `Highest`: the job needs no elevation, and the read-only vCenter
account is the boundary. The stored password is what buys "run whether the user is logged
on or not" — without it the task only fires during an interactive session.

## Reading the result

The last line of a run is machine-readable by contract:

```
GOVC-REPORT report=health-check env=acme-prod status=critical critical=2 warning=5 ok=4 info=1 baseline=changed path=/var/lib/vsphere-health/health-check-acme-prod-2026-07-30.html
```

```bash
out=$(claude -p "/govc Run the fixed environment health check. Unattended: no questions, use defaults, write the HTML report to /var/lib/vsphere-health." \
        --permission-mode dontAsk --max-turns 40 --output-format json)
line=$(printf '%s' "$out" | jq -r '.result' | grep -E '^GOVC-REPORT ' | tail -1)

if [ -z "$line" ]; then
    echo "health check produced no GOVC-REPORT line — treat as failed" >&2
    exit 1
fi
case "$line" in
    *"status=critical"*) mail -s "vSphere: CRITICAL" ops@example.com <<< "$line" ;;
    *"status=error"*)    mail -s "vSphere: check failed" ops@example.com <<< "$line" ;;
esac
```

The empty-line check is the important half. A run that hit the turn limit, lost its
connection, or died writing the file produces no `GOVC-REPORT` line at all — and a wrapper
that only greps for `status=critical` reads that as a healthy night.

`--output-format json` also reports the run's cost and a per-model breakdown, which is how
you budget a daily job.

## The baseline file

The health check writes `health-check-<environment>.baseline.json` next to the report and
compares against it on the next run, which is what makes a scheduled job worth more than a
manual one: every morning's report opens with what changed overnight.

Two consequences for the operator:

- **Do not rotate or clean it** with the reports. Deleting it does not break anything, but
  the next run reports "first run" and you lose one day of comparison.
- **It contains inventory paths**, so it is roughly as sensitive as the reports themselves.
  The repository's `.gitignore` covers `*.baseline.json`; if you keep reports somewhere
  else, treat it the same way.

## What not to use

- **Cloud-hosted scheduled agents** run against a fresh clone with no local files and no
  network path to your vCenter. A vSphere health check cannot run there.
- **In-session repeating tasks** (`/loop` and similar) are scoped to a live session and
  stop when it ends. Useful for watching a migration for an hour, wrong for a nightly
  report.
- **Desktop scheduled tasks** do run locally with file access and are a reasonable
  alternative to cron on a workstation. On a server, use systemd.
