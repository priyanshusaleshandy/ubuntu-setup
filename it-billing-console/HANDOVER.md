# IT Console — session handover

State as of **04-09-2026**. Written so a fresh session can pick this up without
re-discovering any of it.

Deep detail lives in [`n8n/README.md`](n8n/README.md) — this file is the map and the
things that will bite you.

---

## What runs where

| Piece | Address | Notes |
|---|---|---|
| IT console | `192.168.126.101:3000` | Node/Express + SQLite, container `it-billing-console` |
| n8n | `192.168.126.101:5678` | v2.36.9, **15 workflows, all active**. Public: `https://n8n.saleshandy.dev` |
| Invoice parser | `192.168.126.101:4321` | native launchd service, `~/invoice-parser/server.js` |
| ntfy | `192.168.126.101:8080` | topic `it-billing-console` — **the only alert channel that works**. Public: `https://billing.saleshandy.dev` (that host serves **ntfy**, not the console) |

SSH alias `IKI-MAC-27` → `192.168.126.101`, user `admin`.
`docker` is **not on PATH over SSH** — use `/usr/local/bin/docker`.

---

## What changed 02-09 → 04-09-2026

Read this first if you last saw this stack on 01-09. Full narrative lives in Obsidian
`Projects/Mac Mini 101 - Docker Wipe Incident & Backup Automation.md` and the `n8n/` folder.

**n8n came back from a total wipe.** The 01-09 Docker factory-reset destroyed `n8n_data`.
All 15 workflows are active again and the two Google credentials were re-seeded **with their
original ids** (`b1dYZNasS1uLkc9D` Sheets, `vtDw4Vtd1koXODAF` Gmail) — a UI-created credential
gets a random id and would have broken all 25 nodes referencing them.

**The encryption key no longer lives only inside the volume.** It is pinned into `~/n8n/.env`
and referenced from the compose environment, so the credentials export in the NAS backup is
independently restorable. `~/pin-n8n-encryption-key.sh` reuses the current key; it must never
generate a new one.

**Three backup jobs exist now** — `sysBackupNas1` (daily 18:00), `n8nBundle4h` (4-hourly
self-sufficient n8n restore bundle), `vmImageBkFri1` (Sun 06:00, moved off Friday evening).

**Omada's database had never actually been backed up.** The nightly `WARN omada tar failed` was
real: `data/db/*` is `root:root 0600`, tar ran unprivileged and skipped the whole MongoDB dataset
while still shipping a plausible 77 MB archive with an empty `data/db/`. Fixed with a scoped
sudoers rule + a contents assertion (`COVERAGE-OMADA db-files=`). **0 → 1089 files.**
The lesson generalises: the coverage counters counted *archives produced*, not what was inside
them.

**Scanned invoices are captured now.** Amity Infosoft's 04-09 bill was a scanned PDF with no text
layer, so `Extract PDF Text` returned `''` and `/parse-invoice` rejected it with
`400 missing text field` — the mail was picked up and then discarded. The parser accepts
`pdfBase64` and renders it with macOS `sips`; the workflow sends the PDF **only** when the text
layer is empty. Text stays preferred.

**The console shows one folder button per row**, not one chip per file. `attachmentChips` became
`attachmentFolderButton` + a `docs-modal` listing each document with thumbnail, name, date and a
delete control. Uploading is unchanged — still the row's Edit modal.

**ntfy is reachable from a phone.** `base-url` was a LAN address (so every link in a notification
was dead off-LAN); it is now `https://billing.saleshandy.dev`, and `upstream-base-url:
https://ntfy.sh` was added so the iOS app can be woken via APNs. Publishers were not touched —
they post to the LAN URL and `base-url` only affects generated links.

> **ntfy is wide open to the internet.** No `auth-file`, no `auth-default-access`. Verified
> 04-09: an anonymous publish from the public internet returned **200**. Anyone who knows or
> guesses a topic name can read every alert and publish fake ones. Left open deliberately to get
> the phone working first — closing it means auth + a token **and updating every publisher**
> (all n8n ntfy nodes, the `omada-ntfy` watcher on `.180`, any script).

---

## Read this before deploying anything

> **The console deploys by rebuilding the image, not `docker cp`.**
> Every change used to be copied into the *running* container and never into the image.
> A routine `docker compose up -d` on 01-09-2026 recreated the container from the old
> image and **wiped every change** — the rentals tables, the RAC tab, `paid_amount`.
> `data.sqlite` is a bind mount so no data was lost, but the app served pre-RAC code
> until it was restored.
>
> ```bash
> scp <changed files> IKI-MAC-27:/Users/admin/it-billing-console/...
> ssh IKI-MAC-27
> export PATH=/Applications/Docker.app/Contents/Resources/bin:/usr/local/bin:$PATH
> cd ~/it-billing-console && docker compose up -d --build
> ```
>
> That `PATH` line is required: without it the build fails with
> `error getting credentials - docker-credential-desktop: not found`.

> **n8n `import:workflow` deactivates the workflow it overwrites**, and DB changes do not
> take effect while n8n is running. Always follow with
> `n8n publish:workflow --id=<ID>` then `docker restart n8n`, and
> **verify the import actually landed** — one silently did not during this session and
> the old code kept running.
>
> `update:workflow --active=true` is **deprecated** on 2.36.9: it prints
> `Please use: publish:workflow --id=…` and **still exits 0**, so it looks like it worked
> while the workflow stays inactive. Confirm with `list:workflow --active=true`.

---

## Traps that have already cost real time

**Gmail returns `from` / `to` / `cc` as objects**, not strings —
`{ value:[{address,name}], html, text }`. `String(...)` gives `"[object Object]"`, so any
`.includes('@domain')` test is silently false and the workflow processes nothing while
reporting success. This had killed **both** RAC workflows outright. Always normalise
through the `addr()` helper. `subject`, `text` and `html` *are* strings.

**A fixture that does not mirror the real payload is worse than no fixture.** The manual
fixtures passed strings for `from`, so every test was green while production could not
have worked. Fixtures now emit the object shape.

**Never derive "today" from UTC.** n8n's timezone is Asia/Kolkata and schedules fire on
local time, but `new Date()` / `getUTCDate()` inside a Code node ignore that. 00:00 IST
is 18:30 UTC *the previous day* — which made the exit sync remove **every** leaver a day
late. Use:
```js
const istNow = new Date(Date.now() + 5.5 * 3600000);
const today = new Date(Date.UTC(istNow.getUTCFullYear(), istNow.getUTCMonth(), istNow.getUTCDate(), 12, 0, 0));
```
The console container now sets `TZ=Asia/Kolkata` (needs `apk add tzdata` — alpine ships
no timezone database, so a bare `TZ` does nothing).

**Never hardcode a sheet tab name that carries a count.** HR rename them as the count
moves (`G Suite Main 89` → `G Suite Main 111`), which killed the master-sheet sync for
days. Resolve the title from the numeric `sheetId`, which survives a rename.

**`PUT` is a full-record replace everywhere in this API.** Echo every field back or it is
written as NULL.

**HTTP header values must be ASCII.** An emoji in an ntfy `Title` makes node's `fetch`
throw outright.

**Pasting a multi-line script into an n8n UI field strips every newline.** Hit on
02-09-2026 editing `sysBackupNas1`. The paste *saved* — the new content was all there —
but the 5007-char script came back as **one line, zero newlines**, which breaks it
completely: the first `#` comment swallows the rest and a `<<'HEREDOC'` cannot work.
Nothing complains until the job runs. **Edit multi-line SSH/Code nodes through the CLI**,
then verify the stored `command`/`jsCode` still contains newlines. Any node body over
200 chars with zero newlines is broken.

**`du -h` right-pads on macOS.** `" 12M"` with a leading space — a `BUNDLE_SIZE=(\S+)`
style regex silently yields nothing once a value reaches two digits.

---

## The 15 workflows

| ID | Name | Trigger |
|---|---|---|
| `Ncx7r0VcoxUfO6hF` | Weekly IT Spend Summary | Mon 09:00 |
| `t4Pui7NwhNkRoabs` | Gmail Invoice Auto-Capture | Gmail |
| `qZ3Gn6zzCACqfweL` | Auto-Delete Basecamp Notification Emails | Gmail |
| `newJoinersAuto` | New Joiners Auto Add (SH / HA / TI) | 30 min |
| `shSheetSync001` | Saleshandy User List → G Suite Sheet | 30 min |
| `krishnaSheetSync` | Krishnabusiness → G Suite Krishna | 30 min |
| `tiSheetSync001` | TrulyInbox → TrulyInbox GW | 30 min |
| `solSheetSync01` | Saleshandy Solutions ↔ SaleshandySolutions | 30 min |
| `exitSync00001` | Exit Sync — Remove Leavers | 30 min |
| `racBillCapture` | RAC Laptop Bill Auto-Capture | Gmail |
| `racProofCapture` | RAC Payment Proof Auto-Capture | Gmail (SENT) |
| `syncFailAlert01` | **Sync Failure Alert** | error trigger |
| `sysBackupNas1` | System Backup to NAS | daily 18:00 |
| `n8nBundle4h` | n8n Restore Bundle (self-sufficient) | every 4 h |
| `vmImageBkFri1` | UTM VM Image Backup | **Sun 06:00** |

`syncFailAlert01` is every other workflow's `settings.errorWorkflow`. Before it existed,
`shSheetSync001` failed 46 times over two days and nobody knew — the console kept working
and the only symptom was a sheet that had quietly gone stale. All 20 `googleapis.com`
nodes also carry `retryOnFail / maxTries 3`, which absorbs Google's frequent 503s.
**Retry first, alert second** — without the retry the alert fires on every blip and gets
tuned out.

---

## RAC laptops — the newest piece

RAC IT Solutions Pvt Ltd, domain **`racwg.com`**, bill from several mailboxes on it
(`accounts@`, `accountsahmd@`, `receivables3@`, `hobilling@`, `salesahmd4@`,
`billing@`). Payment advices go to **`accountsahmd@racwg.com`**.

Two workflows close the loop:

```
RAC mails a bill   → racBillCapture  → payment row (status Pending) + PDF on the NAS + ntfy
we mail the proof  → racProofCapture → marks it Paid + screenshot on the NAS + ntfy
```

Both land on the same console row under **RAC Laptops**.

| Field | Meaning |
|---|---|
| `amount` | what was invoiced |
| `paid_amount` | what actually left the bank — **lower**, RAC deduct 2% TDS u/s 194I |
| `payment_date` | the bill's own date |
| `paid_on` | when the money went out |
| `due_date` | off the PDF; overdue unpaid rows go red |

Current state: 2 Lenovo V14 G3 laptops (`RAC-02370004` / SN `PF4WGJAW`,
`RAC-02384381` / SN `PF52JT2R`), ₹1,600/month each, on rent since 18-08-2026.
Invoice `AMD/26-27/00669` — ₹3,776 billed, **₹3,712 paid** on 24-08-2026 by IMPS
(₹64 = the TDS). Bills are raised on **IKIGAI INFOTECH LLP**, not Saleshandy.
Their cycle runs **18th → 17th**, not calendar months.

Who holds which laptop is tracked in **Keka** — the "Assigned To" column was
deliberately removed from this UI.

---

## The parser (`:4321`)

Not in this repo — `~/invoice-parser/server.js` on the Mac Mini, run by launchd
(`com.invoiceparser`). Shells out to a coding agent and returns JSON.

| Endpoint | For |
|---|---|
| `POST /parse-invoice` | vendor invoices → service contracts. Takes `text`, **or `pdfBase64` / `imageBase64` for a scanned invoice** |
| `POST /parse-rental-bill` | RAC bills → `invoices[]` + `laptops[]` |
| `POST /parse-payment-proof` | bank screenshots → amount / date / refs |
| `GET /health` | `{ok, engine, codexInstalled, codexAuthed}` |

**Two engines.** Codex (`~/.codex/packages/standalone/current/codex exec`, logged in with
a ChatGPT account) is preferred; claude (`claude -p`) is the fallback. They are separate
quotas, which is the whole point — sharing one with Hermes meant a busy Telegram day took
invoice capture down. On a quota/auth failure codex automatically retries on claude, and
the reply records `_engine` / `_fellBackFrom`.

> Both engines **do** run out. Seen on 31-08: claude's session limit at midday, codex's
> usage limit the same evening. The fallback covers one being down, not both.

> Log in codex over SSH with `codex login --device-auth` — plain `codex login` wants a
> browser on the same machine.

---

## Where things are written down

- **`n8n/README.md`** — the deep reference: every workflow, sheet layouts, API contracts,
  credentials map, deploy steps, gotchas.
- **`n8n/workflows.json`** — export of all 12 live workflows. A **mirror, not the
  source**; re-export before trusting it. Verified to contain credential *references*
  only, never secrets.
- **Obsidian** → `Projects/IT Billing Console - Invoice Automation.md` — narrative
  history, incidents, decisions and the reasoning behind them.
- **Obsidian** → **`n8n/`** (added 03-09-2026) — the standing n8n documentation:
  `n8n Hub`, `n8n - Workflow Inventory`, `n8n - Credentials & OAuth`,
  `n8n - Backup & Restore`, `n8n - Operations & Gotchas`. **Update these when n8n
  changes**, not the incident note.
- **Obsidian** → `Projects/Mac Mini 101 - Docker Wipe Incident & Backup Automation.md` —
  the 01-09 wipe and everything built out of it.

---

## Open items

| Item | Detail |
|---|---|
| Console email alerts | Gmail rejects the stored password (12 chars; needs a 16-char **App Password**). Channel disabled; alerts go to ntfy instead. Re-enable from Alert Settings once a real App Password exists. |
| O365 costs | Service id 4 holds a seeded ₹44,781 that matches neither the 7- nor the 34-user product; id 5 is 0. Needs the Redington invoices. |
| TrulyInbox contract | id 7 expired 09-06-2026 covering 8 users; Google shows 11 licences. Needs the DigiSoft renewal invoice. |
| ₹127 DigiSoft invoice | `GSTNW/1205/2627`, unpaid, due 08-09-2026. **Now visible in the console** as its own service row, *Google Workspace Business Starter - Additional User (Krishnabusiness)*. |
| DigiSoft ₹3140+GST rate | Confirm whether it applies to saleshandy.com (renewal 12-09-2026, ₹13,098 difference). |
| Product Team batches | `Batch-1`…`Batch-5` exist and are empty. 31 domains still to be assigned — the user will dictate the mapping. |
| HR sheet data errors | `sneh@` / `dhruvam@` listed under the wrong domain; `karan.g` / `jiten` exist in no tenant. |
| Unsynced tabs | `G Suite Team 07`, `O365 Truly Inbox 33`, `Zoho 04`, `Billing` have no sync. |
| `trytrulyinbox.com` | Shows "Possible service issues" — DNS check pending. |
| Technofirm contracts | ids 9–15 don't reconcile with the Product Team tab (Batch 1–5 vs 3 batches; 100 O365 vs 60). |
| Seat-note date | `Gmail Invoice Auto-Capture` → `Update Domain Seats` still stamps a UTC date in its note text. Cosmetic; left alone deliberately. |

### Raised 04-09-2026, not yet done

| Item | Detail |
|---|---|
| **Krishnabusiness shows two rows** | Searching `krish` returns *Google Workspace Business Starter - Additional User (Krishnabusiness)* (₹127, one-time, expiry 08-09) **and** *Krishnabusiness - GW (22 Users)* (₹78,918.4, yearly, expiry 09-09), both DigiSoft. The owner flagged this as wrong and expects the captured bill to land against the **main** Krishnabusiness contract rather than creating a second row. **Not investigated yet** — decide first whether a ₹127 additional-user charge is legitimately its own line or should update the parent contract, then fix `Create Vendor + Service in Console` accordingly. The ₹127 row is the `GSTNW/1205/2627` invoice above, so it is real money, not a phantom. |
| **Amity 04-09 bill still not in the console** | The mail that failed on the old scanned-PDF path was discarded. The fix is deployed and verified, but that specific bill needs re-forwarding to the capture mailbox (or re-parsing by hand) — the owner does not want to enter it manually. |
| **Employee → email list** | A device/user list of 19 people (`IKI-LP-22` … `IKI-LP-113`, all `@saleshandy.com`) was to be matched against `/api/mailboxes` (189 rows, 106 on saleshandy.com) with a list of anyone unmatched. **Dropped mid-way at the owner's request** — pick it up only if asked again. |
| **ntfy left unauthenticated** | See the warning above. A deliberate decision on 04-09, not an oversight. |
| **Invoice parser is not in this repo** | `~/invoice-parser/server.js` on the Mac only. It *is* covered by the nightly NAS backup's `native/` section, so it will not be lost — but it has no version history, and it was changed on 04-09. Worth adding. |
