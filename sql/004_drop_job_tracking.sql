-- ---------------------------------------------------------------------------
-- Remove job tracking entirely (2026-09-04).
--
-- The pipeline no longer scrapes ATS boards, scores postings, prepares cover
-- letters, or shows applications in the morning report. Phase 1 is gone; the
-- engine now tracks mail, money, calendar, food, and health only.
--
-- Every table below was exported to CSV before this ran. `companies` -- the 149
-- validated ATS boards -- went with them: it is only config for a phase that no
-- longer exists, and the CSV is enough to rebuild it if the job hunt resumes.
--
-- Order matters: the views read the tables, and the tables carry FKs into jobs.
-- `cascade` on the table drops takes the dependent constraints with them.
-- ---------------------------------------------------------------------------

drop view if exists v_queue_live;
drop view if exists v_queue;
drop view if exists v_blocked_employers;

drop table if exists email_events           cascade;
drop table if exists applications           cascade;
drop table if exists job_scores             cascade;
drop table if exists job_filters            cascade;
drop table if exists jobs                   cascade;
drop table if exists recruiter_submissions  cascade;
drop table if exists companies              cascade;

drop function if exists set_recruiter_submission_expiry() cascade;

-- Retention loses its two job clauses along with the tables they read. What is
-- left is the phase_runs and email_actions trim, which still matters: phase 2
-- writes an email_actions row per thread every morning.
create or replace function public.prune_old_data()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  runs_deleted    int;
  actions_deleted int;
  db_bytes        bigint;
begin
  delete from phase_runs where started_at < now() - interval '90 days';
  get diagnostics runs_deleted = row_count;

  delete from email_actions where acted_at < now() - interval '90 days';
  get diagnostics actions_deleted = row_count;

  select pg_database_size(current_database()) into db_bytes;

  return jsonb_build_object(
    'phase_runs_deleted',    runs_deleted,
    'email_actions_deleted', actions_deleted,
    'db_bytes',              db_bytes,
    'db_pretty',             pg_size_pretty(db_bytes),
    'over_threshold',        db_bytes > 350 * 1024 * 1024
  );
end;
$$;

revoke all on function public.prune_old_data() from public, anon, authenticated;
grant execute on function public.prune_old_data() to service_role;

-- Nothing calls prune_old_data() any more -- phase 1a was its only caller and
-- phase 1a is gone. Phase 2 calls it at the end of its sweep instead.
