# Accountant — the transaction feed

Everything in `accountant_*` is loaded by one Supabase edge function. No Claude
routine writes any of it. Phase 3 reads the views to draw the morning report and
that is the only other thing that touches these tables.

Owners, so this stays true:

| Job | Owner |
|---|---|
| Load transactions | `accountant-simplefin-sweep` edge function, on a `pg_cron` schedule |
| Name and categorize merchants | the `accountant` account skill, on demand |
| Read for the morning report | phase 3, read-only |
| Anything else | nobody — do not add a routine for it |

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

`pg_cron` job `accountant-simplefin-sweep`, `37 20 * * *` UTC — 1:37pm Pacific in
summer, 12:37pm in winter. An odd minute on purpose. It calls the function
through `pg_net`.

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
