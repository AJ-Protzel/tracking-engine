-- ---------------------------------------------------------------------------
-- tracking-engine schema
--
-- The full current shape of the Tracking-Engine Supabase project. Running this
-- against an empty database reproduces the system.
--
-- This is the shape AFTER 004, the removal of job tracking, applied to the live
-- database on 2026-09-04. It no longer creates the seven job tables. 002 and 003
-- are kept only as the historical record of how the database got here -- do not
-- run them against a fresh install.
--
-- Everything here is written by a scheduled cloud routine or a skill, and read
-- by the morning report. Phase 1 still exists in this repo but is detached and
-- writes to nothing; see phase1/README.md.
--
-- Design notes worth knowing before changing anything:
--   * A view is a hole in RLS unless you say otherwise. Every view here sets
--     security_invoker = true, and any view added later needs it too -- see the
--     note in README.md.
--   * The revoke block at the bottom is load-bearing. Read it before adding a
--     table or a policy.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Phase telemetry.
--
-- One row per phase per run. Phase 3 reads the newest row for each phase to
-- decide whether a card says "nothing changed" or "did not run" -- which is
-- what lets any phase be paused without the morning report looking broken.
-- ---------------------------------------------------------------------------
create table if not exists engine_phase_runs (
  id          bigserial primary key,
  -- The live database still allows '1a' and '1b': historical rows carry those
  -- values and tightening the constraint would have rejected them. A fresh
  -- install has no such rows, so the narrow check is correct for one.
  phase       text not null check (phase in ('2','2b','3')),
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  status      text not null default 'running'
              check (status in ('running','ok','failed','skipped')),
  counts      jsonb not null default '{}'::jsonb,
  summary     jsonb,
  error       text
);
create index if not exists phase_runs_phase_started_idx
  on engine_phase_runs (phase, started_at desc);

-- ---------------------------------------------------------------------------
-- Phase 2 and 3 tables.
-- ---------------------------------------------------------------------------

-- Account names only. No card or account numbers, ever.
create table if not exists accountant_accounts (
  id         bigserial primary key,
  name       text not null unique,            -- e.g. 'Chase Checking'
  kind       text not null default 'checking'
             check (kind in ('checking','savings','credit','investment','other')),
  active     bool not null default true,
  created_at timestamptz not null default now()
);

-- Written by phase 2 from Money In / Money Out email, and later from a CSV
-- export. Only catches what emails a receipt, which the artifact says plainly
-- rather than implying the picture is complete.
create table if not exists accountant_transactions (
  id          bigserial primary key,
  account_id  bigint references accounts(id) on delete set null,
  date        date not null,
  name        text not null,
  merchant    text,
  amount      numeric(12,2) not null,
  direction   text not null check (direction in ('in','out')),
  source      text not null default 'email' check (source in ('email','csv','manual')),
  wedding     bool not null default false,    -- surfaced for the wedding sheet
  notes       text,
  external_id text unique,                    -- makes re-imports idempotent
  created_at  timestamptz not null default now()
);
create index if not exists transactions_date_idx on accountant_transactions (date desc);

-- What phase 2 did, per thread. Feeds the artifact's email card and makes the
-- sweep auditable after the fact.
create table if not exists engine_email_actions (
  id              bigserial primary key,
  run_id          bigint references engine_phase_runs(id) on delete set null,
  gmail_thread_id text not null,
  action          text not null
                  check (action in ('labeled','drafted','trashed','spam_rescued','blocked','skipped')),
  label           text,
  subject_snippet text,
  note            text,                       -- newsletter gist, draft From address
  acted_at        timestamptz not null default now()
);
create index if not exists email_actions_acted_idx on engine_email_actions (acted_at desc);
-- prune_old_data() deletes aged engine_phase_runs rows, and each delete forces an FK
-- recheck against this table. Cheap to carry, and this table only grows.
create index if not exists email_actions_run_id_idx on engine_email_actions (run_id);

-- Senders to watch or trash on sight. Lifted out of a Google Drive CSV so that
-- no phase depends on a file that can be moved, renamed, or half-written.
create table if not exists engine_blocklist (
  sender_email text primary key,
  trash_dates  date[] not null default '{}',
  status       text not null default 'Watching' check (status in ('Watching','Blocked')),
  blocked_date date,
  updated_at   timestamptz not null default now()
);

-- Phase 2 writes the intent; phase 2b creates the calendar event. Split so a
-- calendar outage cannot take the email sweep down with it, and so intents
-- queue harmlessly until the Google calendars exist.
create table if not exists engine_calendar_intents (
  id              bigserial primary key,
  gmail_thread_id text not null,
  calendar        text not null,              -- Work | Health | Holiday | Wedding | Birthday | Claude
  title           text not null,
  starts_at       timestamptz,                -- no time means no event gets created
  ends_at         timestamptz,
  location        text,                       -- always set for a destination event
  note            text,                       -- what was missing, if anything
  status          text not null default 'pending'
                  check (status in ('pending','created','skipped','failed')),
  google_event_id text,
  created_at      timestamptz not null default now(),
  drained_at      timestamptz,
  unique (gmail_thread_id, title, starts_at)
);

-- Wedding vendor names live in the database, not in config/, because this repo
-- is public and a vendor list is a map of a private life. Phase 2 reads it to
-- decide whether a transaction is wedding-related.
create table if not exists accountant_wedding_vendors (
  name       text primary key,
  note       text,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Food tracking, moved in from the separate Food-Tracker project so one
-- database backs the whole morning report. Shapes are unchanged.
-- ---------------------------------------------------------------------------
create table if not exists doctor_nutrition_items (
  id        uuid primary key default gen_random_uuid(),
  item      text not null,
  serving   text not null,
  calories  numeric,
  protein_g numeric,
  carbs_g   numeric,
  fat_g     numeric,
  sugar_g   numeric
);

create table if not exists doctor_food_log (
  id        uuid primary key default gen_random_uuid(),
  meal      text not null,
  person    text not null check (person in ('Adrien','Ashley')),
  date      date not null,
  calories  numeric,
  protein_g numeric,
  carbs_g   numeric,
  fat_g     numeric,
  sugar_g   numeric
);
create index if not exists food_log_date_idx on doctor_food_log (date desc);

-- Symptoms, vitals, medications and events, one row per entry. Read and written
-- by the doctor skill, which also owns doctor_food_log and doctor_nutrition_items above.
create table if not exists doctor_health_log (
  id              uuid primary key default gen_random_uuid(),
  person          text not null default 'Adrien' check (person in ('Adrien','Ashley')),
  date            date not null default current_date,
  logged_at       timestamptz not null default now(),
  entry_type      text not null check (entry_type in ('symptom','vital','medication','event','note')),
  label           text not null,
  body_location   text,
  severity        int check (severity between 1 and 10),
  value           numeric,                    -- for vitals: the reading
  unit            text,                       -- for vitals: mmHg, bpm, lb
  started_at      date,
  resolved_at     date,
  status          text not null default 'open'
                  check (status in ('open','resolved','recurring','monitoring')),
  suspected_cause text,
  notes           text
);
create index if not exists health_log_person_date_idx on doctor_health_log (person, date desc);
create index if not exists health_log_type_status_idx on doctor_health_log (entry_type, status);

-- ---------------------------------------------------------------------------
-- Retention.
--
-- Lives here rather than in 003 because 003 is historical: its version deleted
-- from `jobs` and is superseded. Ingest used to write ~10k postings a night and
-- this existed to keep the 500 MB free tier out of reach; with job tracking gone
-- the database barely grows, but phase 2 still writes an engine_email_actions row per
-- thread every morning, so the trim stays. Phase 2 calls it at the end of its
-- sweep, since phase 1a -- its previous caller -- no longer runs.
--
-- Worth keeping from the note in 003: retention was never what bounded database
-- size. TOAST churn was, and `vacuum (full, analyze)` was the lever. Nothing
-- here rewrites 10k rows a night any more, so that problem is gone with it.
-- ---------------------------------------------------------------------------
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
  delete from engine_phase_runs where started_at < now() - interval '90 days';
  get diagnostics runs_deleted = row_count;

  delete from engine_email_actions where acted_at < now() - interval '90 days';
  get diagnostics actions_deleted = row_count;

  select pg_database_size(current_database()) into db_bytes;

  return jsonb_build_object(
    'phase_runs_deleted',    runs_deleted,
    'email_actions_deleted', actions_deleted,
    'db_bytes',              db_bytes,
    'db_pretty',             pg_size_pretty(db_bytes),
    -- Phase 3 paints a warning card when this is true.
    'over_threshold',        db_bytes > 350 * 1024 * 1024
  );
end;
$$;

revoke all on function public.prune_old_data() from public, anon, authenticated;
grant execute on function public.prune_old_data() to service_role;

-- ---------------------------------------------------------------------------
-- RLS on with no policies: only the service key reaches these tables, and the
-- service key lives in the routine connectors.
-- ---------------------------------------------------------------------------
alter table engine_phase_runs            enable row level security;
alter table accountant_accounts              enable row level security;
alter table accountant_transactions          enable row level security;
alter table engine_email_actions         enable row level security;
alter table engine_blocklist             enable row level security;
alter table engine_calendar_intents      enable row level security;
alter table accountant_wedding_vendors       enable row level security;
alter table doctor_nutrition_items       enable row level security;
alter table doctor_food_log              enable row level security;
alter table doctor_health_log            enable row level security;

-- ---------------------------------------------------------------------------
-- RLS with no policies denies reads, but it does not remove the table GRANTs
-- Supabase hands anon and authenticated by default. Those grants include INSERT,
-- UPDATE, DELETE and TRUNCATE -- so the day anyone adds a permissive policy to
-- one of these tables to make a read work, they also hand the public anon key
-- write access to it. Nothing here uses either role: there are no auth users, no
-- edge functions and no storage. Every phase connects as service_role.
-- ---------------------------------------------------------------------------
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

-- and stop tables created later from quietly re-acquiring them
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
