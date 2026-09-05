# Phase 1 — Extract

> ## ⚠️ DETACHED — 2026-09-04
>
> **Phase 1 no longer runs and is not part of the pipeline.** The code is kept
> here on purpose — it is the most interesting engineering in the repo — but it
> is wired to nothing:
>
> - The seven job tables it reads and writes (`jobs`, `job_filters`,
>   `job_scores`, `companies`, `applications`, `email_events`,
>   `recruiter_submissions`) were **dropped from the database**. See
>   `sql/004_drop_job_tracking.sql`.
> - The Actions schedule is **removed**, so 1a never fires on its own.
> - The 1b cloud routine is **deleted**, so nothing fetches
>   `routine_1b_score.md` any more.
> - Phase 3 no longer renders a jobs card, and phase 2 no longer advances
>   applications.
>
> `pytest -q` still passes — the filter tests are pure functions and touch no
> database. Everything else here needs schema that no longer exists.
>
> **To bring it back:** re-run the table definitions from git history
> (`git show <commit before 004>:sql/001_schema.sql`), restore the Actions
> `schedule:` block, recreate the 1b routine, and re-add the card to phase 3.

Collects what there is to know and writes it to Postgres. Nothing here decides
anything a person would argue with; it fetches, normalizes, and applies rules
that are the same every time.

Two sub-phases, because they need different runtimes.

## 1a — ingest · 5:45am PT · GitHub Actions

The Python in `src/`. Fetches seven ATS APIs, normalizes, dedupes across
sources, upserts, applies the hard filters, and prunes what went stale.

It lives on Actions because it needs raw outbound network, which a scheduled
Claude session does not have. Entry point is `tracking-engine-ingest`, wired in
`.github/workflows/ingest.yml`.

```bash
tracking-engine-ingest --dry-run   # sources only, no database writes
pytest -q                          # 49 tests
```

The workflow's cron is a backstop, not the primary trigger — Actions has fired
it up to 9.5 hours late. Phase 1b dispatches it directly and waits.

## 1b — score and prepare · 6:30am PT · cloud routine

Not built yet. Will live here as `routine_1b_score.md`.

Ranks what survived 1a on two axes (fit 1–10, compounding 1–5), writes a cover
letter per queued job to Drive, and creates the `applications` row. Needs
judgment and a language model, so it is a prompt rather than code.

## What's shared, and why it isn't in here

`config/` and `sql/` sit at the repo root because phases 2 and 3 read them too.
Everything else in this folder is phase 1's alone — the point of the split is
that you can rewrite one phase without reading the others.

## Files

| Path | What |
|---|---|
| `src/tracking_engine/sources/` | One module per ATS. A 404 is not an error |
| `src/tracking_engine/normalize.py` | Location parsing, region classification, description cap |
| `src/tracking_engine/filters.py` | Hard kills, recruiter conflict. Pure functions, heavily tested |
| `src/tracking_engine/db.py` | Batched upserts, `phase_runs` telemetry |
| `src/tracking_engine/retention.py` | Nightly prune, reports database size |
| `src/tracking_engine/find_slug.py` | Validates an ATS slug against the board's own name |
| `tests/` | 49 tests, mostly filter edge cases |

## Two things not to undo

**`UPSERT_BATCH = 100`.** At 500 the nightly run hit a Postgres statement
timeout (57014) once it became mostly UPDATEs instead of INSERTs.

**Slug validation checks the board's self-reported name.** A first-word fallback
once resolved `blue` to BlueCloud Services while looking for Blue Shield of
California and returned 10 live postings from the wrong company — worse than an
empty board, because nothing downstream notices.
