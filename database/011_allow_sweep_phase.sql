-- 011 — let engine_phase_runs record the consolidated sweep
--
-- On 2026-09-08 phases 2, 2b and 3 became one routine writing phase = 'sweep'.
-- The check constraint was never widened to accept it, so the first 1:00am run
-- on 2026-09-09 could not open its run row — and could not write a FAILED row
-- either, because that insert names the same rejected column. It stopped with
-- no trace in the table, which is why the page still read "Email sweep has
-- never run" rather than "Email sweep failed".
--
-- Worth remembering as a shape, not just an incident: a routine whose only way
-- to report failure is a write that fails the same way is silent exactly when
-- it most needs to speak. The check ran before the value it guards was ever
-- exercised. Renaming an enum value means changing the constraint in the same
-- change, not after the first run finds it.
--
-- The five legacy values stay. 35 existing rows use them, and a CHECK is
-- validated against existing rows when added, so dropping them would make this
-- migration fail. They are history, not values anything writes any more: 1a and
-- 1b died with phase 1 on 2026-09-06, and 2, 2b and 3 on 2026-09-08. 'sweep' is
-- the only value a live routine writes.
--
-- Applied 2026-09-09.

alter table engine_phase_runs drop constraint phase_runs_phase_check;

alter table engine_phase_runs add constraint phase_runs_phase_check
  check (phase = any (array['sweep'::text,
                           '1a'::text, '1b'::text, '2'::text, '2b'::text, '3'::text]));
