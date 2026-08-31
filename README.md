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

| Table | What it holds |
|---|---|
| `companies` | 149 validated ATS boards, with the failure counter that deactivates dead ones |
| `jobs` | Every posting seen. No raw payloads — see below |
| `job_filters` | Pass/fail **and which rule killed it**. The tuning mechanism |
| `job_scores` | Two axes: fit 1–10, and whether the role compounds, 1–5 |
| `applications` | Lifecycle from queued through applied to replied |
| `email_actions` | What the sweep did, per thread — the sweep is auditable |
| `calendar_intents` | Events phase 2 wants; phase 2b creates them |
| `transactions` | Names, dates, amounts, accounts. Never a card number |
| `phase_runs` | The heartbeat every phase writes and phase 3 reads |

### The 228 MB column

Postings were stored with their untouched API payload in a `jsonb` column, on
the theory that keeping source data is always cheaper than re-fetching it. After
one night of real ingest the database was **252 MB of a 500 MB free tier** — and
228 MB of that was the TOAST side-table behind that one column, against 5.9 MB
of actual rows.

Only 59 MB of it was even live. The rest was bloat: the nightly run UPDATEs all
~10,600 rows, and autovacuum cannot reclaim TOAST pages that fast.

The column is gone. Descriptions are stored as text, capped at 4,000 characters,
which is all the scorer ever reads. The database is now 11 MB, and flat instead
of climbing. Re-fetching beats hoarding when the source re-fetches nightly
anyway.

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

---

## Status

| Phase | State |
|---|---|
| Database schema and retention | Live |
| 1a — ingest, 7 sources | Ported, 49 tests green |
| 1b — score and prepare | Not built |
| 2 — email sweep | Not built |
| 2b — calendar drain | Not built |
| 3 — morning report | Not built |

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
```

Phases 2 and 3 are prompts rather than Python: they run as scheduled cloud
sessions with the Gmail, Drive, and Calendar connectors. Those prompts are kept
in version control rather than only inside the scheduler, where a bad edit is
unrecoverable and nothing records what changed.

## License

MIT.
