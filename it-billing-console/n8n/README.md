# n8n automations for the IT console

Everything n8n does for the IT Billing Console ("IT console"), written so a fresh
session can pick this up without re-discovering it.

`workflows.json` in this folder is an export of all live workflows. It is a
**mirror, not the source** — the live n8n DB is authoritative. Re-export before
trusting it (see [Deploying a change](#deploying-a-change)).

---

## Where it runs

| Piece | Address | Notes |
|---|---|---|
| n8n | `192.168.126.101:5678` | Docker container `n8n`, image `docker.n8n.io/n8nio/n8n`, **v2.36.7**, `restart=always` |
| IT console API | `192.168.126.101:3000` | Node/Express + SQLite, container `it-billing-console` |
| Invoice parser | `192.168.126.101:4321` | `POST /parse-invoice`, `POST /parse-rental-bill`, `GET /health` |
| ntfy | `192.168.126.101:8080` | topic `it-billing-console` |

SSH alias `IKI-MAC-27` → `192.168.126.101`, user `admin`.

> **Two things bite every time:**
> 1. `docker` is **not on PATH over SSH** — always `/usr/local/bin/docker`.
> 2. Inside the n8n container, `localhost` does **not** reach the host. Every URL in
>    a workflow must be the literal LAN IP `192.168.126.101`.

n8n's SQLite DB is at `/home/node/.n8n/database.sqlite` inside the container.
Useful tables: `workflow_entity` (incl. the `staticData` column), `execution_entity`,
`execution_data`, `credentials_entity`.

---

## Live workflows

| ID | Name | Trigger |
|---|---|---|
| `Ncx7r0VcoxUfO6hF` | Weekly IT Spend Summary | cron `0 9 * * 1` |
| `t4Pui7NwhNkRoabs` | Gmail Invoice Auto-Capture | Gmail trigger |
| `qZ3Gn6zzCACqfweL` | Auto-Delete Basecamp Notification Emails | Gmail trigger |
| `newJoinersAuto` | New Joiners Auto Add (SH / HA / TI) | every 30 min + manual |
| `shSheetSync001` | Saleshandy User List → G Suite Sheet | every 30 min + manual |
| `krishnaSheetSync` | Krishnabusiness User List → G Suite Krishna 20 | every 30 min + manual |
| `tiSheetSync001` | TrulyInbox User List → TrulyInbox GW | every 30 min + manual |
| `exitSync00001` | Exit Sync - Remove Leavers from Console | every 30 min + manual |
| `solSheetSync01` | Saleshandy Solutions <-> SaleshandySolutions-10 | every 30 min + manual |
| `racBillCapture` | RAC Laptop Bill Auto-Capture | Gmail trigger + manual |
| `syncFailAlert01` | Sync Failure Alert | error trigger (every other workflow's `errorWorkflow`) |
| `racProofCapture` | RAC Payment Proof Auto-Capture | Gmail trigger (SENT) + manual |

All eleven are active. `JqFyzAypvj6uMKw3` (Saleshandy joiners) and `haJoinerSync01`
(HighAdvocacy joiners) were **merged into `newJoinersAuto` on 29-08-2026 and deleted**.

### The invoice parser (`192.168.126.101:4321`)

Not in this repo — it lives at `~/invoice-parser/server.js` on the Mac Mini, run by
launchd (`~/Library/LaunchAgents/com.invoiceparser.plist`, `KeepAlive`). It is a tiny
native HTTP service that shells out to a coding agent and returns the JSON object it
produces.

**Two engines, chosen at call time by `pickEngine()`:**

| | |
|---|---|
| `codex` | `~/.codex/packages/standalone/current/codex exec` — **preferred** |
| `claude` | `~/local-node/bin/claude -p` — fallback |

Codex wins because it is a **different account with a different quota**. Sharing one
Claude session with Hermes meant a busy Telegram day took invoice capture down with it,
which is exactly what happened on 31-08-2026. It also suits a one-shot extraction
better: `-o` writes the final message to its own file (so the answer is read from there
instead of regex-scraping a whole transcript), `-i` attaches an image natively instead
of the "read the file at this path" hack, and `--ephemeral --skip-git-repo-check` stop a
stateless call from leaving sessions behind or caring about the working directory. It
runs `-s read-only`, so it can never write anything.

Selection is automatic: codex is used when the binary exists **and**
`~/.codex/auth.json` exists (or `OPENAI_API_KEY` is set), otherwise it falls back to
claude.

> **Being logged in is not the same as having quota.** Codex answered fine at 14:00 on
> 31-08-2026 and was refusing with "You've hit your usage limit" by 14:30, while claude's
> own limit had reset at 15:10 — the two run dry at different times, which is the whole
> point of keeping both. `pickEngine()` cannot see quota, so `callAgent()` now retries
> **once on claude** when a codex run dies with anything `isCapacityFailure()` matches
> (usage/session/rate limit, quota, 429, 401, not logged in). The reply then carries
> `_fellBackFrom: "codex"`. Without this the parser kept picking codex and kept failing
> with a perfectly good claude sitting unused. `PARSER_ENGINE=codex|claude` in the launchd plist pins one. `GET /health`
reports which is live:

```json
{"ok":true,"engine":"claude","codexInstalled":true,"codexAuthed":false}
```

Every parse response also carries `_engine`, so an odd result can be traced to the agent
that produced it.

**Codex went live 31-08-2026** — logged in with a ChatGPT account, `/health` reports
`{"engine":"codex","codexAuthed":true}`. Verified against the real
`AMD/26-27/00669` invoice: every field correct, including the ones only the PDF carries
(due date, PO number, both serial numbers and RAC's own asset numbers). ~25s per parse.

> **Logging codex in over SSH: use `codex login --device-auth`.** Plain `codex login`
> starts a callback server on `localhost:1455` and wants a browser on the same machine,
> which an SSH session does not have. Device auth prints a URL and a code to enter from
> any browser. `codex login --with-api-key` (key on stdin) works too, and
> `ssh -L 1455:localhost:1455` would tunnel the normal flow if it is ever needed.
> Afterwards: `launchctl kickstart -k gui/$(id -u)/com.invoiceparser`.

| Endpoint | Body | Returns |
|---|---|---|
| `POST /parse-invoice` | `{text, existingVendors[], existingDomains[]}` | vendor/service/cost/expiry + optional seat change |
| `POST /parse-payment-proof` | `{text \| emailText \| imageBase64+imageMime, openInvoices[]}` | amount actually paid, `paid_on`, method, bank ref, and a `looks_like_payment_proof` guard |
| `POST /parse-rental-bill` | `{text \| emailText \| imageBase64+imageMime, existingAssets[]}` | `invoices[]` (number/date/**due date**/PO/period/location/net/GST/total) + `laptops[]` with serial and vendor asset numbers |
| `GET /health` | — | `ok` |

`/parse-rental-bill` takes extracted PDF text, the **email body**, a raw photo, or any
combination. An image is written to a temp file and claude is pointed at the path (a
photo of a bill has no extractable text at all); the temp file is deleted whether the
call succeeds, fails or times out. Timeouts differ by input: 120s for text, 180s for an
image.

It returns **`invoices[]`, not a single invoice** — RAC list several e-invoices in one
mail, one table row each. The prompt is told dates are DD-MM-YYYY (19-08-2026 is 19
August), that `period_label` must describe the real billed period rather than a calendar
month (their cycle runs 18th→17th), and that a lump-sum bill with no per-machine
breakdown must return `laptops: []` instead of inventing machines from the total.

> Restart it with `launchctl kickstart -k gui/$(id -u)/com.invoiceparser`. Backups of
> previous versions sit beside it as `server.js.bak-<date>-<reason>`.

> **A non-zero exit reports `stdout` as well as `stderr`.** Both agents write their own
> failures to stdout, so the old `{"error":"claude exited 1","stderr":""}` said nothing
> at all — the real message (`You've hit your session limit · resets 3:10pm`) was being
> thrown away. Seen for real on 31-08-2026: **the parser can simply run out of quota**,
> and then every capture workflow fails until it resets. That outage is what drove the
> move to codex.

> Both endpoints spawn `claude -p`. That is the same OAuth token Hermes uses, so a
> burst of bills means concurrent `claude` calls — the risk the repo CLAUDE.md warns
> about. It has been fine in practice, but if Hermes ever loses auth around a busy
> invoice day, this is the first place to look.

### RAC Laptop Bill Auto-Capture

`Gmail Trigger → Match RAC + Pick Bill → Is PDF? → (true) Extract PDF Text →
Build Parse Request → AI Parse Rental Bill → Record Payment + Sync Laptops →
Attach Bill to NAS → Build Payment Summary → Notify via ntfy`

The `Is PDF?` false branch skips `Extract PDF Text` and goes straight to
`Build Parse Request`, which sends the file itself as base64 — that is the photo /
scan path. `Manual Trigger → Test Fixture (manual runs)` feeds a synthetic RAC
invoice **into `Match RAC + Pick Bill`**, not past it, because every node downstream
reads `$('Match RAC + Pick Bill')`; wire the fixture anywhere later and a manual run
throws.

What it writes: a row in `rental_payments`, any laptop on the bill that is not already
in `rented_assets`, and the bill file itself onto the NAS under `Documents/RAC/`.

> **Matching a laptop: serial number first, asset name second.** A tag like "RAC-01"
> can be re-used on a replacement machine; a serial cannot. Both are compared with
> punctuation and case stripped.

> **`PUT /api/rentals/:id` is a full replace.** The update branch echoes every field
> back, changing only rent / serial / model where the bill actually adds something.
> It skips the PUT entirely when nothing would change.

> **One mail can carry several e-invoices.** `Record Payment + Sync Laptops` loops over
> `invoices[]` and returns one item per invoice booked, so `Attach Bill to NAS` files the
> document against each and `Build Payment Summary` reads `.all()` to report them in a
> single alert.

> **Settling and attaching are separate questions.** `Settle Payment` used to return
> `[]` as soon as the row was already Paid with the same figures — which swallowed the
> proof file for any bill marked paid by hand. It now bails out only when the figures
> match **and** a file of that name is already on the row; otherwise it skips the `PUT`
> but still lets the attachment through.

> **Duplicate guard: `invoice_no`, per invoice.** An invoice number already present is
> skipped and named in the alert; if every invoice on the mail is a duplicate the node
> returns `[]` and the chain stops — no second payment, no second NAS copy, no
> notification. Gmail re-delivering a mail is normal; paying twice on paper is not.

> **Captured rows are `status: 'Pending'`, never `Paid`.** A RAC mail is an invoice
> asking for payment, not a receipt — see the Pending/Paid note in the RAC Laptops tab
> section.

> **`asset_id` stays NULL unless the bill lists exactly one laptop.** The vendor bills
> the fleet on one invoice, so a payment covers everything by default.

> **Both `AI Parse Rental Bill` and `Record Payment + Sync Laptops` have error outputs
> wired to `Notify Parse Failure`.** Without them a bill that cannot be parsed — or that
> parses but yields no usable invoice — fails silently: n8n logs a red execution nobody
> is watching and the money never reaches the console. The branch sends a
> **high-priority** ntfy naming the sender, subject, file and the underlying reason.
> Verified live while the parser was out of quota.

> **RAC replies are not bills.** When we mail them a payment proof they reply on the same
> thread, so the mail is `from:racwg.com`, its subject still says E-INVOICE, and it
> carries their signature block as Gmail-inlined `image001.png` … parts. `Match RAC +
> Pick Bill` therefore prefers a PDF (their e-invoices always are one), ignores
> `^image\d{3}\.(png|jpe?g|gif|webp)$` names when choosing an image, and returns `[]`
> when inline-looking parts are all that is attached. A properly-named image is still
> accepted, in case a scan ever arrives.

The ntfy alert is the answer to "how much have we already paid". It lists every invoice
booked off the mail (number, amount, period, location), then the money position:
outstanding unpaid bills and their total, paid vs billed this financial year, paid
all-time, and the last payment actually made. Paid and billed are counted separately —
that distinction is the whole point of the `status` column.

**The vendor is RAC IT Solutions Pvt Ltd, `racwg.com`** (confirmed 31-08-2026 from a
real invoice mail). They bill from several mailboxes on that one domain — `accounts@`,
`accountsahmd@`, `receivables3@`, `hobilling@`, `salesahmd4@` — so `SENDERS` holds the
**domain** `@racwg.com`, not any single address, and the Gmail query is `from:racwg.com`.
Payment advices are supposed to go back to `accountsahmd@racwg.com`.

A sender match alone is not enough to book money: RAC also send reminders and replies on
the same thread, so `Match RAC + Pick Bill` additionally requires the subject or body to
look like an invoice, and requires an attachment. The `SUBJECT_KEYWORDS` /
`\brac\b` test is now only the fallback for mail from some other address.

Their invoice numbers look like `AMD/26-27/00669` (branch / FY / serial) and the subject
is `E-INVOICE-<BILLED ENTITY> -<invoice no>`. Note the bills are raised on **IKIGAI
INFOTECH LLP**, not Saleshandy.

> **The same two lists are duplicated in `Gmail Invoice Auto-Capture` →
> `Normalize PDF Attachment`, which uses them to SKIP these mails.** Its own Gmail
> query (`invoice OR bill OR renewal …`) matches a RAC bill just as well, so without
> that guard one bill is booked twice: once as a rental payment and once as a service
> contract that then starts firing renewal alerts. **Change both together.**

### RAC Payment Proof Auto-Capture

`Gmail Trigger (Sent) → Match Proof + Pick File → Is PDF? → (true) Extract Proof Text →
Build Proof Request → AI Parse Payment Proof → Settle Payment → Attach Proof to NAS →
Build Payment Summary → Notify via ntfy`

The mirror of the bill workflow. A bill arrives **from** `racwg.com`; the proof of payment
goes back **to** them, from us, on the same thread — so this trigger watches
`labelIds: ['SENT']` with `q: to:racwg.com has:attachment`, and it **settles** the row the
bill workflow created rather than creating one.

> **The signature block is attachments too — seven of them.** A real proof mail carried
> `image001.jpg` … `image007.png` (Gmail inlines a signature and names those parts
> sequentially) plus the actual screenshot. `Match Proof + Pick File` prefers a PDF;
> among images it ranks anything matching `^image\d{3}\.(png|jpe?g|gif|webp)$` **last**,
> then takes the largest. Size alone was not safe — the biggest signature part was
> within 2KB of the proof. Sub-8KB files are dropped only when there is something else to
> compare against, so a small but genuine screenshot survives, and an inlined-looking
> name is still eligible if it is all there is. The parser's `looks_like_payment_proof`
> flag is the final backstop: if the wrong file is picked, `Settle Payment` throws to the
> high-priority ntfy rather than filing a logo as a receipt.

> **It never guesses which bill to settle.** Invoice numbers are gathered from the
> parser's answer plus a `[A-Z]{2,4}/dd-dd/ddddd`-shaped scan of the subject and body.
> Zero matches or more than one and `Settle Payment` throws — its error output goes to
> `Notify Proof Failure`, a high-priority ntfy, and nothing is written. Settling the
> wrong row is worse than settling none.

> **`paid_amount` comes off the proof, not the invoice.** The gap is reported explicitly
> ("Short by Rs.64 — expected, that is the 2% TDS") and a payment *larger* than the bill
> is flagged for checking. It also warns when `paid_on` is after `due_date`.

Re-delivery is safe: a row already Paid with the same amount and date makes the node
return `[]`, so no duplicate NAS copy and no second alert.

### Gmail Invoice Auto-Capture

`Gmail Trigger → Normalize PDF Attachment → Extract PDF Text → Get Existing Vendors
→ Get Existing Domains → Build Parse Request → AI Parse Invoice → Create Vendor +
Service in Console → Update Domain Seats → Attach Original PDF → Notify via ntfy`

`Update Domain Seats` also keeps the **linked base contract** in step: after bumping
`domains.total_seats` it follows `domains.service_id` and rewrites that contract's
`(N Users)` label and its `Total Users: N` note. Seat counts otherwise live in two
unconnected places and drift apart. The whole block is wrapped in try/catch so a
contract-sync failure can never break the domain update or the steps after it.

### New Joiners Auto Add (SH / HA / TI)

One workflow, three departments. All three tabs come back in a **single**
`values:batchGet` call with three `ranges` params — the order of `ranges` in the URL
must match the `DEPARTMENTS` array in the code node.

Add-only. For every row where **Joining Status = `Joined`**
and **Mail ID Created** is a valid address, creates a console mailbox
(`status: Active`, `purpose: "<Designation> - <Department>"`).

They never update or remove anything. Deactivating leavers is a manual job in the
console — see [Known gaps](#known-gaps).

**Why they do not re-create people you delete by hand:** each workflow keeps a
`seenJoinerEmails` list in n8n static data. The **first run baselines** everything
currently in the tab and adds nobody; after that only genuinely new sheet entries
are added. HR never flips a leaver's row back from `Joined`, so without this a row
deleted from the console would reappear within 30 minutes, as `Active`, forever.

A re-hire is therefore *not* auto-added — their address is already "seen". Add them
in the console by hand. This is deliberate: it is the same property that protects
manual deletes.

**Domain validation:** the mail id's domain must already exist in `GET /api/domains`,
or the mailbox is not created and the address is reported instead. Bad addresses are
remembered in `reportedProblems` static data so each one alerts once, not every 30
minutes.

Baseline captured on 29-08-2026: 51 addresses (SH 46, HA 1, TI 7, minus 3 rejected).

> [!WARNING] The TI tab has bad mail IDs
> State of its 7 `Joined` rows as of 29-08-2026, after `trulyinbox.com` was added to
> the console:
> - `kaushal@`, `saurav@`, `ife@` **`trulyinbox.com`** — real, and now in the console.
>   These used to be rejected because the domain did not exist; that is fixed.
> - `sneh@saleshandy.com`, `dhruvam@saleshandy.com` — **the sheet has the wrong
>   domain.** Both people are real but their mailboxes are `@trulyinbox.com`, and are
>   in the console under those addresses. The sheet needs correcting, not the console.
> - `karan.g@saleshandy.com`, `jiten@saleshandy.com` — exist in **no** Google tenant.
>   The `TrulyInbox GW` sheet separately listed `karan.g@trulyinbox.com`, also absent
>   everywhere; that row was deleted on 29-08-2026. Never created, apparently.
>
> All 7 are in the baseline, so none of them will be auto-added. If the wrong-domain
> rows are corrected in the sheet, the fixed addresses count as new and will sync.
>
> `IKI-LP-85` also appears in the SH tab's Mail ID column — a laptop asset tag, not an
> email. Rejected as bad format.

### Saleshandy User List → G Suite Sheet

`Every 30 Minutes / Run Manually → Read Sheet (A-K) → Build User Rows → Layout OK?
→ Write Users to Sheet (A-D) → Colour Status Column (D) → Anything to Report? → Notify via ntfy`
(`Layout OK?` false branch → `Alert: Layout Changed`)

> [!IMPORTANT] The notify gate exists because of the 30-minute cadence
> This sync rewrites the whole block on every run, and its ntfy node was originally
> ungated — fine at one run per two days, but **48 messages a day** at 30 minutes.
> `Anything to Report?` now passes only when `reportFlag` is set, i.e. the written
> content actually differs from `lastWritten`, or drift was detected.

Runs on the same 30-minute beat as the joiner sync, so a new mailbox reaches its
sheet in the same cycle it reaches the console. Pushes console `saleshandy.com`
mailboxes into the users spreadsheet. One read of
`A1:K200` serves three purposes: header check, current A–D content (drift), and the
H–K role addresses.

Two safety features, both tested by deliberately breaking the sheet:

- **Header guard** — if `A1:D1` is not exactly
  `First Name | Last Name | Email Address | Status`, it writes **nothing** and sends a
  high-priority ntfy alert. Without this, someone inserting a column would make it
  silently write into the wrong columns forever.
- **Drift alert** — it stores what it last wrote (`lastWritten` static data) and
  compares against the sheet before overwriting. Any hand edit is reported by row,
  with old and new values. It reports, it does not prevent — to actually prevent
  edits, protect `A2:D200` via *Data → Protect sheets and ranges*.

---

### Krishnabusiness User List → G Suite Krishna 20

`Every 30 Minutes / Run Manually → Read Krishna Sheet → Build Krishna Rows → Rows to Append?`
→ true: `Insert Blank Rows` → `Write New Rows` → `Notify via ntfy`
→ false: `Anything to Report?` → `Notify via ntfy`

**Append-only, and deliberately so.** Unlike the Saleshandy sync (which rewrites
`A2:D200` wholesale), this one **never modifies an existing row** — the `Purpose` and
`Current User` columns hold hand-written text that must survive, and rows carry manual
highlighting (the admin `leo@humbersolutions.com` is green; a stray red row sits below
the block).

A user row is one where **A is a number and B is an email**. Everything else is
ignored — notably the multi-line domain-list cell and the stray red row underneath
the user block.

New people are added by `insertDimension` (`inheritFromBefore: true`) immediately
after the last user row, then written with `values.update`. The rows below **shift
down intact** rather than being overwritten. Verified 29-08-2026 by adding a test
mailbox: the new row landed at 24, the domain-list block moved 24→25 and the red row
25→26; both were restored afterwards with `deleteDimension`.

Drift is keyed **by email, not row number**, so inserting rows does not raise false
alarms. Any hand edit to an existing row (including the admin row) is reported to ntfy
with old and new values, as is any row that disappears.

---

### TrulyInbox User List → TrulyInbox GW

Same shape as the Krishnabusiness sync and **append-only for the same reason**: row 2
(`vatsal@trulyinbox.com`, the tenant admin) is highlighted green by hand. A full
rewrite would re-sort the block and drop that highlight on the wrong person.

Sheet `sheetId` 946850404, columns `A=Sr # B=First Name C=Last Name D=Email Address`.
New people are inserted after the last user row via `insertDimension`, then written
with `values.update`. Verified 29-08-2026 with a throwaway mailbox (landed at row 14,
Sr# 13) and removed again with `deleteDimension`.

Rows that are **in the sheet but not in the console** are reported, never deleted.

Reconciled against the Google export on 29-08-2026 — the tab now matches it exactly,
11 rows, Sr # 1-11:
- `karan.g@trulyinbox.com` removed (existed in no Google tenant) and the Sr # column
  renumbered
- `Truluinbox` -> `Trulyinbox`, `Ife@` -> `ife@`, `Trulyinbox` -> `trulyinbox` for
  `contribute@`

After any such manual fix, clear the workflow's `snapshot` static data, or the next
run reports your own edit as drift.

---

### Which sheets survive a hand edit

This decides where to fix a name.

| Sheet | Write style | A hand edit... |
|---|---|---|
| `G Suite Main 89` | `PUT A2:D200` — full rewrite every run | **is overwritten.** Fix names in the **IT console**, not the sheet |
| `G Suite Krishna 20` | `insertDimension` + write only the new rows | **survives** |
| `TrulyInbox GW` | `insertDimension` + write only the new rows | **survives** |

The two append-only syncs report a hand edit as drift but never revert it. The
Saleshandy one reports it *and* overwrites it, because it owns the whole block.

> [!WARNING] Write Sr # as a number, not a string
> The append syncs originally built the row as `[String(lastSr + 1 + k), ...]`, so
> Google stored the Sr # as **text** — left-aligned, unlike every hand-entered row.
> Fixed 29-08-2026 in both workflows to `[lastSr + 1 + k, ...]`. Same trap applies to
> any numeric column: with `valueInputOption=RAW` a JSON string stays text.

---

### Exit Sync - Remove Leavers from Console

`Every Day / Run Manually → Read Exit Sheet → Remove Exited Mailboxes →
Anything to Report? → Notify via ntfy`

Reads the HR `Exit-2026` tab and **deletes** the console mailbox one day after a
person's exit date. Nothing about *why* they left is recorded in the console — the
sheet already holds that.

> [!DANGER] This is the only workflow that deletes console data
> Deletion is irreversible; the console has no version history. It only ever acts on
> a row that carries an explicit **Mail ID in column J**, matched exactly. Back up
> `data.sqlite` before changing this workflow.

**Column J (`Mail ID`) was added by us on 29-08-2026** — the tab originally had names
only. Matching leavers by name was tested and is **unsafe**: of 27 exit rows, only 2
matched a single console account, 2 were ambiguous, and "Ravi Khatri" matched
`ravip@saleshandy.com`, who is **Ravi Prajapati, the admin on two contracts**. Never
reintroduce name matching. Rows without a Mail ID are skipped silently.

Row position is ignored on purpose: HR fills this tab **bottom-to-top**, inserting each
new leaver *above* the previous one, so every row with a Mail ID and an exit date is
considered wherever it sits.

Exit dates are free text (`3rd September 2026`, `27th Feb 2026`, and the real typo
`20th Feb2026`). The parser strips ordinal suffixes, re-inserts a missing space before
the year, and matches the month on its first three letters. Anything it cannot read is
reported, never guessed.

> [!WARNING] The >90-day guard
> The sheet contains `25th August 2025` where the Month column says `Aug'26`, and
> `8th May 2025` under `Mar'26` — mistyped years. Without a guard those read as long
> overdue and would delete instantly. Any exit date more than **90 days** in the past
> is therefore reported instead of actioned. Remove the guard only if the sheet's
> dates get cleaned up.

Verified end-to-end 29-08-2026 with a throwaway mailbox and a test row in the sheet's
empty row 50; the mailbox was deleted and the row cleared afterwards. On the same run
the pending list correctly read `Abhishek Tiwari -> 2026-09-01` and
`Devanshi -> 2026-09-04`, one day after each exit date.

---

### Year rollover — tabs are discovered, not hardcoded

HR creates a new tab every year (`New Joiners- 2026 (SH)` becomes `... 2027 (SH)`,
`Exit-2026` becomes `Exit-2027`). Both HR-driven workflows therefore **look the tabs
up at runtime** instead of naming them:

`List Sheet Tabs` -> `Pick ... Tabs` -> `Tabs Found?` -> `Read ...` (false branch:
high-priority ntfy alert).

- **Joiners** match a title containing `new joiner`, a year >= 2026, and `(SH)`/`(HA)`/`(TI)`.
- **Exits** match `^Exit-<year>$` with year >= 2026 — strict on purpose, so the older
  `Exit Oct-Dec'25` and `Old Exit` tabs are not picked up.
- **Every matching year is read**, not just the newest, so the changeover period is
  covered when entries land in both the old and the new tab.
- If **nothing** matches, the workflow writes nothing and sends a high-priority alert
  listing the tabs it did find.

> [!WARNING] Why this mattered
> With the year hardcoded, the day HR moved to 2027 these workflows would have kept
> reading the dead 2026 tab, found nothing new, and **failed silently** — no error, no
> alert, new joiners never added and leavers never removed.
>
> Verified 29-08-2026 by creating real `Exit-2027` and `New Joiners- 2027 (SH)` tabs:
> both workflows picked them up with no config change, and the tabs were deleted again.

The department is now read from each returned range (`'New Joiners- 2026 (SH)'!A1:S1100`)
rather than from the position of the range in the batchGet. The order of discovered
tabs is not stable, and an earlier version that assumed it **mislabelled SH as HA**.

---

### Saleshandy Solutions <-> SaleshandySolutions-10

**The only two-way sync.** Everything else pushes one direction; this one lets a change
on either side reach the other.

`Every 30 Minutes / Run Manually -> Read Solutions Sheet -> Reconcile Sheet and Console
-> Sheet Edits? -> Apply Sheet Edits -> Rows to Append? -> Insert Blank Rows ->
Write New Rows -> Anything to Report? -> Notify via ntfy`
(both IF nodes fall through to the next stage, so either path still reaches the notify)

Tab `SaleshandySolutions-10` (`sheetId` 623354432), columns
`A=Sr # B=Email C=Status D=Purpose E=Current User F=Password`.

> [!DANGER] Column F holds passwords
> It is never read, never written, and never logged. The reconcile code only ever
> touches C, D and E, and appends write `A:E`.

> [!IMPORTANT] How direction is decided — three-way compare
> "Sheet and console differ" does not say *which side changed*. The workflow keeps a
> `snapshot` of the last synced state in static data and compares all three:
>
> | sheet vs snapshot | console vs snapshot | action |
> |---|---|---|
> | changed | unchanged | sheet -> console |
> | unchanged | changed | console -> sheet |
> | **changed** | **changed** | **conflict — nothing applied, both values reported** |
>
> Without the snapshot one side would always have to win blindly, silently discarding
> the other's edit. The first run only baselines.

**Deletions are reported, never performed** — on either side. A row vanishing from one
side is ambiguous (deleted there, or added on the other?) and this is the one sync that
writes to both, so it says so instead of guessing. Adds and field edits do propagate
automatically.

Verified end-to-end 29-08-2026, all three paths, then restored and re-baselined:
- console purpose changed -> landed in sheet row 8
- sheet `D9` changed -> landed in the console
- both sides changed on the same row -> reported as a conflict, **neither** overwritten

The tenant is `saleshandysolutions.com` (Primary, 10 seats, contract id 3 via
Cloudgeneric) with `saleshandytech.com`, `saleshandyagency.com` and
`saleshandypro.com` as secondaries — 10 mailboxes across the four.

> [!WARNING] Domain structure is inferred, not verified
> Primary/secondary was deduced from contract id 3 (one 10-user contract, admin
> `dhruv@SaleshandySolutions.com`, the green row in the sheet). It has **not** been
> checked against that tenant's Google Admin Console *Manage domains* page.

---

## Google Sheets reference

### HR sheet — `11xaUZgLZXOr6o5vJGqOLyXjrLhN6CrAH01ziLbjvH9Y`

| Tab | sheetId | Synced by |
|---|---|---|
| `New Joiners- 2026 (SH)` | 648858717 | `newJoinersAuto` |
| `New Joiners- 2026 (TI)` | 1111669315 | `newJoinersAuto` |
| `New Joiners-2026(HA)` | 1586203670 | `newJoinersAuto` |
| `Exit-2026` | 1823075134 | `exitSync00001` |
| `New Joiner- Oct-Dec'25` | 794622375 | — |
| `Exit Oct-Dec'25` | 1669128865 | — |
| `Old Exit` | 537209204 | — |
| `New Joiner` | 0 | — |

All joiner tabs share one column layout (0-based indexes):

| Idx | Col | Field |
|---|---|---|
| 2 | C | Tentative Joining Date |
| 3 | D | Department |
| 5 | F | Name of the Candidate |
| 6 | G | Designation Offered |
| 7 | H | **Joining Status** (`Joined`, `Not Joined`, `Declined the offer`) |
| 12 | M | **Mail ID Created** |

> Cells contain stray leading spaces and embedded newlines — one real value is
> `"        \navinash.v@highadvocacy.com"`. **`.trim()` every read** or matching fails.
> Joining dates are free text with no year (`26 Jan`, `10th Aug `, `29th June`), so
> do not build logic on parsing them.

### Users sheet — `1wSiylxdg06EBn8a-jFm7j_sORSp3UlwsA6Udj4FbKOg`

13 tabs. Synced ones first:

| Tab | sheetId | Synced by | Write style |
|---|---|---|---|
| `G Suite Main 89` | 708600971 | `shSheetSync001` | full rewrite of `A2:D200` |
| `G Suite Krishna 20` | 860200999 | `krishnaSheetSync` | **append-only** |
| `TrulyInbox GW` | 946850404 | `tiSheetSync001` | **append-only** |
| `G Suite Team 07` | 1240889154 | — | |
| `O365 Truly Inbox 33` | 831155614 | — | |
| `SaleshandySolutions-10` | 623354432 | `solSheetSync01` | **two-way** |
| `Billing` | 1033869637 | — | |
| `Zoho 04` | 1740466391 | — | |
| `Gmail` | 794728471 | — | |
| `Product Team` | 1495857269 | — | |
| `Domain List` | 1276312201 | — | |
| `New` | 1187467786 | — | |
| `GD` | 398230838 | — | |

The three synced tabs have **different column layouts** — do not copy code between them:

| | `G Suite Main 89` | `G Suite Krishna 20` | `TrulyInbox GW` |
|---|---|---|---|
| A | First Name | Sr # | Sr # |
| B | Last Name | Email Address | First Name |
| C | Email Address | Status | Last Name |
| D | Status | Purpose | Email Address |
| E | — | Current User | — |

**Every tab has a different layout. Never copy a range or index between them.**
`TrulyInbox GW` has no Status column at all, so no status colouring is applied there.

`G Suite Krishna 20` also has a yellow header row, a green admin row
(`leo@humbersolutions.com`), a multi-line domain-list cell below the user block, and a
red row below that. None of it is touched.

`G Suite Main 89` has **two independent blocks**:

| Range | Content | Owner |
|---|---|---|
| `A2:D200` | regular user list | **the workflow** |
| `H:K` | role / shared mailboxes | **maintained by hand — never write here** |

The workflow *reads* H–K and excludes those addresses from A–D so nobody is listed
twice. Add a role address to H–K and it drops out of A–D automatically. Currently 9:
`webmaster@ affiliates@ contribute@ growth@ sales@ careers@ vatsal@ finance@ interns@`.

Status colours are literal cell backgrounds (**there are no conditional formatting
rules on this sheet**), applied with `batchUpdate` → `updateCells` restricted to
`fields: userEnteredFormat.backgroundColor` on column D:

| Status | Colour |
|---|---|
| Active | light green `RGB(182,215,168)` |
| Inactive | light red `RGB(224,102,102)` |
| blank row | white |

Values are written with `values.update` on `A2:D200`, padded to row 200 so leavers
do not leave stale rows. Neither call touches font, width, borders, or the header row.

---

## Credentials

| ID | Type | Name |
|---|---|---|
| `b1dYZNasS1uLkc9D` | `oAuth2Api` (generic) | Google Sheets - HR Onboarding |
| `vtDw4Vtd1koXODAF` | `gmailOAuth2` | Gmail account |
| `pFzfcXy8ADvEAAMR` | `oAuth2Api` | Unnamed credential (unused as far as we know) |

> **The Sheets credential was read-only until 29-08-2026.** Every write returned
> `403 ACCESS_TOKEN_SCOPE_INSUFFICIENT`. It was re-authorised with
> `https://www.googleapis.com/auth/spreadsheets`. If writes start 403-ing again,
> check the scope first — it is a generic `oAuth2Api` credential, so the scope is
> whatever was typed into the credential form, not an n8n-managed default.

---

## n8n gotchas
### A sync that fails only into n8n's log is a sync nobody is watching

`Saleshandy User List -> G Suite Sheet` failed **46 times over two days** and the only
trace was a red row in n8n's execution list. The console kept working, so the only
outward sign was a master sheet that had quietly stopped updating.

Two changes came out of that (01-09-2026):

**Retry on every Google API call.** Sheets returns `The service is currently unavailable`
(a 503) often enough to have eaten 17 runs in 24h — roughly 11%. All 20 `googleapis.com`
HTTP nodes now carry `retryOnFail: true, maxTries: 3, waitBetweenTries: 5000`.

**A shared error workflow.** `Sync Failure Alert` (`syncFailAlert01`) is an
`errorTrigger` → ntfy, and every other workflow sets `settings.errorWorkflow` to it. The
alert is high priority and names the workflow, the failing node, the reason and a direct
link to the execution.

> **Order matters: retry first, alert second.** Without the retry the alert would fire on
> every transient Google blip and be tuned out inside a week.

> **`n8n execute` cannot test this.** The CLI tears its DB connection down as it exits, so
> the error workflow dies with `Driver has already been released.` even though n8n did
> try to call it. Test with a scheduled workflow instead — a temporary one that throws,
> activated for a minute — which exercises the real production path.

### Never hardcode a tab name that carries a count

HR name these tabs after the licence count — `G Suite Main 89`, `G Suite Krishna 20`,
`SaleshandySolutions-10` — and rename them when the count moves. `shSheetSync001` had
`G Suite Main 89` baked into two URLs; the tab became **`G Suite Main 111`** and every
run since died on `Unable to parse range: G Suite Main 89!A1:K200`.

It failed **loudly in n8n and silently everywhere else**: the console kept updating, the
master sheet quietly stopped, and a leaver removed from the console still showed as
Active in the sheet for days. That is how it was found (01-09-2026).

A tab's numeric **`sheetId` does not change on rename**. Each of these workflows now
starts `List Tabs → Resolve Tab Name`, resolving the title from its id, and every URL
and write-range is built from that:

| Workflow | sheetId |
|---|---|
| `shSheetSync001` | `708600971` |
| `krishnaSheetSync` | `860200999` |
| `solSheetSync01` | `623354432` |

`Resolve Tab Name` throws — naming every tab it did find — if the id is gone, so a
deleted tab is an explicit failure rather than a wrong range.

> Write ranges are assembled inside the Code nodes, so `const TAB = $('Resolve Tab
> Name').first().json.tab;` is used there too. Fixing only the read URL leaves the
> workflow half-migrated and still liable to break.

> `TrulyInbox GW` carries no count, so `tiSheetSync001` was never exposed — it is the
> only one of the four that is safe by luck rather than design.

### Gmail hands you objects, not strings

`from`, `to` and `cc` on a Gmail trigger/node item are **objects**:

```js
from: { value: [{ address: 'accounts@racwg.com', name: 'Parshuram Kuwlekar' }],
        html: '…', text: '"Parshuram Kuwlekar" <accounts@racwg.com>' }
```

`subject`, `text` and `html` are plain strings; the three address fields are not.
`String(item.json.from)` gives **`"[object Object]"`**, so every `.includes('@domain')`
test against it is silently false and the workflow processes nothing while reporting
success. Found 01-09-2026 — it had killed **both** RAC workflows outright and disabled
the RAC skip-guard in `Gmail Invoice Auto-Capture`, which had also been writing
`[object Object]` into service notes and ntfy as the sender.

Every matcher now goes through:

```js
const addr = (v) => {
  if (!v) return '';
  if (typeof v === 'string') return v;
  if (typeof v.text === 'string') return v.text;
  if (Array.isArray(v.value)) return v.value.map(x => (x && x.address) || '').join(' ');
  return '';
};
```

> **The manual fixtures hid this.** They handed the matcher a plain string, so the tests
> exercised a shape Gmail never sends and passed while production was dead. The fixtures
> now emit the object form. **A fixture that does not mirror the real payload is worse
> than no fixture** — it buys false confidence.

### Dates: never derive "today" from UTC

n8n's instance timezone is **Asia/Kolkata** and schedules fire on Indian local time —
but `new Date()` / `getUTCDate()` / `toISOString()` inside a Code node ignore that
setting entirely. A schedule at **00:00 IST is 18:30 UTC the previous day**, so any
hand-rolled "today" is a day behind for the whole 00:00–05:30 window.

This shipped as a real bug: `Exit Sync` compared a leaver's removal date against a
UTC-derived today, so **every leaver was removed a day late**. Caught 01-09-2026 when
Abhishek Tiwari (exit 31-08, due 01-09) was still in the console after the 00:00 run
reported him as pending.

Use this instead — it is in `Remove Exited Mailboxes`, `Record Payment + Sync Laptops`
and `Build Payment Summary`:

```js
const istToday = () => new Date(Date.now() + 5.5 * 3600000).toISOString().slice(0, 10);
// or, when a Date object is needed for comparison:
const istNow = new Date(Date.now() + 5.5 * 3600000);
const today = new Date(Date.UTC(istNow.getUTCFullYear(), istNow.getUTCMonth(), istNow.getUTCDate(), 12, 0, 0));
```

`Remove Exited Mailboxes` now also returns `ranAsOf`, so the date it actually decided on
is visible in the run output instead of having to be inferred.


These have each cost real debugging time.

**A JSON body must use `specifyBody`, not `body`.** For `httpRequest` typeVersion
`4.2` the node must read:

```json
"contentType": "json",
"specifyBody": "json",
"jsonBody": "={{ JSON.stringify({ ... }) }}"
```

A plain `"body"` key does **not** survive `n8n import:workflow` — the CLI silently
rewrites the node to `"bodyParameters":{"parameters":[{}]}` and drops `contentType`,
leaving the request with an empty body. This silently broke `AI Parse Invoice` once.
To check any node shape: import a throwaway workflow, immediately `export:workflow`
it, and diff the parameters.

**`import:workflow` deactivates the workflow it overwrites.** Always:

```bash
docker exec n8n n8n update:workflow --id=<ID> --active=true
docker restart n8n     # DB changes do not take effect while n8n is running
```

**Running a workflow from the CLI** fails two different ways:

```bash
# "Task Broker's port 5679 is already in use"  -> override the ports
docker exec -e N8N_RUNNERS_BROKER_PORT=5699 -e N8N_PORT=5698 n8n n8n execute --id=<ID>

# "Missing node to start execution"  -> the workflow has only a schedule trigger.
# Add a manualTrigger node; worth keeping permanently for on-demand runs.
```

**There is no CLI delete.** Remove a workflow with node + sqlite3 in the container:

```bash
docker exec n8n node -e '
const s=require("/usr/local/lib/node_modules/n8n/node_modules/sqlite3");
const db=new s.Database("/home/node/.n8n/database.sqlite");
db.run("DELETE FROM workflow_entity WHERE id=?",["<ID>"],function(){console.log(this.changes)});
'
```

**n8n expressions are single-expression only.** A multi-statement IIFE with `let`
and `if` in a node parameter throws `Invalid or unexpected token`. Build message
strings inside a Code node and reference `{{ $('Node Name').first().json.message }}`.

**Newlines inside Code-node strings.** Writing the JS via a script that interprets
`\n` will inject a real newline and break the string literal. Use
`String.fromCharCode(10)` in the JS, or write the file with a quoted heredoc.

**Static data lives under a `global` key.** `$getWorkflowStaticData('global')`
persists to `workflow_entity.staticData` as `{"global":{...}}` — reading
`o.seenJoinerEmails` returns undefined, it is `o.global.seenJoinerEmails`. It is
saved only for production (trigger/schedule) executions, not manual UI runs.

**`node` is not installed on the macOS host.** Run any test harness inside a
container instead: `docker cp` the script in, then `docker exec n8n node /tmp/x.js`.

**Container `/tmp` cleanup needs root:** `docker exec -u root n8n rm -f /tmp/x.json`.

---

## IT console UI notes

`server.js` serves `index.html` from **its own route, registered before
`express.static`**, so it can stamp `app.js?v=<mtime>` and `style.css?v=<mtime>` and
send the HTML as `Cache-Control: no-store`. Without that, a UI deploy is invisible
until the user hard-refreshes — `express.static` gives `app.js` a stable URL and
browsers keep serving the cached copy. If you move that route after `express.static`
it stops working, because static wins for `/`.

Domain rows whose name has **no dot** (`Product Team`, `Batch-1`) are treated as
grouping rows, not real domains: folder icon, a "N domains" badge instead of
"N mailboxes", and their mailbox tables are hidden. The same `isGroupRow` test keeps
them out of the dashboard's domain count. `openSubdomainDetail` renders a
third level ("Domains grouped under this"), and the parent dropdown lists grouping
secondaries as `↳ Batch-1` so a domain can be filed one level down.

Both of those cards call `switchTab('mailboxes')`. Pass the **tab key**, not the DOM
id — `switchTab` builds the element id itself (`tab-${tabId}`), so an id like
`tab-mailboxes` resolves to `tab-tab-mailboxes`, matches nothing, and leaves the
content area blank after clearing every `.active`.

Two dashboard cards — **Domains Tracked** and **Licensed Seats** — are computed in
`renderDomainKpis()` from `domainsData` / `mailboxesData` already in memory, not from
`/api/dashboard/stats`. They are refreshed from both `fetchDomains` and
`fetchMailboxes`, so they stay right after any edit. Seats sum `total_seats` across
every domain that carries one and compare against `usedSeatsForPrimary`; the value
turns red if used ever exceeds purchased.

---

## RAC Laptops tab (rented hardware)

Sidebar entry **RAC Laptops** → `#tab-rentals`. Covers laptops taken on rent from a
vendor (RAC is the first), which are deliberately **not** modelled as
`services_contracts`: a rental is an open-ended monthly payment against a machine that
goes back, not a licence with an expiry date, so it must never land in the renewal
alerts or in the yearly-spend KPI.

Two tables in `data.sqlite`:

| Table | Holds |
|---|---|
| `rented_assets` | one row per laptop — name/tag, model, serial, who has it, monthly rent, on-rent-since, status (`On Rent` / `Returned`), `gmail_link`, notes |
| `rental_payments` | one row per **bill or payment** — amount, `payment_date`, `due_date`, `period_label`, `invoice_no`, method, `gmail_link`, `status`, optional `asset_id` |

`due_date` comes off the invoice PDF (the email body never carries it). An unpaid row
past its due date shows the date in red with "overdue" under it, and the dashboard card
says `N OVERDUE` instead of the next due date. RAC charge **18% a year** on late
payment, so this is not decoration.

`paid_on` is when the money actually left, which is **not** `payment_date` (that holds
the bill's own date). "Mark paid" prompts for it and "Last Payment Made" sorts and
displays by it, falling back to `payment_date` only for rows written before the column
existed.

`paid_amount` is what actually left the bank. **RAC deduct 2% TDS u/s 194I, so this is
routinely lower than the invoice** — Rs.3,776 billed, Rs.3,712 paid. `amount` keeps the
invoice value; `paid_amount` is null when the two matched. Everything that answers "how
much have we paid" uses `paid_amount ?? amount`, in the UI and in the workflow's
`Build Payment Summary` (its `outflow()` helper). Get this wrong and the console
disagrees with the bank statement every single month.

`rented_assets.assigned_to` is **not shown in the UI** — who holds which machine is
tracked in Keka, and a second half-maintained copy is worse than none. The column and
any values in it are left alone: the laptop form echoes the stored value back on save so
it cannot be wiped.

`rental_payments.asset_id` is **nullable and normally NULL** — the vendor bills the
whole fleet on one invoice, so a payment covers all laptops unless it is explicitly
tagged to one. Deleting a laptop does **not** delete its payments (money that actually
left the account stays on record); the FK is `ON DELETE SET NULL` and the row then
reads "Deleted laptop".

**`status` is `Pending` or `Paid`, and the difference matters.** RAC email an invoice
asking to be paid by a due date; booking that as a payment made the dashboard claim money
had left the account when it had not. Auto-captured rows land as `Pending`; the row
carries a one-click **Mark paid** button; and "Last Payment Made" plus every
"already paid" total counts `Paid` rows only, with the unpaid balance shown alongside.

One row holds **as many files as it needs** — the invoice PDF *and* the payment-proof
screenshot both hang off the same payment, because they are two halves of one
transaction. The column is "Bill / Proof", and `attachmentThumb()` renders anything
matching `.jpe?g|png|webp|heic|gif` as a **thumbnail** rather than a filename link; a
proof you cannot see at a glance is not much of a proof. Uploads already accepted those
types (`billFileFilter` in `server.js`) — only the rendering was missing.

Bills attach through the shared `attachments` table with `entity_type =
'rental_payment'`, and land on the NAS under `Documents/RAC/` — folder resolved from
`rental_payments.vendor_name`, same as any other vendor's paperwork. `gmail_link` is
the alternative when the bill is only an email: the Bill column renders the uploaded
PDFs first, then an "✉️ Gmail thread" link if one is set.

Routes:

| Route | Notes |
|---|---|
| `GET/POST /api/rentals`, `PUT/DELETE /api/rentals/:id` | `PUT` is a full replace, like everywhere else |
| `GET/POST /api/rental-payments`, `PUT/DELETE /api/rental-payments/:id` | ordered `payment_date DESC` — the "Last Payment Made" card just reads `[0]` |
| `POST /api/rental-payments/:id/bill` | multipart, field name `bill` |

The three cards on the tab (`renderRentalKpis`) count only laptops whose status is
`On Rent`, so a returned machine stops inflating the monthly rent figure.

**Not yet automated.** The bills arrive over Gmail and are entered by hand for now;
no workflow reads them. Wiring that up needs the Gmail connector authorised first.

---

## IT console API contracts

Only what workflows depend on. Source: `../server.js`.

| Route | Notes |
|---|---|
| `GET /api/mailboxes` | full list |
| `POST /api/mailboxes` | `{email, status, purpose, current_user, notes}` |
| `PUT /api/mailboxes/:id` | full replace |
| `DELETE /api/mailboxes/:id` | |
| `GET/POST /api/domains`, `PUT/DELETE /api/domains/:id` | |
| `GET/POST /api/services`, `PUT/DELETE /api/services/:id` | |
| `GET/POST /api/payments`, `DELETE /api/payments/:id` | **no PUT** |
| `POST /api/services/:id/bill` | multipart, field name `bill` |
| `GET/POST /api/rentals`, `PUT/DELETE /api/rentals/:id` | rented laptops |
| `GET/POST /api/rental-payments`, `PUT/DELETE /api/rental-payments/:id` | rental payments |

> **`PUT` is a full-record replace, not a patch.** Echo every field back or it is
> written as NULL. `PUT /api/services/:id` additionally recomputes `status`
> server-side from `expiry_date` and ignores any `status` sent by the client.

> **There are no single-item GET routes.** `GET /api/domains/:id` and
> `/api/services/:id` fall through to the SPA and return `index.html`. Always GET
> the full list and filter.

> **`DELETE /api/services/:id` does not clean up foreign keys** — neither
> `domains.service_id` nor `payment_history.service_id`. Check both before deleting
> or you orphan payment rows and silently break the seat-sync block (its try/catch
> swallows the error). To move a payment: **POST the replacement first, verify, then
> DELETE the original** — there is no `PUT /api/payments/:id`.

---

## Deploying a change

```bash
# 1. export what is live (never edit workflows.json blind)
ssh IKI-MAC-27 '/usr/local/bin/docker exec n8n n8n export:workflow --id=<ID> --output=/tmp/w.json >/dev/null 2>&1; \
  /usr/local/bin/docker exec n8n cat /tmp/w.json; /usr/local/bin/docker exec -u root n8n rm -f /tmp/w.json' > w.json

# 2. edit w.json  (patch parameters.jsCode from a separate .js file - see gotchas)

# 3. import, reactivate, restart
scp -q w.json IKI-MAC-27:/tmp/w.json
ssh IKI-MAC-27 '/usr/local/bin/docker cp /tmp/w.json n8n:/tmp/w.json && \
  /usr/local/bin/docker exec n8n n8n import:workflow --input=/tmp/w.json && \
  /usr/local/bin/docker exec n8n n8n update:workflow --id=<ID> --active=true && \
  /usr/local/bin/docker restart n8n'

# 4. verify
ssh IKI-MAC-27 '/usr/local/bin/docker exec n8n n8n list:workflow --active=true'
```

**Back up the console DB before anything that writes to it:**

```bash
ssh IKI-MAC-27 'cp ~/it-billing-console/data.sqlite ~/it-billing-console/data.sqlite.bak-$(date +%Y%m%d-%H%M)'
```

Existing backups on the host: `.bak-20260828-before-id2-merge`,
`.bak-20260828-before-mailbox-sync`, `.bak-20260829-krishna-seats`,
`.bak-20260829-ha-test`, `.bak-20260829-before-ti`,
`.bak-20260829-before-exitsync`, `.bak-20260829-before-solutions`.

Reading execution output (the CLI dump is huge — grep it):

```bash
docker exec n8n node -e '...'   # execution_entity for ids/status
                                # execution_data.data for the returned JSON
```

`execution_data.data` is a **flattened pool**: a JSON array where numeric strings are
indexes back into the same array. Resolve recursively before reading values.

---

## Known gaps

- **Leaver removal now runs off `Exit-2026`** (`exitSync00001`, added 29-08-2026) but
  only for rows where HR fills in the new **Mail ID** column. Rows without it are
  skipped, so the gap is closed only as far as HR keeps that column filled. Before
  this, nine stale `saleshandy.com` mailboxes had to be reconciled by hand on
  28-08-2026 against a Google user export.
- **`G Suite Team 07`** has no sync.
- **`trulyinbox.com` was added to the console on 29-08-2026** — Primary, 11 seats,
  admin `vatsal@trulyinbox.com`, all 11 mailboxes imported, no secondary domains.
  Its GW contract is stale: id 7 `Truly Inbox - GW (8 Users)` **expired 09-06-2026**
  at Rs.2065/user, and the renewal has never been recorded. Google now shows 11
  licences. Get the DigiSoft renewal invoice and create the current contract.
- **The HR TI tab has wrong domains for two people.** It lists `sneh@saleshandy.com`
  and `dhruvam@saleshandy.com`, but both are really `@trulyinbox.com` and are already
  in the console under the correct addresses. Fix the sheet, not the console.
- **`karan.g` and `jiten` exist in no tenant.** HR lists `karan.g@saleshandy.com` and
  `jiten@saleshandy.com`; the `TrulyInbox GW` sheet lists `karan.g@trulyinbox.com`.
  Neither address is in any Google export — the mailboxes were never created.
- **The users sheet is not write-protected.** Anyone with access can edit `A2:D200`
  and the next sync overwrites them — the drift alert reports it, but does not stop it.
- **Krishnabusiness licences purchased are unverified.** The console says 22 seats
  (matches 22 users and the ₹78,918.4 paid), but invoice `GSTNW/1205/2627` bought
  "1 Additional User", so purchased may be 23 with 1 spare. Needs the Subscriptions
  page for that tenant.
- **Most console figures still come from a stale spreadsheet** seeded by
  `../seed_excel.js`. Only `saleshandy.com` and `krishnabusinesshub.com` have been
  checked against real Google exports.
