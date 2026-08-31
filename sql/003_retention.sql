-- ---------------------------------------------------------------------------
-- Retention. Called by phase 1a at the end of every ingest.
--
-- The free tier caps the database at 500 MB. Dropping the raw payload column
-- took it from 252 MB to 11 MB, but ingest still writes ~10k postings a night,
-- so something has to remove what stopped mattering. This runs server-side
-- rather than in Python: it is several correlated deletes, and one round trip
-- inside one transaction is both faster and harder to half-apply.
-- ---------------------------------------------------------------------------

create or replace function public.prune_old_data()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  jobs_deleted    int;
  descs_cleared   int;
  runs_deleted    int;
  actions_deleted int;
  db_bytes        bigint;
begin
  -- Postings that went stale without ever being scored. Anything scored, or
  -- attached to an application, is history and stays: the weekly tuning numbers
  -- are only meaningful if the rejected pool remains measurable.
  delete from jobs j
   where j.last_seen_at < now() - interval '14 days'
     and not exists (select 1 from job_scores s where s.job_id = j.id)
     and not exists (select 1 from applications a where a.job_id = j.id);
  get diagnostics jobs_deleted = row_count;

  -- Scoring a job pins it forever, and the row carries up to 4,000 characters
  -- of description. At 40 scored a day that is ~58 MB/year of text for postings
  -- rejected months ago. The score row is the tuning evidence and stays; the
  -- description is only needed at scoring time, so it goes.
  update jobs j set description = null
   where j.description is not null
     and j.last_seen_at < now() - interval '30 days'
     and not exists (select 1 from applications a where a.job_id = j.id);
  get diagnostics descs_cleared = row_count;

  delete from phase_runs where started_at < now() - interval '90 days';
  get diagnostics runs_deleted = row_count;

  delete from email_actions where acted_at < now() - interval '90 days';
  get diagnostics actions_deleted = row_count;

  select pg_database_size(current_database()) into db_bytes;

  return jsonb_build_object(
    'jobs_deleted',          jobs_deleted,
    'descriptions_cleared',  descs_cleared,
    'phase_runs_deleted',    runs_deleted,
    'email_actions_deleted', actions_deleted,
    'db_bytes',              db_bytes,
    'db_pretty',             pg_size_pretty(db_bytes),
    -- Phase 3 paints a warning card when this is true. 350 MB of a 500 MB cap
    -- leaves room to notice and act before anything actually breaks.
    'over_threshold',        db_bytes > 350 * 1024 * 1024
  );
end;
$$;

-- Reachable only by the service key, which is what phase 1a authenticates with.
revoke all on function public.prune_old_data() from public, anon, authenticated;
grant execute on function public.prune_old_data() to service_role;
