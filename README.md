# tracking-engine

A personal data pipeline that runs on hosted infrastructure with no machine of
mine involved. It sweeps and organizes an email account, turns receipts into a
ledger, drains anything date-shaped onto a calendar, records what it did, and
renders one report each morning — ready before I wake up.

It replaces two earlier systems that worked separately and never joined up, plus
three status emails that arrived in the inbox the pipeline itself was trying to
clean.

It also used to run a job-application pipeline — seven ATS APIs, scored postings,
generated cover letters. That was switched off on 2026-09-04; the code is still
here, detached. See [Job tracking, removed](#job-tracking-removed).

---

## The problem it solves

**Nothing was in one place.** A mail sweeper labeled things, a food tracker
logged meals into a spreadsheet, and a spending picture existed only as a pile of
receipt emails. Each reported separately, by email, into the same inbox the
sweeper was trying to clean. Reading the reports cost more attention than the
systems saved.

Now there is one page. It opens from a phone home screen and answers the only
questions worth asking before coffee: what did I spend, what did I eat, and what
needs me today.

**Filing is only safe if something else surfaces what mattered.** Every labeled
thread leaves the inbox, so the inbox is no longer a place a missed reply would
catch the eye. That makes the morning report load-bearing rather than a
convenience, and the report is written against that rule: a thread filed without
being reported is a thread lost.

---

## Architecture

Three phases. Each is a separate scheduled job with its own failure domain.
(There were two more that ingested and scored job postings; they are detached —
see below.)

```
  7:15am  ┌────────────────────────────┐
  ──────► │ 2   email sweep            │
          │     label, draft, record   │  ──────────────┐
          └────────────────────────────┘                │
  7:45am  ┌────────────────────────────┐                ▼
  ──────► │ 2b  calendar drain         │  ────────►  Postgres
          │     intents → events       │            (Supabase)
          └────────────────────────────┘                │
  8:00am  ┌────────────────────────────┐                │
  ──────► │ 3   build the report       │  ◄─────────────┘
          └────────────────────────────┘
                        │
                        ▼
              one page, on a phone, by 8:30
```

**Why the phases are split.** They chain only through the database — no phase
calls another. Every phase writes a `phase_runs` row on every exit path,
including a crash. Phase 3 reads the newest row per phase, so a paused or broken
phase renders as *"nothing changed, last ran 07:15"* rather than an error or a
blank page. Any phase can be paused, rewritten, or left half-built without
taking the morning report down with it — which matters, because phase 3 gets
edited constantly. Removing phases 1a and 1b wholesale was a live test of that
claim, and the other three needed no changes to keep running.

---

## What lives in the database

Mail, money, and the heartbeat:

| Table | What it holds |
|---|---|
| `email_actions` | What the sweep did, per thread — the sweep is auditable |
| `blocklist` | Repeat junk senders, and the dates that earned them the label |
| `calendar_intents` | Events phase 2 wants; phase 2b creates them |
| `transactions` | Names, dates, amounts, accounts. Never a card number |
| `accounts` | Account names only, for `transactions` to reference |
| `wedding_vendors` | Vendor names behind the wedding-tagged transactions |
| `phase_runs` | The heartbeat every phase writes and phase 3 reads |

Read and written by skills rather than by a phase:

| Table | What it holds |
|---|---|
| `food_log` | One row per meal eaten, already summed if it was a combo |
| `nutrition_items` | Reference macros, one row per ingredient |
| `health_log` | Symptoms, vitals, medications and events |

These three carry no pipeline dependency — no phase reads them. They exist so the
report has something to render and so a conversational skill has somewhere
durable to write. `food_log` and `nutrition_items` came over when the separate
Food-Tracker project was folded into this one; the doctor skill takes ownership
of all three, replacing the earlier food-tracker skill, and an accountant skill
takes `transactions`.

## Design decisions worth defending

**Nothing labeled gets auto-deleted.** An earlier version trashed flagged
threads after a week. Deleting a person's unanswered mail on a timer is the kind
of automation that is only correct until the one time it isn't.

**One writer per destination.** The wedding artifact is updated by phase 2 only,
because that is where the receipt lands first. Phase 3 mentions the payment and
writes nothing. Two writers on one page is how a page ends up with a number
neither of them meant.

**Personal data never enters this repo.** It is public. The wedding vendor list
lives in a database table rather than a config file, because a vendor list is a
map of a private life. Gmail label IDs and calendar IDs are here; addresses,
phone numbers, and vendor names are not. `config/identity.yaml` — a real address
and phone number, used by detached phase 1 — is gitignored, with an example file
committed in its place.

**A view is a hole in RLS unless you say otherwise.** Every table has RLS on with
no policies, which denies everything and is the intended state — only the service
key reaches this data. But a Postgres view runs as its *owner* by default, and
the owner here is `postgres`, which has `BYPASSRLS`. Two views were created
without `security_invoker`, so anyone with the public anon key could read the
queue — company, title, salary, apply link, and the private `verdict` and
`concerns` scoring fields — straight through a door the base tables had shut.
Fixed 2026-09-03. Those particular views are gone with job tracking, but the rule
stands: `security_invoker = true` on every view in `sql/001_schema.sql`, and any
view added later needs it too.

---

## Status

The three live phases have been running unattended since 2026-09-01.

| Phase | State | Last verified run |
|---|---|---|
| Database schema and retention | Live | — |
| 2 — email sweep | Live | 11 scanned, 6 labeled, 1 transaction |
| 2b — calendar drain | Live | no pending intents |
| 3 — morning report | Live | report published, 2 items needing a human |
| 1a — ingest, 7 sources | **Detached** 2026-09-04 | 52 tests still green |
| 1b — score and prepare | **Detached** 2026-09-04 | routine disabled |

---

## Running it

The three live phases are prompts on a scheduler — there is nothing to install
and nothing to start. The only runnable code is detached phase 1:

```bash
pip install -e ".[dev]"
pytest -q && ruff check .
```

Those 52 tests are pure functions over fixture data and still pass. Everything
past them needs tables that no longer exist, and the ingest job in CI is gated
`if: false` so nothing can run it by accident.

## Layout

One folder per phase, so a phase can be debugged, upgraded, or rewritten without
reading the others. Each has a README explaining what it does and what must not
be undone.

```
phase1/   extract  — DETACHED. Job ingest (Python) + the scoring prompt
phase2/   email    — inbox sweep + calendar drain
phase3/   present  — the morning report
config/   shared   — filters and thresholds for detached phase 1
sql/      shared   — schema, history, and the removal of job tracking
skills/   shared   — conversational skills over the non-pipeline tables
```

Phases 2, 2b and 3 are prompts rather than Python: they run as scheduled cloud
sessions with the Gmail, Drive, and Calendar connectors.

**The routines fetch these prompts from this repo at run time.** Each scheduled
routine is about ten lines — fetch the raw GitHub URL for its prompt file, follow
everything after the first `---`, and on a second failed fetch write a failed
`phase_runs` row and stop rather than improvise. So **editing a prompt file here
changes live behavior on the next run**, with no scheduler edit. Do not paste a
prompt body into the scheduler: that creates a second copy, and the two drift
without anything saying so.

| Phase | Prompt |
|---|---|
| 2 | `phase2/routine_2_email.md` |
| 2b | `phase2/routine_2b_calendar.md` |
| 3 | `phase3/routine_3_artifact.md` + `phase3/template.html` |

**Every cron in this system is fixed UTC** — all three routines. They need a
manual one-hour bump when Pacific goes back to standard time in November.
Written down rather than pretended away.

---

## Job tracking, removed

Until 2026-09-04 this was also a job-application pipeline: seven ATS APIs polled
nightly, ~10,000 postings normalized and deduped, hard filters that recorded
*which rule* killed each rejection, an LLM scoring pass on two axes, generated
cover letters, and five roles surfaced on the morning report with apply links.
It ran unattended for four days.

It is switched off. The seven tables — `jobs`, `job_filters`, `job_scores`,
`companies`, `applications`, `email_events`, `recruiter_submissions` — and their
three views were exported to CSV and dropped (`sql/004_drop_job_tracking.sql`).
The database went 61 MB → 11 MB.

**The code is still here, detached.** `phase1/` keeps the ingest package, its
seven source adapters, the filter rules, and the scoring prompt — running on no
schedule, wired to nothing, reading tables that do not exist. Deleting it would
have cost the most substantial engineering in the repo to save nothing; a banner
at the top of `phase1/README.md` says plainly that it is inert and what to
restore to revive it. The `Jobs` email label survives as an ordinary label.

What is worth keeping from it is the storage lesson, which took two rounds to
learn.

### The 228 MB column

Postings were stored with their untouched API payload in a `jsonb` column, on
the theory that keeping source data is always cheaper than re-fetching it. After
one night of real ingest the database was **252 MB of a 500 MB free tier** — and
228 MB of that was the TOAST side-table behind that one column, against 5.9 MB
of actual rows.

Only 59 MB of it was even live. The rest was bloat: the nightly run UPDATEs all
~10,600 rows, and autovacuum cannot reclaim TOAST pages that fast.

The column is gone. Descriptions are stored as text, capped at 4,000 characters,
which is all the scorer ever reads. Re-fetching beats hoarding when the source
re-fetches nightly anyway.

### The same problem, smaller, in the column that replaced it

Dropping `raw` fixed the size but not the mechanism. Measured 2026-09-03, with a
full night loaded: the database was back to **78 MB, of which 54 MB was TOAST
behind the `description` column** — against 25 MB of live description text. The
nightly run UPDATEs every one of ~10,600 rows, and autovacuum does not reclaim
TOAST pages at that rate. Roughly 29 MB was dead.

Two things follow, and the second is the one that surprised me:

- `vacuum (full, analyze) jobs` rewrites the table and hands the pages back:
  **78 MB → 48 MB**. That is the lever when size climbs, not retention.
- **Retention was never going to catch this.** Both age tests in
  `prune_old_data()` key on `last_seen_at`, which the ingest refreshes for every
  posting still listed. A job that stays open never ages out. On the day this was
  measured the function had *zero* rows to act on. It reclaims postings that fall
  off their board; it does not bound steady-state size, and reading the size
  graph as if it did would send you looking in the wrong place.

---

## License

MIT.
