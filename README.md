# tracking-engine

A personal tracking system for one person.

It watches two things that arrive on their own — bank transactions and email —
and shows what it finds on a single private web page: where the money went, what
was eaten, and what still needs a human. Everything else is added by talking to
a skill in a chat, not by anything running on a timer.

```
12:30am PT   simplefin-sweep    loads the night's transactions   (Supabase, free)
 1:00am PT   email-sweep        sorts and files the inbox        (one Claude run)
```

Two scheduled jobs. That is the whole of the automation.

## The rule everything follows

> **Schedule only what arrives whether or not you ask.**

Transactions arrive from the bank. Mail arrives in the inbox. Neither waits for
a request, so both need something watching.

Food, health entries, merchant names, tutoring — those only ever happen because
Adrien starts them, in a chat, with the skill that owns that data. They need no
schedule and no routine. Adding one only creates a second writer for a table
that already has an owner, and nothing to reconcile them when they disagree.

Apply this rule when the system next wants to grow. It is also what retired two
dead pipelines: a job-application scraper, and an xlsx food tracker that synced
itself to Drive every night so a cloud routine could email a chart back.

## Layout

```
sweeps/                 the two things that run on a schedule
  email-sweep.md          the Claude routine's prompt, fetched from GitHub at 1am
  simplefin-sweep.ts      the edge function Supabase runs at 12:30am
  deno.json               its import map
database/               SCHEMA.md — what the database allows — and functions.sql
artifact-template.html  a backup copy of the published page
```

Nine files, one README. `sweeps/` groups by what those two jobs *do* rather
than by what they are written in: one is TypeScript deployed to Supabase, the
other a markdown prompt, and they belong together because they are the only two
things here that run unasked.

**`sweeps/email-sweep.md` must keep that exact path.** The scheduler fetches it
by raw GitHub URL at run time, so moving or renaming it breaks the 1am run until
the scheduler entry is edited to match.

`deno.json`'s import map is currently unused — both imports in the `.ts` are
fully-qualified `jsr:` specifiers. It stays because it is deploy config for a
function whose redeploy cannot be tested from a clone.

## Who owns what

| Tables | Written by |
|---|---|
| `engine_*` | the email sweep |
| `accountant_*` | the SimpleFIN function; the `accountant` skill on demand; the page, when a charge is renamed |
| `doctor_*` | the `doctor` skill, when Adrien logs something in a chat |

A table's prefix names its owner, which is why a skill can be told "you own
every table named `doctor_*`" instead of being handed a list that goes stale.

One owner per table, with one deliberate exception: the merchant maps are
written by both the `accountant` skill and the page. They write the same two
tables the same way and an upsert is idempotent, so a collision costs nothing.

**Before writing anything, read `database/SCHEMA.md`.** It lists every
constrained column and its legal values, plus four rules the columns imply but
cannot enforce. Two bugs in one day came from an allowed-value list living in
the database and a second copy of it living in someone's head.

## The skills

Adrien talks to these; none of them is scheduled. **They live on claude.ai, not
in this repo, and that is deliberate** — nothing here reads them, so a copy
checked in would be a second definition with nothing reconciling it against the
live one. What matters here is the boundary, not the implementation.

| Skill | Owns |
|---|---|
| `secretary` | email and calendar — including the judgment the 1am sweep uses |
| `accountant` | transactions, merchant names and categories |
| `doctor` | food, nutrition and health entries |
| `tutor` | data-engineering practice. Nothing on the page |

## The email sweep

`sweeps/email-sweep.md` is the prompt. The cloud routine **Tracking Engine
Sweep** fetches it at run time and follows everything after the first `---`, so
editing that file and pushing changes live behaviour on the next run. There is
nothing to paste into the scheduler — and pasting a prompt body there creates a
second copy that drifts with nothing to say so.

| | |
|---|---|
| Runs | 1:00am PT — cron `0 8 * * *` UTC |
| Connectors | Supabase, Gmail, Google Calendar |
| Writes | `engine_email_actions`, `engine_blocklist`, `engine_calendar_intents`, `engine_phase_runs` |

It does the email work *by calling the `secretary` skill*, rather than restating
its rules. That way a sweep at 1am and a request at 2pm cannot drift apart: the
skill holds the judgment, the prompt holds only what unattended running needs —
a run row, caps, retry limits, and the values the database will accept.

Threads that name a date **and** a time become calendar events immediately. A
date with no time becomes a `skipped` row in `engine_calendar_intents`, which is
that table's only remaining job: it is what the page's Requires Action card
reads to say something needs adding by hand. A guessed time is worse than no
entry.

### Why there is only one routine

This was three until 2026-09-08: an email sweep at 7:15am, a calendar drain at
7:45am, and a page build at 8:00am, each paying for its own session boot,
connector setup and run row.

The calendar drain existed because it was a separate session, and a calendar
failure should not take the inbox pass down with it — inside one session that is
a `try`/`catch`, not a table and a second routine. The page build existed
because a model had to render the page. It no longer does.

### Why 1am

It puts the run at the far end of the usage window rather than thirty minutes
before Adrien reads. The tradeoff is real and chosen: the sweep covers
yesterday's mail, and anything arriving between 1am and morning waits a day.

The page does not care. It queries live, so it shows the current state of the
database no matter when the sweep last ran.

## The page

**https://claude.ai/code/artifact/fb3d377a-c279-4b59-b182-2b90616d084d** —
private, read on a phone from the home screen. It carries transactions, food
entries and email subjects. Never share it, and never publish it to a second URL.

Five cards: **Money** (a month navigator, three figures, spend by category, and
the day-grouped ledger behind a disclosure), **Over Time** (the whole history as
one line, read three ways), **Card Credits** (static, ticked by hand),
**Nutrition** (7 days, both people), and **Requires Action** (drafts waiting,
mail flagged for review, calendar items missing a time, and the sweep itself
when it failed or has not run).

It queries Supabase directly, through Adrien's own connector, every time it is
opened. Nothing renders it and nothing republishes it on a schedule.

Until 2026-09-08 a routine rebuilt it every morning: read a 68 KB template and
~2,000 transactions into a model, then write the entire page back out. It cost
tens of thousands of output tokens a day, it was only ever as fresh as the last
run, and every design change made on the page had to be backported here or the
next morning would flatten it. One change removed all three problems.

**So: never publish this artifact from a routine.** A routine that republished
it would overwrite Adrien's edits and bring back the cost.

### How it reads

Declared capabilities: `mcp` (the `Supabase` connector, `execute_sql` only) and
`db` (the artifact's own store). Four calls, one per card, so a failure is
contained to the card it feeds.

| Card | Reads |
|---|---|
| Money, Over Time | `accountant_transactions`, every row |
| the `Synced` line | `max(ran_at)` from `accountant_phase_runs` |
| Nutrition | `doctor_food_log`, 7 days, both people |
| Requires Action | `engine_email_actions`, `engine_calendar_intents`, `engine_phase_runs` |

Two things learned the hard way, both worth keeping:

- **Rows are read from `payload` first, then `structuredContent`, then each
  content block's text** — never by walking the result for the first array of
  objects. `res.content` is an array of `{type, text}` envelope blocks, so a
  blind walk finds the wrapper and every card silently renders it as data.
- **Each query names a column only it returns**, checked before the rows are
  used. Four `watchTool` registrations on one tool delivered each other's
  results, and the Money card drew the sync query's single row.

Every connector error code gets its own message naming the one action that fixes
it — reconnect, add the connector, choose one. A catch-all banner hides exactly
the thing that would repair the page, so do not collapse them. An empty result
is a legitimate answer and is rendered as such, never as a failure.

Anything the data can determine is derived from the data. The masthead date and
`complete_from` — the first month whose figures can be trusted — are both
computed in the page, because `complete_from` was once a literal that went stale
the moment a CSV import filled a gap, and the page spent weeks calling three
years of complete history partial.

### Edits write straight to Postgres

Tapping a charge opens a rename-and-categorize panel. On save the page writes to
the database, re-reads, and only then drops its local copy — in that order,
because marking the edit applied removes it from the overlay drawn over the rows,
and doing that before the re-read makes a saved rename flick back to the old
name. A write that fails stays queued and is retried on the next load, so the
page drains its own queue and no routine has to.

`execute_sql` offers no parameter binding, so every value is escaped in the page
and the category checked against the nine the table allows; a transaction id must
be digits. Anything failing a check is not written.

The artifact's own store holds four collections, all written by the page:
`credits` (which credits are ticked), `actions` (dismissed items), `txn_edits`
(the retry queue), and `diag` (what a card received when it could not read a
reply — written only on failure).

### artifact-template.html

A copy of what is published, kept as a backup and as something to read. It is
**not** a build input; nothing renders from it. If the two disagree the published
page wins — copy it back over this file, never the other way around.

The ~30 transactions embedded in it are the offline fallback, the current month
only. They are never the page's data and refreshing them is never required.

Publish updates with the Artifact tool, passing the URL above so it updates in
place, and pass no `favicon` and no `title` — a redeploy keeps them. Pass
`capabilities` **only** to change them, and restate the whole set when you do: a
non-empty declaration revokes anything left out, which would take the card ticks,
the dismissals and the live data down together.

## The transaction feed

`sweeps/simplefin-sweep.ts` is a Supabase edge function, deployed as
**`accountant-simplefin-sweep`** and fired by `pg_cron`. It is the cheapest thing
here — no model, no tokens — and the model everything else aspires to.

Needs `SIMPLEFIN_ACCESS_URL` in the project's Edge Function secrets;
`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected. `verify_jwt` is on.

```
POST /functions/v1/accountant-simplefin-sweep?mode=<mode>
```

- **`sweep`** — the daily job, one request. The window comes from the *oldest*
  per-account watermark minus a 5-day pad, clamped to 14–90 days, so a bank that
  posts late or a connection that was down for a week is still caught up.
  Afterwards it flags any active account quiet longer than its own
  `expected_idle_days`.
- **`backfill`** — manual, resumable. Walks 90-day windows backwards from a
  stored cursor, stopping after two empty ones.
  `?mode=backfill&from=YYYY-MM-DD&windows=8`
- **`dry_run`** — fetches and maps, writes nothing but a run row.

Dedupe is on `external_id`, so overlapping windows are free.

**SimpleFIN reaches back about six months, not the 1–2 years the docs suggest**
(measured 2026-09-06). Anything older has to come from a bank CSV export loaded
through `accountant_ingest` with `source = 'csv'` — which is how the
2025-03 → 2026-03 gap was finally filled on 2026-09-09.

## Both crons are fixed UTC

They need a manual one-hour bump when Pacific returns to standard time in
November. They shift together, so the transaction load stays ahead of the sweep.

## The database

Two files.

`database/SCHEMA.md` is the one to read: every table, every constrained column
with its legal values, and four rules the columns imply but cannot enforce.

`database/functions.sql` holds the three function bodies, generated straight
from the live database with `pg_get_functiondef`. Logic cannot be described in
prose, so it is kept as logic — and generating it beats copying it, because a
copy drifts.

There were eight numbered migrations until 2026-09-09. They are gone. Every one
had already been applied, so none of them did anything; their reasoning has been
lifted into `SCHEMA.md`; and `001`, the file that claimed to reproduce the
system, still created a table dropped four days earlier. A rebuild script that
rebuilds the wrong schema is worse than no rebuild script. Git has all eight if
the history is ever wanted: `git log -- database/`.

## What this used to be

It started as a job-application pipeline (`apply-engine`, still on GitHub): seven
ATS APIs polled nightly, ~10,000 postings normalized, scored and filtered, cover
letters drafted for the survivors. That came out on 2026-09-04 when the job hunt
was called off, and its seven tables went with it. Job *mail* is still labelled
and legitimacy-checked by the secretary skill, which is all that remains.

It was then a three-phase pipeline — ingest, sweep, present — which is where the
"phase" vocabulary in `engine_phase_runs` comes from. Phase 1 went on 2026-09-06;
phases 2, 2b and 3 became the single sweep on 2026-09-08, the same day the page
started reading the database for itself.

## License

MIT. See `LICENSE`.
