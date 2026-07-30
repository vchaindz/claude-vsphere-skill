# HTML report template — standard deliverable format

When the user asks for a **report as a file** (health check, snapshot audit, capacity
report, inventory, assessment — anything they will keep, share, or send), produce a
self-contained HTML file based on `assets/report-template.html`. For quick in-chat
answers, a Markdown table is still fine; the template is for deliverables.

## Workflow

1. **Collect data first.** Run all govc queries (read-only, `-json`) and compute the
   numbers before touching the template. Never invent values — every number in the
   report must come from a command you actually ran.
2. **Read `assets/report-template.html`** and use it as the skeleton. Keep the CSS and
   the sort script unchanged; replace only the `{{TOKEN}}` placeholders and remove the
   inline `<!-- example -->` comments.
3. **Write the finished report** to the location the user asked for, named
   `<report-type>-<environment>-<YYYY-MM-DD>.html`
   (e.g. `snapshot-audit-acme-prod-2026-07-30.html`).
4. Tell the user the file path and summarize the top findings in one or two sentences.

## Filling the tokens

| Token | Source |
|---|---|
| `{{REPORT_TITLE}}` | Report type, e.g. "Environment Health Check" |
| `{{ENVIRONMENT_NAME}}` | User-supplied name, else the vCenter FQDN |
| `{{VCENTER}}` | Endpoint host from `GOVC_URL` |
| `{{VSPHERE_VERSION}}` | `govc about` — product, version, build |
| `{{GENERATED_AT}}` | Local time, `date '+%Y-%m-%d %H:%M %Z'` / `Get-Date -Format 'yyyy-MM-dd HH:mm'` |
| `{{SCOPE}}` | Counts from discovery, e.g. "2 datacenters · 3 clusters · 14 hosts · 412 VMs" |
| `{{KPI_CARDS}}` | 3–6 headline numbers (see below) |
| `{{FINDINGS_ROWS}}` | One `<tr>` per finding, worst first |
| `{{SECTIONS}}` | One `<section>` per data table |
| `{{FOOTER_NOTE}}` | e.g. "All data collected read-only via govc 0.44 on 2026-07-30" |

## Structure rules

**KPI cards (3–6).** Headline numbers only, colored by state: `sev-critical` /
`sev-warning` / `sev-ok` class on the card when the number itself is a verdict, no
class when it is neutral inventory ("412 VMs total").

**Findings table — always present, always first.** Every report leads with findings,
ordered critical → warning → ok → info. Each row names the *exact affected objects*
(in `<code>` tags) and a concrete recommended action. If a whole category is healthy,
say so with a `sev-ok` row — "checked and found healthy" is a result, not noise. If
there are no findings at all, keep the section with a single ok-row stating what was
checked.

**Data sections.** One `<section>` per table. Each section's `.desc` line states the
**source command** and the **thresholds applied** — this is what makes the report
auditable, never omit it. Add `class="sortable"` to tables where reordering helps
(capacity, ages, sizes). For columns with formatted values (GB, %, ages), put the raw
number in `data-v` so sorting works:

```html
<td class="num" data-v="1099511627776">1.0 TB</td>
```

An empty result is shown as `<p class="empty">No snapshots found.</p>` instead of an
empty table.

**Row highlighting.** Add `sev-critical` / `sev-warning` as a class on the `<tr>` of
offending rows in data tables — this draws the colored edge marker. Don't badge every
row; badge only where a status column exists.

## Severity thresholds

Use these defaults unless the user specifies others, and state the applied thresholds
in the section `.desc`:

| Check | Warning | Critical |
|---|---|---|
| Datastore used | ≥ 75% | ≥ 85% |
| Snapshot age | > 3 days | > 7 days or > 3 in a chain |
| Host not connected / in maintenance unexpectedly | — | always |
| VMware Tools | not running | — |
| Triggered alarms | yellow | red |
| CPU/mem overcommit context | note in `.desc` | — |

## Consultant mode

If the report is for a client (user says "assessment", "for the customer", or names a
client), additionally:

- Use the client name as `{{ENVIRONMENT_NAME}}`.
- Add an "Executive summary" `<section>` right after the KPI cards: 3–5 sentences of
  prose, no table — overall state, the one or two things that matter, and the risk if
  unaddressed.
- Keep recommended actions vendor-neutral and phrased as recommendations, not commands.

## Rules

- **Never fabricate a value.** If a query failed or a metric is unavailable, write "not
  collected" and say why in the section `.desc`.
- **The report must state how data was gathered** (footer + per-section source
  commands). A report that can't be reproduced is worthless to an admin.
- Stay self-contained: no CDN links, no external images, no added JavaScript beyond the
  bundled sort script.
- With the privacy wrapper active, tokens like `VM-0001` will appear in the report —
  that is expected; mention `govc-safe rehydrate <file>` to the user for a cleartext copy.
