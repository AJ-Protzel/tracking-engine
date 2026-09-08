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

This is the rule to apply when the system next wants to grow.

## Layout

```
sweep/         the one Claude routine, and why there is only one
page/          the morning report, and its backup copy
accountant/    the SimpleFIN edge function
sql/           schema and migrations (sql/archive/ is history, not live)
skills/        a skill definition kept in-repo
```

## Where the data comes from

| Table group | Written by |
|---|---|
| `accountant_*` | the SimpleFIN edge function; the `accountant` skill on demand; the page, when a charge is renamed |
| `doctor_*` | the `doctor` skill, when Adrien logs something in a chat |
| `engine_*` | the sweep |

One owner per table, with one knowing exception: the merchant maps are written
by both the `accountant` skill and the page. They write the same two tables the
same way and an upsert is idempotent, so a collision costs nothing.

## The page

**https://claude.ai/code/artifact/fb3d377a-c279-4b59-b182-2b90616d084d** —
private, read on a phone from the home screen.

It queries Supabase itself, through Adrien's own connector, every time it is
opened. Nothing renders it and nothing republishes it on a schedule.

That is a recent and load-bearing change. Until 2026-09-08 a routine rebuilt the
whole page every morning: read a 68 KB template and ~2,000 transactions into a
model, write the entire page back out. It cost tens of thousands of output
tokens a day, it was only ever as fresh as the last run, and every design change
made on the page had to be backported into this repo or the next morning would
flatten it.

Now the page is permanent and the data is live. Details and the rules that keep
it that way: `page/README.md`.

## Skills

Adrien talks to these; they are not scheduled. They are managed on claude.ai
rather than in this repo, so they cannot be edited from a clone.

| Skill | Owns |
|---|---|
| `secretary` | email and calendar — including the judgment the 1am sweep uses |
| `accountant` | transactions, merchant names and categories |
| `doctor` | food, nutrition and health entries |
| `tutor` | data-engineering practice. No data on the page |

The sweep does not restate the secretary's rules; it calls the skill. One
definition of how mail is handled, whether it runs at 1am or he asks at 2pm.

`skills/food-tracker/` predates the `doctor` skill and covers the same two
tables. It is kept for now because it may be the working copy behind the cloud
skill, but it is a second definition of one job and should be reconciled.

## Running it

There is nothing to install and nothing to start.

The routine is a prompt on a scheduler, about ten lines: fetch the raw GitHub
URL for `sweep/routine.md`, follow everything after the first `---`, and on a
second failed fetch write a failed `engine_phase_runs` row and stop rather than
improvise. **Editing that file and pushing changes live behavior on the next
run.** Never paste a prompt body into the scheduler — that creates a second copy
and the two drift with nothing to say so.

The one piece of deployed code is the SimpleFIN edge function, which Supabase
runs. See `accountant/README.md`.

Both schedules are fixed UTC and need a manual one-hour bump when Pacific goes
back to standard time in November. They shift together, so the sweep stays
behind the transaction load.

## History

This began as a job-application pipeline (`apply-engine`, still on GitHub): seven
ATS APIs polled nightly, ~10,000 postings normalized, scored and filtered, with
cover letters drafted for the survivors. That was removed on 2026-09-04 when the
job search was scrapped, and the tables went with it. Job *mail* is still
labeled and legitimacy-checked, which is all that remains of it.

It was then a three-phase pipeline — ingest, sweep, present — which is where the
"phase" vocabulary in `engine_phase_runs` comes from. Phase 1 was removed on
2026-09-06; phases 2, 2b and 3 became the single sweep on 2026-09-08.

`sql/archive/` holds migrations that no longer describe anything live:
`002` migrated the apply-engine job tables, and `003` is a retention function
that reads three tables which no longer exist. Kept as history; do not run them.

## License

MIT. See `LICENSE`.
