-- 009 — move the SimpleFIN sweep ahead of the morning report
--
-- 007 scheduled the sweep at 37 20 * * * UTC (1:37pm PT). Phase 3 publishes the
-- morning report at 0 15 * * * UTC (8:00am PT) — five and a half hours EARLIER.
-- The report therefore rendered transactions as of the previous day's lunchtime,
-- every single day, and on 2026-09-06 it showed an empty September because the
-- first real sweep had not run yet when phase 3 went out.
--
-- 30 14 * * * UTC = 7:30am PT, thirty minutes before phase 3. The sweep is one
-- SimpleFIN request against an 14-90 day window and finishes in seconds, so the
-- gap is ample.
--
-- Applied 2026-09-06 with cron.alter_job(1, schedule => '30 14 * * *').
-- Recorded here so the repo matches what is actually scheduled.
--
-- Both times are fixed UTC and shift by an hour relative to Pacific when DST
-- ends in November. They shift TOGETHER, so their ordering holds; only the
-- wall-clock times move.

select cron.alter_job(
  (select jobid from cron.job where jobname = 'accountant-simplefin-sweep'),
  schedule => '30 14 * * *'
);
