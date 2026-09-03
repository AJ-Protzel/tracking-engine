# tracking-engine

A personal data pipeline that runs on hosted infrastructure with no machine of
mine involved. It collects job postings from public ATS APIs, sweeps and
organizes an email account, records what it did, and renders one report each
morning — ready before I wake up.

It replaces two earlier systems that worked separately and never joined up, plus
three status emails that arrived in the inbox the pipeline itself was trying to
clean.

---

## The problem it solves

Two problems, and they turned out to be the same problem.

**Aim, not effort.** Roughly **3% of "data engineer" postings are entry-level**
(219 of 6,877 sampled, May 2026). "Analytics engineer" is closer to **8%** —
nearly triple, for a substantially overlapping skill set. Applying harder to the
first title does not fix that. So the ranking layer scores against a defined
profile rather than a job title, and the filter layer records *why* it rejected
every posting it rejected. After a week the kill-rule log says which rules are
over-firing, which turns "my filters are probably too strict" into a number.

**Nothing closed the loop.** The old job pipeline prepared applications and the
old mail sweeper labeled the replies, but neither told the other, so the
applications table had exactly one row in it. Here, the phase that reads mail is
the phase that advances the application record.

---

## Architecture

Five phases. Each is a separate scheduled job with its own failure domain.

```
  5:45am  ┌────────────────────────────┐
  ──────► │ 1a  ingest                 │  GitHub Actions — unrestricted egress
          │     7 ATS APIs → normalize │  ────────────────────────────────►
          │     → dedupe → filter      │
          └────────────────────────────┘                    Postgres
  6:30am  ┌────────────────────────────┐                   (Supabase)
  ──────► │ 1b  score & prepare        │                     ▲     │
          │     rank → cover letters   │  ───────────────────┘     │
          └────────────────────────────┘                           │
  7:15am  ┌────────────────────────────┐                           │
  ──────► │ 2   email sweep            │  ─────────────────────────┤
          │     label, draft, record   │                           │
          └────────────────────────────┘                           │
  7:45am  ┌────────────────────────────┐                           │
  ──────► │ 2b  calendar drain         │  ─────────────────────────┤
          └────────────────────────────┘                           │
  8:00am  ┌────────────────────────────┐                           │
  ──────► │ 3   build the report       │  ◄────────────────────────┘
          └────────────────────────────┘
                        │
                        ▼
              one page, on a phone, by 8:30
```

**Why the runtimes are split.** Ingest needs raw outbound network to hit seven
different APIs, which is what Actions is good at and free for on public repos.
The rest need judgment and reach Postgres, Gmail, Drive, and Calendar over
tooling rather than raw sockets.

**Why the phases are split.** They chain only through the database — no phase
calls another. Every phase writes a `phase_runs` row on every exit path,
including a crash. Phase 3 reads the newest row per phase, so a paused or broken
phase renders as *"nothing changed, last ran 07:15"* rather than an error or a
blank page. Any phase can be paused, rewritten, or left half-built without
taking the morning report down with it — which matters, because phase 3 gets
edited constantly and phase 2b stays inert until some manual setup happens.

---

## What lives in the database

The job pipeline:

| Table | What it holds |
|---|---|
| `companies` | 149 validated ATS boards, with the failure counter that deactivates dead ones |
| `jobs` | Every posting seen. No raw payloads — see below |
| `job_filters` | Pass/fail **and which rule killed it**. The tuning mechanism |
| `job_scores` | Two axes: fit 1–10, and whether the role compounds, 1–5 |
| `applications` | Lifecycle from queued through applied to replied |
| `email_events` | Replies matched back to an application, and how they were classified |
| `recruiter_submissions` | Employers an agency already owns, so the filter can avoid a conflict |

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

## Design decisions worth defending

**It never submits an application.** It goes as far as a cover letter, a scored
ranking, and a direct apply link. A human clicks submit. That is a product
decision, not a missing feature — and nothing running in the cloud can drive an
ATS form honestly anyway.

**Nothing labeled gets auto-deleted.** An earlier version trashed flagged
threads after a week. Deleting a person's unanswered mail on a timer is the kind
of automation that is only correct until the one time it isn't.

**Two axes, not one.** A job needs `fit >= 8` **and** `compounding >= 3` to
queue. Compounding asks whether a year in the seat puts a nameable tool on a
resume. A high-fit job that fails it is *named in the report* rather than
silently dropped — those are the tempting ones.

**The kill-rule column is not cleanup debt.** Every rejection records which rule
rejected it. Dropping rejected rows to save space would delete the only evidence
of whether the filters are calibrated.

**Personal data never enters this repo.** `config/profile.yaml` holds filters,
thresholds, and geography and is public. `config/identity.yaml` holds a real
address and phone number and is gitignored, with an example file committed in
its place.

**A view is a hole in RLS unless you say otherwise.** Every table has RLS on with
no policies, which denies everything and is the intended state — only the service
key reaches this data. But a Postgres view runs as its *owner* by default, and
the owner here is `postgres`, which has `BYPASSRLS`. Two views were created
without `security_invoker`, so anyone with the public anon key could read the
queue — company, title, salary, apply link, and the private `verdict` and
`concerns` scoring fields — straight through a door the base tables had shut.
Fixed 2026-09-03; `security_invoker = true` is now set on every view in
`sql/001_schema.sql`, and any view added later needs it too.

---

## Status

All five phases are live and have been running unattended since 2026-09-01.

| Phase | State | Last verified run |
|---|---|---|
| Database schema and retention | Live | — |
| 1a — ingest, 7 sources | Live, 49 tests green | 10,263 fetched → 10,074 upserted → 700 passed |
| 1b — score and prepare | Live | 40 scored, backlog 4 |
| 2 — email sweep | Live | 11 scanned, 6 labeled, 1 transaction |
| 2b — calendar drain | Live | no pending intents |
| 3 — morning report | Live | report published, 2 items needing a human |

Source coverage is honest about itself: Greenhouse, Lever, Ashby, Remotive, and
RemoteOK are verified against live boards. Workable's response shape is
confirmed but no populated board turned up in sampling. Recruitee is unverified.

---

## Running it

```bash
pip install -e ".[dev]"
pytest -q && ruff check .

# Sources only, no database writes:
tracking-engine-ingest --dry-run
```

A real run needs `SUPABASE_URL` and `SUPABASE_SERVICE_KEY`. In CI they are repo
secrets, and the ingest job is gated to `schedule` and `workflow_dispatch` so a
push never writes to the database or needs them.

## Layout

One folder per phase, so a phase can be debugged, upgraded, or rewritten without
reading the others. Each has a README explaining what it does and what must not
be undone.

```
phase1/   extract  — ingest (Python, Actions) + the scoring routine
phase2/   email    — inbox sweep + calendar drain
phase3/   present  — the morning report
config/   shared   — filters and thresholds (public), identity (gitignored)
sql/      shared   — schema, the one-time migration, retention
skills/   shared   — conversational skills over the non-pipeline tables
```

Phases 1b, 2, 2b and 3 are prompts rather than Python: they run as scheduled
cloud sessions with the Gmail, Drive, and Calendar connectors.

**The routines fetch these prompts from this repo at run time.** Each scheduled
routine is about ten lines — fetch the raw GitHub URL for its prompt file, follow
everything after the first `---`, and on a second failed fetch write a failed
`phase_runs` row and stop rather than improvise. So **editing a prompt file here
changes live behavior on the next run**, with no scheduler edit. Do not paste a
prompt body into the scheduler: that creates a second copy, and the two drift
without anything saying so.

| Phase | Prompt |
|---|---|
| 1b | `phase1/routine_1b_score.md` |
| 2 | `phase2/routine_2_email.md` |
| 2b | `phase2/routine_2b_calendar.md` |
| 3 | `phase3/routine_3_artifact.md` + `phase3/template.html` |

**Every cron in this system is fixed UTC** — the four routines and the Actions
workflow. All five need a manual one-hour bump when Pacific goes back to standard
time in November. Written down rather than pretended away.

## License

MIT.
