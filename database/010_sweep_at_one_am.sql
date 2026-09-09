-- 010 — move the SimpleFIN sweep ahead of the 1:00am routine
--
-- 009 put the sweep at 30 14 * * * UTC (7:30am PT), thirty minutes before the
-- morning report was rendered at 8:00am. On 2026-09-08 two things changed:
--
--   1. The page stopped being rendered at all. It queries Supabase directly
--      through Adrien's connector every time he opens it, so there is no run to
--      be "before" any more and no daily render to feed. See page/README.md.
--   2. The three Claude routines became one, moved to 1:00am PT so it lands at
--      the far end of his usage window rather than just before he reads.
--
-- 30 7 * * * UTC = 12:30am PT, thirty minutes ahead of that sweep. The report no
-- longer depends on this ordering — it reads whatever is in the table when it is
-- opened — but the sweep's own run summary is more useful when the night's
-- transactions are already in, and a fixed ordering is one less thing to reason
-- about.
--
-- Applied 2026-09-08 with cron.alter_job. Recorded here so the repo matches what
-- is actually scheduled.
--
-- Both this and the routine's cron are fixed UTC and shift by an hour relative
-- to Pacific when DST ends in November. They shift TOGETHER, so the ordering
-- holds; only the wall-clock times move.

select cron.alter_job(
  (select jobid from cron.job where jobname = 'accountant-simplefin-sweep'),
  schedule => '30 7 * * *'
);
