-- 007 -- resumable backfill state, account watermarks, and the daily schedule
--
-- Applied to qarwswpnzignofrwdqye on 2026-09-06 via apply_migration, so unlike
-- 006 this one IS in Supabase's migration history.
--
-- Context: accountant_transactions held 1,627 CSV rows ending 2025-03-12 and
-- nothing had ever been written by the SimpleFIN function -- accountant_phase_runs
-- held two dry runs and no cron job existed. This adds what the daily sweep and
-- the gap-filling backfill need, then schedules the sweep.

-- ---------------------------------------------------------------------------
-- Backfill cursor. One row, id = 1. The backfill walks 90-day windows backwards
-- and persists where it stopped, so a run that hits an error or its window cap
-- resumes instead of restarting.
-- ---------------------------------------------------------------------------
create table if not exists accountant_backfill_state (
  id            smallint primary key default 1 check (id = 1),
  cursor_end    date        not null,
  windows_done  integer     not null default 0,
  requests_made integer     not null default 0,
  rows_inserted integer     not null default 0,
  exhausted     boolean     not null default false,
  last_note     text,
  updated_at    timestamptz not null default now()
);

alter table accountant_backfill_state enable row level security;
-- RLS on, no policies: service_role only, same as every other accountant table.

insert into accountant_backfill_state (id, cursor_end)
values (1, current_date)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Per-account watermarks. The sweep derives its window from the OLDEST of these
-- rather than a hardcoded 24 hours, so a bank that posted late still gets swept.
-- days_stale drives the health check (>3 days on a linked, active account).
-- ---------------------------------------------------------------------------
create or replace view accountant_account_watermarks
with (security_invoker = on) as
select a.id  as account_id,
       a.bank,
       a.name as account,
       a.active,
       (a.simplefin_account_id is not null) as linked,
       count(t.id)                  as txns,
       max(t.date)                  as last_txn,
       (current_date - max(t.date)) as days_stale
  from accountant_accounts a
  left join accountant_transactions t on t.account_id = a.id
 group by a.id, a.bank, a.name, a.active, a.simplefin_account_id
 order by a.id;

-- ---------------------------------------------------------------------------
-- Daily schedule. 37 20 * * * UTC = 1:37pm Pacific in summer. Odd minute on
-- purpose. The Authorization header carries the project's PUBLISHABLE anon key,
-- which is all verify_jwt needs; the function does its own writes with the
-- service role key from its environment, which never appears here.
--
-- Re-run cron.schedule with the same job name to change the time or the body;
-- cron.unschedule('accountant-simplefin-sweep') removes it.
-- ---------------------------------------------------------------------------
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net  with schema extensions;

-- select cron.schedule(
--   'accountant-simplefin-sweep',
--   '37 20 * * *',
--   $job$
--   select net.http_post(
--     url     := 'https://qarwswpnzignofrwdqye.supabase.co/functions/v1/accountant-simplefin-sweep?mode=sweep',
--     headers := jsonb_build_object(
--                  'Content-Type', 'application/json',
--                  'Authorization', 'Bearer <publishable anon key>'),
--     body    := '{}'::jsonb,
--     timeout_milliseconds := 120000
--   );
--   $job$
-- );

-- ---------------------------------------------------------------------------
-- What the first real runs found, 2026-09-06.
--
--   sweep     90-day window (five accounts had no rows at all): 8 accounts,
--             414 transactions seen, 413 inserted.
--   backfill  from 2026-06-08, 8 windows requested, 3 used: 36 rows in
--             2026-03-10..2026-06-08, then zero in 2025-12-10..2026-03-10 and
--             zero in 2025-09-11..2025-12-10, so it stopped. A manual probe of
--             2025-05-03..2025-08-01 also returned zero.
--
-- SimpleFIN reaches back about six months for these institutions, not the 1-2
-- years assumed when the chunked backfill was specified. The 90-day per-request
-- limit was never the binding constraint. 2025-03-13 -> 2026-03-18 stays empty
-- until bank CSV exports are loaded through accountant_ingest with source='csv'.
-- ---------------------------------------------------------------------------
