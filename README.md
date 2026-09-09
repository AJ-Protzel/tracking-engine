# tracking-engine

A personal tracking system for one person. Bank transactions and email arrive on
their own and are swept automatically; everything else is added by talking to
the skill that owns it. One private web page shows the result.

Two things run on a schedule. Everything else is conversational.

```
12:30am PT   accountant-simplefin-sweep   Supabase edge function, pg_cron
 1:00am PT   Tracking Engine Sweep        one Claude routine, sweep/routine.md
```

That is the whole of it.

## The rule the design rests on

> **Schedule only what arrives whether or not he asks.**

Transactions arrive from the bank. Mail arrives in the inbox. Neither waits for
a request, so both need something watching.

Food, health entries, merchant categorization, tutoring — those only ever happen
because Adrien starts them, in a chat, with the skill that owns that data. They
need no schedule, no sweep and no routine. Adding one only creates a second
writer for a table that already has an owner.

This is the rule to apply when the system next wants to grow. It is also what
retired two dead pipelines: job tracking, and an xlsx food tracker that synced
itself to Drive nightly so a cloud routine could email a chart back.

## Layout

```
sweep/routine.md      the one Claude routine — fetched from GitHub at run time
artifact/             the morning page: a backup copy of what is published
simplefin/            the edge function that loads transactions
sql/                  migrations, and SCHEMA.md — what the database allows
```

Fifteen files. There is deliberately one README — this one. Per-folder READMEs
were tried and drifted: one still described a phase 3 that had been deleted.

**`sweep/routine.md` must keep that exact path.** The scheduler fetches it by
raw GitHub URL at run time, so moving or renaming it breaks the 1am run until
the scheduler entry is edited to match.

## Where the data comes from

| Table group | Written by |
|---|---|
| `accountant_*` | the SimpleFIN edge function; the `accountant` skill on demand; the page, when a charge is renamed |
| `doctor_*` | the `doctor` skill, when Adrien logs something in a chat |
| `engine_*` | the sweep |

One owner per table, with one knowing exception: the merchant maps are written
by both the `accountant` skill and the page. They write the same two tables the
same way and an upsert is idempotent, so a collision costs nothing.

**Before writing anything, read `sql/SCHEMA.md`.** It lists every constrained
column and its legal values. Two bugs in one day came from a value list living
in the database and a second copy of it living in someone's head.

## The skills

Adrien talks to these; they are not scheduled. **They live on claude.ai, not in
this repo, and that is on purpose** — nothing here reads them, so a copy checked
in would be a second definition with nothing reconciling it against the live one.

| Skill | Owns |
|---|---|
| `secretary` | email and calendar — including the judgment the 1am sweep uses |
| `accountant` | transactions, merchant names and categories |
| `doctor` | food, nutrition and health entries |
| `tutor` | data-engineering practice. No data on the page |

What matters here is the boundary — which skill owns which tables — not their
implementation. The sweep does not restate the secretary's rules; it calls the
skill, so a sweep at 1am and a request at 2pm cannot drift apart.

## The sweep

`sweep/routine.md` is the prompt. The cloud routine **Tracking Engine Sweep**
fetches it at run time and follows everything after the first `---`, so editing
that file and pushing changes live behavior on the next run. There is nothing to
paste into the scheduler — and pasting a prompt body there creates a second copy
that drifts with nothing to say so.

| | |
|---|---|
| Runs | 1:00am PT — cron `0 8 * * *` UTC |
| Connectors | Supabase, Gmail, Google Calendar |
| Writes | `engine_email_actions`, `engine_blocklist`, `engine_calendar_intents`, `engine_phase_runs` |

### Why there is exactly one

This was three routines until 2026-09-08: an email sweep at 7:15am, a calendar
drain at 7:45am, and a page build at 8:00am, each paying for its own session
boot, connector setup and run row.

The calendar drain existed because it was a separate session, and a calendar
failure should not take the inbox pass down with it. Inside one session that is
a `try`/`catch`, not a table and a second routine. The page build existed because
a model had to render the page; it no longer does.

### The 1am tradeoff, on purpose

The sweep covers yesterday's mail, and mail arriving between 1am and when Adrien
wakes is swept the next night. That puts the run at the far end of his usage
window rather than thirty minutes before he reads.

The page does not care — it queries live, so it always shows the current state
of the database no matter when the sweep last ran.

## The page

**https://claude.ai/code/artifact/fb3d377a-c279-4b59-b182-2b90616d084d** —
private, read on a phone from the home screen. It carries transactions, food
entries and email subjects. Never share it, and never publish it to a second URL.

It queries Supabase directly, through Adrien's own connector, every time it is
opened. Nothing renders it and nothing republishes it on a schedule.

Until 2026-09-08 a routine rebuilt it every morning: read a 68 KB template and
~2,000 transactions into a model, write the entire page back out. It cost tens of
thousands of output tokens a day, it was only ever as fresh as the last run, and
every design change made on the page had to be backported here or the next
morning would flatten it. Both problems went away with the same change.

**So: never publish this artifact from a routine.** A routine that republished it
would overwrite his edits and bring back the cost.

### How it works

Declared capabilities: `mcp` (the `Supabase` connector, `execute_sql` only) and
`db` (the artifact's own store). Four calls, one per card, so a failure is
contained to the card it feeds:

| Card | Reads |
|---|---|
| Money, Over Time | `accountant_transactions`, every row |
| the `Synced` line | `max(ran_at)` from `accountant_phase_runs` |
| Nutrition | `doctor_food_log`, 7 days, both people |
| Requires Action | `engine_email_actions`, `engine_calendar_intents`, `engine_phase_runs` |

Card Credits is static markup. The masthead date and `complete_from` are computed
in the page.

Two things learned the hard way, both worth keeping:

- **Rows are read from `payload` first, then `structuredContent`, then each
  content block's text** — never by walking the result for the first array of
  objects. `res.content` is an array of `{type, text}` envelope blocks and gets
  found first, so every card silently rendered the wrapper instead of the data.
- **Each query names a column only it returns**, checked before the rows are
  used. Four `watchTool` registrations on the same tool delivered each other's
  results, and the money card drew the sync query's single row.

Each connector error code gets its own message naming the one action that fixes
it. A catch-all banner would hide that, so do not collapse them. An empty result
is a legitimate answer and is rendered as such, never as a failure.

### Edits write straight to Postgres

Tapping a charge opens a rename-and-categorize panel. On save the page writes to
the database itself, re-reads, and only then drops its local copy — in that
order, because marking the edit applied removes it from the overlay drawn over
the rows, and doing that before the re-read makes a saved rename flick back to
the old name. A write that fails stays queued and is retried on the next load,
so the page drains its own queue and no routine has to.

`execute_sql` offers no parameter binding, so every value is escaped in the page
and the category is checked against the nine the table allows; a transaction id
must be digits. Anything failing a check is not written.

### The store

Four collections in the artifact's own db store, all written by the page:
`credits` (which card credits are ticked), `actions` (dismissed items),
`txn_edits` (the retry queue), and `diag` (what a card received when it could not
read a reply — written only on failure).

### artifact/template.html

A copy of what is published, kept as a backup and as something to read. It is
**not** a build input — nothing renders from it. If the two disagree, the
published page wins; copy it back over this file, not the other way around.

The ~30 transactions embedded in it are the offline fallback, the current month
only. They are never the page's data and a refresh is never required.

Publish updates with the Artifact tool, passing the URL above so it updates in
place, and pass no `favicon` and no `title` — a redeploy keeps them. Pass
`capabilities` **only** to change them, and when you do, restate the whole set: a
non-empty declaration revokes anything left out, which would take the card ticks,
the dismissals and the live data down together.

## The transaction feed

`simplefin/` is a Supabase edge function, deployed as
**`accountant-simplefin-sweep`**. No Claude routine writes any `accountant_`
table; this loads them.

Needs `SIMPLEFIN_ACCESS_URL` in the project's Edge Function secrets;
`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected. `verify_jwt` is on.

```
POST /functions/v1/accountant-simplefin-sweep?mode=<mode>
```

- **`sweep`** — the daily job, one request. The window comes from the *oldest*
  per-account watermark minus a 5-day pad, clamped to 14–90 days, so a bank that
  posts late or a connection that was down for a week is still picked up.
  Afterwards it flags any active account quiet longer than its own
  `expected_idle_days` — per account, because he does not use every card.
- **`backfill`** — manual, resumable. Walks 90-day windows backwards from a
  stored cursor, stopping after two empty ones. `?mode=backfill&from=YYYY-MM-DD&windows=8`
- **`dry_run`** — fetches and maps, writes nothing but a run row.

Dedupe is on `external_id`, so overlapping windows are free.

**SimpleFIN reaches back about six months, not the 1–2 years the docs suggest**
(measured 2026-09-06). Anything older has to come from a bank CSV export loaded
through `accountant_ingest` with `source = 'csv'` — which is how the
2025-03 → 2026-03 gap was finally filled on 2026-09-09.

## Both crons are fixed UTC

They need a manual one-hour bump when Pacific goes back to standard time in
November. They shift together, so the sweep stays behind the transaction load.

## History

This began as a job-application pipeline (`apply-engine`, still on GitHub): seven
ATS APIs polled nightly, ~10,000 postings normalized, scored and filtered, with
cover letters drafted for the survivors. Removed on 2026-09-04 when the job
search was scrapped. Job *mail* is still labeled and legitimacy-checked, which is
all that remains of it.

It was then a three-phase pipeline — ingest, sweep, present — which is where the
"phase" vocabulary in `engine_phase_runs` comes from. Phase 1 was removed on
2026-09-06; phases 2, 2b and 3 became the single sweep on 2026-09-08.

Migrations `002` and `003` were deleted on 2026-09-09. They described the
apply-engine job tables and a retention function reading three tables that no
longer exist. Git holds them; keeping dead migrations as files mostly invites
someone running one.

## License

MIT. See `LICENSE`.
