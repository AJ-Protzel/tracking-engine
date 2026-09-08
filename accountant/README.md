# Accountant — the transaction feed

Everything in `accountant_*` is loaded by one Supabase edge function. No Claude
routine writes any of it. The morning page reads these tables directly, through
Adrien's own Supabase connector, and that is the only other thing that touches
them.

Owners, so this stays true:

| Job | Owner |
|---|---|
| Load transactions | `accountant-simplefin-sweep` edge function, on a `pg_cron` schedule |
| Name and categorize merchants | the `accountant` account skill, on demand |
| Name and categorize from the page | the page itself, writing on save |
| Read for the morning report | the page itself, on every open |
| Anything else | nobody — do not add a routine for it |

Tapping a transaction on the morning page renames or recategorizes it, and the
page writes that to `accountant_merchant_aliases`, `accountant_merchant_categories`
and the transaction itself, directly. It keeps a copy in the artifact's own store
as its retry queue and retries anything unapplied on the next load. Until
2026-09-08 that edit sat in the store until an 8:00am routine drained it; there
is no routine now, and no wait.

So the merchant maps have TWO writers — the skill and the page — which is the one
place this system knowingly breaks its own one-owner rule. They write the same
two tables the same way, and an alias is idempotent, so a collision costs nothing
worse than a redundant upsert. Anything beyond those two tables is still
nobody's: the page must never DELETE a transaction or insert one.

## The function

Source here, deployed to Supabase project `qarwswpnzignofrwdqye` as
`accountant-simplefin-sweep`. Needs `SIMPLEFIN_ACCESS_URL` in the project's Edge
Function secrets; `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected.

`verify_jwt` is on, so a call needs a Supabase JWT. The publishable anon key is
enough — the function does its own writing with the service role key, which
never leaves the server.

### Modes

```
POST /functions/v1/accountant-simplefin-sweep?mode=<mode>
```

**`sweep`** — the daily job, one SimpleFIN request. The window is derived from
the *oldest* per-account watermark in `accountant_account_watermarks`, minus a
5-day pad, clamped to 14–90 days. Not a fixed 24 hours: a bank that posts late,
or a connection that was down for a week, still gets picked up on the next run
without anyone noticing it was behind. Every mapped account comes back in one
request, so the oldest watermark sets the window for all of them.

It also runs a health check after the write and lists any linked, active account
that has gone quiet longer than its own `expected_idle_days`. That threshold is
per account because he does not use every card — BofA Customized Cash and Chase
Freedom Unlimited are 60, AmEx Platinum 35, AmEx Checking 14, the daily drivers
5. A flat 3 days flagged five of eight accounts on the first real run, three of
them correctly quiet. Change the number with an UPDATE; no code change needed.

**`backfill`** — manual and resumable. Walks 90-day windows backwards from a
cursor in `accountant_backfill_state`, up to `windows` per run (default 6, max
20), and stops after two consecutive empty windows. Re-run it to continue from
where it stopped; `from=YYYY-MM-DD` restarts the cursor, `reset=true` clears the
exhausted flag.

```
?mode=backfill&from=2026-06-08&windows=8
```

**`dry_run`** — fetches, maps, writes nothing but a run row. `days` defaults to 7.

Every mode writes an `accountant_phase_runs` row. Dedupe is on `external_id`
(`simplefin:<id>`), so overlapping windows are free.

## Schedule

`pg_cron` job `accountant-simplefin-sweep`, `30 7 * * *` UTC — 12:30am Pacific in
summer, 11:30pm in winter. It calls the function through `pg_net`.

Thirty minutes ahead of the 1:00am Tracking Engine Sweep, so the night's
transactions are loaded before anything else runs. Both are fixed UTC and shift
together in November, so the ordering holds. It was `37 20 * * *` (1:37pm PT)
until 2026-09-08, which was fine while the page was rendered each morning and
wrong once the sweep moved to 1am.

SimpleFIN's Bridge pulls each bank roughly once every 24 hours at an hour that
varies by bank and by day, and there is no push and no on-demand refresh, so the
exact time matters less than the 5-day pad does. Budget is 24 requests/day; the
daily sweep uses one.

## How far back SimpleFIN actually reaches

**Measured 2026-09-06: about six months, not the 1–2 years the docs suggest.**
A backfill walked backwards from 2026-06-08 and found 36 transactions in
2026-03-10..2026-06-08, then zero in every window before that. A separate probe
of 2025-05-03..2025-08-01 also returned zero across all eight accounts.

So the 90-day-per-request limit was never the binding constraint — the banks
simply do not expose more than about six months through the Bridge. The
**2025-03-13 → 2026-03-18 gap can only be filled by CSV export** from each bank,
loaded through `accountant_ingest` with `source = 'csv'`, the same way the
2023-05-26 → 2025-03-12 history was.

## Tables

`accountant_transactions` is written only through `accountant_ingest(jsonb)`,
never by direct insert. Amounts are signed: negative out, positive in. Categories
are the nine — dining, grocery, shopping, utility, gas, travel, transfer, income,
fee — with `utility` meaning rent and utilities only and `transfer` excluded from
spend totals by `accountant_monthly`.

`accountant_clean_name` does **not** fall through to the raw descriptor. With no
alias match it returns `initcap()` of the text with `[0-9#*]` stripped, and that
is what gets stored. A `raw_pattern` containing a digit, `*` or `#` can therefore
never match anything, and it fails silently.

Views: `accountant_ledger`, `accountant_monthly`, `accountant_uncategorized`,
`accountant_account_watermarks`.
