# What the database actually holds

*(`database/SCHEMA.md` — the migrations beside it are how it got this way.)*

A snapshot of the live schema, taken 2026-09-09, plus the rules the columns
imply but cannot enforce. **Read this before writing anything**, especially
before changing a value some routine or the page writes.

`functions.sql` beside it holds the three function bodies, generated with
`pg_get_functiondef` — logic has to be kept as logic, and it is the one part of
the schema this document cannot describe in prose.

**There is no rebuild script and no migration folder.** The numbered migrations
were deleted on 2026-09-09: every one had been applied, and `001` — the file
claiming to reproduce the system — still created a `accountant_wedding_vendors`
table dropped four days earlier. A rebuild script that rebuilds the wrong schema
is worse than none, and git holds all eight files if the reasoning is ever
wanted (`git log -- database/`).

When this document and the live database disagree, the database is right.
Regenerate from the query below rather than trusting the page.

Twice now a change has been made in two places and not the third. On 2026-09-08
the phases were consolidated and both the routine and the page were updated to
say `sweep` — but the CHECK constraint still allowed only the old values, so the
first run could not open its run row, *and could not write a failed row either*,
because that insert names the same rejected column. It failed silently. The same
day, the page was written to look for `action = 'draft'` where the table only
accepts `'drafted'`; that one had not fired yet.

Both were the same mistake: an allowed-value list living in the database, and a
second copy of it living in someone's head. This file is that list, written down.

## Regenerating it

This snapshot is hand-maintained and will drift. When in doubt, ask the database
rather than trusting the page below:

```sql
-- every CHECK constraint and what it allows
select rel.relname||'.'||con.conname||' = '||pg_get_constraintdef(con.oid)
  from pg_constraint con
  join pg_class rel on rel.oid = con.conrelid
  join pg_namespace n on n.oid = rel.relnamespace
 where n.nspname = 'public' and con.contype = 'c'
 order by rel.relname;
```

## Constrained values — the ones that bite

Anything written outside these lists is rejected outright. There is no partial
write and no coercion.

| Column | Allowed |
|---|---|
| `engine_phase_runs.phase` | **`sweep`** — plus `1a` `1b` `2` `2b` `3`, which exist only for old rows. Never write a legacy value |
| `engine_phase_runs.status` | `running` `ok` `failed` `skipped` |
| `engine_email_actions.action` | `labeled` **`drafted`** `trashed` `spam_rescued` `blocked` `skipped` |
| `engine_calendar_intents.status` | `pending` `created` `skipped` `failed` |
| `engine_blocklist.status` | `Watching` `Blocked` |
| `accountant_transactions.category` | `dining` `grocery` `shopping` `utility` `gas` `travel` `transfer` `income` `fee` — or NULL, which the page shows as "uncategorized" |
| `accountant_transactions.source` | `simplefin` `csv` `manual` |
| `accountant_merchant_categories.category` | the same nine. No NULL — the map cannot hold "no category" |
| `accountant_phase_runs.mode` | `dry_run` `backfill` `sweep` |
| `accountant_accounts.kind` | `checking` `savings` `credit` `investment` `other` |
| `accountant_accounts.type` | `credit` `debit` |
| `accountant_accounts.owner` | `me` `joint` `ashley` |
| `accountant_accounts.network` | `visa` `mastercard` `amex` `discover`, or NULL |
| `doctor_food_log.person` | `Adrien` `Ashley` — capitalised |
| `doctor_targets.person` | `Adrien` `Ashley` — one row each, the person is the key |
| `doctor_health_log.person` | `Adrien` `Ashley` |
| `doctor_health_log.entry_type` | `symptom` `vital` `medication` `event` `note` |
| `doctor_health_log.status` | `open` `resolved` `recurring` `monitoring` |
| `doctor_health_log.severity` | integer 1–10 |

`drafted` and `Adrien`/`Ashley` are the three most likely to be got wrong:
one reads like a noun where the column wants a past tense, and the other two are
case-sensitive where nothing else is.

## Rules that are not written in the columns

Four things the schema implies but does not enforce. Each was learned by getting
it wrong; each lives here rather than in a migration comment because this is the
file people actually open.

**A table's prefix names its owner.** `doctor_*` belongs to the doctor skill,
`accountant_*` to the accountant skill and the SimpleFIN function, `engine_*` to
the sweep. This is why a skill can be told "you own every table named
`doctor_*`" rather than handed a list — adding a table later needs no skill
edit. Enumerating table names in a skill description is the thing that goes
stale; a prefix rule does not.

**`accountant_clean_name()` strips `[0-9#*]` before storing.** So a
`raw_pattern` in `accountant_merchant_aliases` containing a digit, `*` or `#`
can never match anything, and it fails silently — the alias just sits there
doing nothing forever. Strip them before writing one.

**`accountant_transactions` is written only through `accountant_ingest(jsonb)`.**
Never insert directly. Dedupe is on `external_id`, which is what makes
overlapping SimpleFIN windows free.

**Staleness is per account, not global.** `accountant_accounts.expected_idle_days`
exists because a flat 3-day threshold flagged five of eight accounts on its first
run, three of them correctly quiet — cards that genuinely go unused for weeks. A
check that fires every morning on accounts that are fine is a check nobody reads.
Change the number with an UPDATE; no code change needed.

## Tables

Row counts are from 2026-09-09 and only indicate scale.

### engine_* — owned by the sweep

| Table | Rows | Columns |
|---|---|---|
| `engine_phase_runs` | 35 | id, phase, started_at, finished_at, status, counts jsonb, summary jsonb, error |
| `engine_email_actions` | 65 | id, run_id, gmail_thread_id, action, label, subject_snippet, acted_at, note |
| `engine_blocklist` | 13 | sender_email, trash_dates date[], status, blocked_date, updated_at |
| `engine_calendar_intents` | 2 | id, gmail_thread_id, calendar, title, starts_at, ends_at, location, note, status, google_event_id, created_at, drained_at |

`engine_calendar_intents` now only ever holds `status = 'skipped'` rows — things
that named a date but no time. The sweep creates real events directly; nothing
drains this table any more.

### accountant_* — owned by the SimpleFIN function, the accountant skill, and the page

| Table | Rows | Columns |
|---|---|---|
| `accountant_transactions` | 2,976 | id, account_id, date, amount numeric(12,2), description, category, source, external_id |
| `accountant_accounts` | 16 | id, name, kind, active, issuer, annual_fee_usd, owner, network, last4, simplefin_account_id, bank, type, expected_idle_days, … |
| `accountant_merchant_aliases` | 714 | raw_pattern, clean_name |
| `accountant_merchant_categories` | 642 | clean_name, category |
| `accountant_phase_runs` | 12 | id, ran_at, mode, accounts_seen, txns_seen, rows_inserted, rows_skipped, errors, note |
| `accountant_backfill_state` | 1 | single row, id is always 1 |

`amount` is signed: negative out, positive in, on credit and debit alike. Never
re-derive the sign or take an absolute value.

### doctor_* — owned by the doctor skill, on demand

| Table | Rows | Columns |
|---|---|---|
| `doctor_food_log` | 5 | id, meal, person, date, calories, protein_g, carbs_g, fat_g, sugar_g |
| `doctor_nutrition_items` | 10 | id, item, serving, and the same five nutrients |
| `doctor_health_log` | 0 | id, person, date, logged_at, entry_type, label, body_location, severity, value, unit, started_at, resolved_at, status, suspected_cause, notes |
| `doctor_targets` | 0 | person, calories, protein_g, note, set_at |

A table with no rows is not a broken one — the page renders that as "no entries
yet".

**Dates in `doctor_*` are Pacific dates, and this database runs in UTC.** Write
and read them as `(now() at time zone 'America/Los_Angeles')::date`; plain
`current_date` is already tomorrow from 5pm Pacific onwards, which silently
files an evening meal on the wrong day.

## Views, functions, jobs

**Views** — `accountant_ledger`, `accountant_monthly`, `accountant_uncategorized`,
`accountant_account_watermarks`. `accountant_monthly` excludes `transfer` from
spend totals.

**Functions**

- `accountant_ingest(jsonb)` — the only way rows enter `accountant_transactions`.
  Never insert directly.
- `accountant_clean_name(text)` — with no alias match, returns `initcap()` of the
  text with `[0-9#*]` stripped. **A `raw_pattern` containing a digit, `*` or `#`
  can therefore never match anything, and it fails silently.** Strip them before
  writing an alias.
- `prune_old_data()` — trims `engine_phase_runs` and `engine_email_actions` past
  90 days. Touches no `accountant_` table.

**Scheduled** — one `pg_cron` job: `accountant-simplefin-sweep` at `30 7 * * *`
UTC (12:30am PT). That is the only thing the database runs on its own.

## RLS

Every table has row level security enabled. The SimpleFIN function writes with
the service role key, which never leaves the server; the page reads and writes as
the viewer through their own Supabase connector.
