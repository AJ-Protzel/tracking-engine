-- ---------------------------------------------------------------------------
-- One-time migration from the apply-engine layout, applied 2026-08-30.
--
-- Not needed for a fresh install -- 001_schema.sql already produces the end
-- state. This file exists so the change is auditable and repeatable against a
-- database that still has the old shape.
--
-- Context: measured before this ran, the database was 252 MB of the 500 MB free
-- tier after a single night of ingest. jobs was 238 MB of that, and 228 MB of
-- jobs was the TOAST side-table behind one column, `raw`. Only 59 MB of that
-- was live data; the rest was bloat, because the nightly run UPDATEs every row
-- and autovacuum cannot reclaim TOAST pages that fast.
--
-- TRUNCATE rather than DELETE is deliberate: it rewrites the table and its
-- TOAST, which is what actually returns the space. After this ran the database
-- was 11 MB.
-- ---------------------------------------------------------------------------

-- v_queue selected jobs.*, and an expanded star pins every column into the view
-- definition, so the view had to go before the column could.
drop view if exists public.v_queue;

alter table public.jobs drop column if exists raw;

-- Clean slate. The first pass was scored against a mis-aimed pool and none of
-- it is worth keeping. companies is NOT truncated: 149 validated ATS boards are
-- configuration bought with a ~325-candidate probe, not accumulated data.
truncate table public.jobs cascade;
truncate table public.email_events;

-- Retention deletes stale postings, so their filter and score rows must go with
-- them. Applications deliberately do not cascade -- an applied job stays.
alter table public.job_filters drop constraint job_filters_job_id_fkey;
alter table public.job_filters add constraint job_filters_job_id_fkey
  foreign key (job_id) references public.jobs(id) on delete cascade;

alter table public.job_scores drop constraint job_scores_job_id_fkey;
alter table public.job_scores add constraint job_scores_job_id_fkey
  foreign key (job_id) references public.jobs(id) on delete cascade;

-- Rebuilt without raw, and with the columns listed so this cannot happen again.
create view public.v_queue as
  select a.id as application_id, a.status, a.cover_url, a.queued_at,
         j.id, j.source, j.source_job_id, j.company, j.title, j.location_raw,
         j.region, j.employment_type, j.salary_min, j.salary_max, j.description,
         j.apply_url, j.posted_at, j.first_seen_at, j.last_seen_at,
         s.fit, s.compounding, s.verdict,
         s.builds, s.concerns, s.title_bucket
    from applications a
    join jobs j on j.id = a.job_id
    join job_scores s on s.job_id = j.id
   where a.status = 'queued'
   order by s.fit desc, j.first_seen_at desc;

-- `runs` was one row per whole pipeline run. phase_runs is one row per phase,
-- which is what makes the phases independently pausable: phase 3 can tell
-- "phase 2 ran and did nothing" apart from "phase 2 never ran".
drop table if exists public.runs;

-- The remaining new tables (phase_runs, accounts, transactions, email_actions,
-- blocklist, calendar_intents, food_log, nutrition_items) are created by
-- 001_schema.sql, which is idempotent and safe to run after this.
