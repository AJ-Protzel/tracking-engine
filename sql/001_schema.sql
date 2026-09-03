-- ---------------------------------------------------------------------------
-- tracking-engine schema
--
-- The full current shape of the Tracking-Engine Supabase project. Running this
-- against an empty database reproduces the system; 002 is the one-time move
-- from the old apply-engine layout and is not needed for a fresh install.
--
-- Design notes worth knowing before changing anything:
--   * jobs is append-mostly during a posting's life; last_seen_at tracks whether
--     it is still live. Retention (003) eventually removes postings that went
--     stale without ever being scored.
--   * There is deliberately no `raw` payload column. It once held 228 MB of a
--     252 MB database -- 90% of the free tier -- for data nothing read.
--     Descriptions are stored as text, capped at 4,000 characters.
--   * job_filters.kill_rule is the tuning mechanism. Every rejection records
--     WHICH rule rejected it, so false-positive rates are measurable instead of
--     anecdotal. Do not "clean up" by dropping rejected rows.
--   * job_scores keeps history for jobs that never queued. Same reason.
-- ---------------------------------------------------------------------------

-- companies we poll
create table if not exists companies (
  id          bigserial primary key,
  name        text not null,
  ats         text not null check (ats in ('greenhouse','lever','ashby','workable','recruitee')),
  slug        text not null,
  tier        int  not null default 2,      -- 1 = check first, 3 = long tail
  active      bool not null default true,
  last_ok_at  timestamptz,
  fail_count  int  not null default 0,
  unique (ats, slug)
);

-- every posting we've ever seen
create table if not exists jobs (
  id              bigserial primary key,
  source          text not null,             -- 'greenhouse' | 'adzuna' | 'usajobs' | ...
  source_job_id   text not null,
  company         text not null,
  title           text not null,
  location_raw    text,
  region          text,                      -- 'remote-us' | 'ca-norcal' | 'ca-other' | 'wa' | 'other'
  employment_type text,                      -- 'full_time' | 'contract' | 'c2h' | 'part_time' | 'intern'
  salary_min      int,
  salary_max      int,
  description     text,
  apply_url       text not null,
  posted_at       timestamptz,
  first_seen_at   timestamptz not null default now(),
  last_seen_at    timestamptz not null default now(),
  unique (source, source_job_id)
);
create index if not exists jobs_first_seen_idx on jobs (first_seen_at desc);
create index if not exists jobs_company_title_idx on jobs (company, title);

-- Cross-source dedupe -- the same posting appearing on Greenhouse and on an
-- aggregator under different ids -- is resolved in Python by normalize.dedupe()
-- before the upsert runs, so there is deliberately no index for it here. The
-- uniqueness the database enforces is the (source, source_job_id) constraint
-- above. An index on lower(company)/lower(title)/lower(location) existed until
-- 2026-09-03 and was dropped after never being scanned once: it cost 1.6 MB and
-- write amplification on ~10k nightly upserts to answer a question nothing asks.

-- hard-filter outcome, written by ingest
create table if not exists job_filters (
  job_id      bigint primary key references jobs(id) on delete cascade,
  passed      bool not null,
  kill_rule   text,                           -- which rule killed it, for tuning
  filtered_at timestamptz not null default now()
);
create index if not exists job_filters_kill_rule_idx on job_filters (kill_rule)
  where kill_rule is not null;

-- LLM score, written by the daily scheduled task
create table if not exists job_scores (
  job_id       bigint primary key references jobs(id) on delete cascade,
  fit          int  not null check (fit between 1 and 10),
  compounding  int  not null check (compounding between 1 and 5),
  title_bucket text,                          -- 'analytics_eng' | 'data_analyst' | ...
  verdict      text not null,                 -- one sentence, shown in the digest
  builds       text,                          -- what the role adds to the resume
  concerns     text,
  soft_flags   text[],
  scored_at    timestamptz not null default now(),
  model        text
);

-- ---------------------------------------------------------------------------
-- Recruiter conflict guard.
--
-- If a staffing agency has submitted Adrien to an employer, applying directly
-- to that employer typically disqualifies him outright, and some employers
-- impose a 6-12 month blackout across the whole company. This table is
-- maintained BY HAND on purpose: a manual insert is the right amount of
-- friction for something this consequential, and there is no reliable way to
-- detect a submission automatically.
--
-- Add a row right after a recruiter call:
--   insert into recruiter_submissions (client_name, agency, role_title, submitted_at)
--   values ('Blue Shield of California', 'TEKsystems', 'Reporting Analyst', current_date);
-- ---------------------------------------------------------------------------
create table if not exists recruiter_submissions (
  id            bigserial primary key,
  client_name   text not null,          -- the EMPLOYER, not the agency
  client_domain text,                   -- optional, improves matching
  agency        text not null,          -- e.g. 'TEKsystems'
  recruiter     text,
  role_title    text,
  submitted_at  date not null,
  expires_at    date,                   -- defaults to submitted_at + 180 days
  active        bool not null default true,
  notes         text
);
create index if not exists recruiter_submissions_client_idx
  on recruiter_submissions (lower(client_name));

create or replace function set_recruiter_submission_expiry()
returns trigger language plpgsql as $$
begin
  if new.expires_at is null then
    new.expires_at := new.submitted_at + interval '180 days';
  end if;
  return new;
end;
$$;

drop trigger if exists recruiter_submissions_expiry on recruiter_submissions;
create trigger recruiter_submissions_expiry
  before insert on recruiter_submissions
  for each row execute function set_recruiter_submission_expiry();

-- the queue and its afterlife
create table if not exists applications (
  id              bigserial primary key,
  job_id          bigint not null unique references jobs(id) on delete cascade,
  status          text not null default 'queued'
                  check (status in ('queued','skipped','applied','screen','interview','offer','rejected','ghosted')),
  skip_reason     text,                       -- e.g. 'recruiter_conflict: TEKsystems 2026-08-14'
  queued_at       timestamptz not null default now(),
  applied_at      timestamptz,
  resume_url      text,                       -- Google Drive link
  cover_url       text,
  last_contact_at timestamptz,
  notes           text
);
create index if not exists applications_status_idx on applications (status);

-- replies detected in Gmail
create table if not exists email_events (
  id              bigserial primary key,
  application_id  bigint references applications(id) on delete cascade,
  gmail_thread_id text not null unique,
  classified_as   text not null check (classified_as in ('rejection','screen','interview','offer','other')),
  subject         text,
  received_at     timestamptz not null
);

-- ---------------------------------------------------------------------------
-- Phase telemetry.
--
-- One row per phase per run. Phase 3 reads the newest row for each phase to
-- decide whether a card says "nothing changed" or "did not run" -- which is
-- what lets any phase be paused without the morning report looking broken.
-- ---------------------------------------------------------------------------
create table if not exists phase_runs (
  id          bigserial primary key,
  phase       text not null check (phase in ('1a','1b','2','2b','3')),
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  status      text not null default 'running'
              check (status in ('running','ok','failed','skipped')),
  counts      jsonb not null default '{}'::jsonb,
  summary     jsonb,
  error       text
);
create index if not exists phase_runs_phase_started_idx
  on phase_runs (phase, started_at desc);

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------

-- Columns are listed rather than j.*: an expanded star pins every column into
-- the view definition, which is what blocked dropping jobs.raw.
-- security_invoker: without it a view runs as its owner (postgres, which has
-- BYPASSRLS), so it reads straight past the RLS that protects every base table
-- below. These two views were the only way the anon key could read this data
-- until 2026-09-03. Any view added here needs this too.
create or replace view v_queue with (security_invoker = true) as
  select a.id as application_id, a.status, a.cover_url, a.queued_at,
         j.id, j.source, j.source_job_id, j.company, j.title, j.location_raw,
         j.region, j.employment_type, j.salary_min, j.salary_max, j.description,
         j.apply_url, j.posted_at, j.first_seen_at, j.last_seen_at,
         s.fit, s.compounding, s.verdict,
         s.builds, s.concerns, s.title_bucket
  from applications a
  join jobs j       on j.id = a.job_id
  join job_scores s on s.job_id = j.id
  where a.status = 'queued'
  order by s.fit desc, j.first_seen_at desc;

-- The same queue plus a staleness flag. A posting the nightly ingest has not
-- re-seen in 7 days is probably closed, so phase 3 retires it rather than
-- surfacing an apply link that 404s.
-- Columns listed rather than q.*, for the same reason as v_queue above.
create or replace view v_queue_live with (security_invoker = true) as
  select q.application_id, q.status, q.cover_url, q.queued_at,
         q.id, q.source, q.source_job_id, q.company, q.title, q.location_raw,
         q.region, q.employment_type, q.salary_min, q.salary_max, q.description,
         q.apply_url, q.posted_at, q.first_seen_at, q.last_seen_at,
         q.fit, q.compounding, q.verdict, q.builds, q.concerns, q.title_bucket,
         j.last_seen_at as seen_at,
         (now() - j.last_seen_at) > interval '7 days' as likely_closed
  from v_queue q
  join jobs j on j.id = q.id;

-- Employers currently owned by an agency. The filter reads this, not the base
-- table, so expiry and deactivation are handled in one place.
create or replace view v_blocked_employers with (security_invoker = true) as
  select lower(client_name) as client_key, client_name, client_domain,
         agency, role_title, submitted_at, expires_at
  from recruiter_submissions
  where active = true
    and (expires_at is null or expires_at >= current_date);


-- ---------------------------------------------------------------------------
-- Phase 2 and 3 tables.
-- ---------------------------------------------------------------------------

-- Account names only. No card or account numbers, ever.
create table if not exists accounts (
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
create table if not exists transactions (
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
create index if not exists transactions_date_idx on transactions (date desc);

-- What phase 2 did, per thread. Feeds the artifact's email card and makes the
-- sweep auditable after the fact.
create table if not exists email_actions (
  id              bigserial primary key,
  run_id          bigint references phase_runs(id) on delete set null,
  gmail_thread_id text not null,
  action          text not null
                  check (action in ('labeled','drafted','trashed','spam_rescued','blocked','skipped')),
  label           text,
  subject_snippet text,
  note            text,                       -- newsletter gist, draft From address
  acted_at        timestamptz not null default now()
);
create index if not exists email_actions_acted_idx on email_actions (acted_at desc);
-- prune_old_data() deletes aged phase_runs rows, and each delete forces an FK
-- recheck against this table. Cheap to carry, and this table only grows.
create index if not exists email_actions_run_id_idx on email_actions (run_id);

-- Senders to watch or trash on sight. Lifted out of a Google Drive CSV so that
-- no phase depends on a file that can be moved, renamed, or half-written.
create table if not exists blocklist (
  sender_email text primary key,
  trash_dates  date[] not null default '{}',
  status       text not null default 'Watching' check (status in ('Watching','Blocked')),
  blocked_date date,
  updated_at   timestamptz not null default now()
);

-- Phase 2 writes the intent; phase 2b creates the calendar event. Split so a
-- calendar outage cannot take the email sweep down with it, and so intents
-- queue harmlessly until the Google calendars exist.
create table if not exists calendar_intents (
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
create table if not exists wedding_vendors (
  name       text primary key,
  note       text,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Food tracking, moved in from the separate Food-Tracker project so one
-- database backs the whole morning report. Shapes are unchanged.
-- ---------------------------------------------------------------------------
create table if not exists nutrition_items (
  id        uuid primary key default gen_random_uuid(),
  item      text not null,
  serving   text not null,
  calories  numeric,
  protein_g numeric,
  carbs_g   numeric,
  fat_g     numeric,
  sugar_g   numeric
);

create table if not exists food_log (
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
create index if not exists food_log_date_idx on food_log (date desc);

-- Symptoms, vitals, medications and events, one row per entry. Read and written
-- by the doctor skill, which also owns food_log and nutrition_items above.
create table if not exists health_log (
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
create index if not exists health_log_person_date_idx on health_log (person, date desc);
create index if not exists health_log_type_status_idx on health_log (entry_type, status);

-- ---------------------------------------------------------------------------
-- RLS on with no policies: only the service key reaches these tables, and the
-- service key lives in GitHub Actions secrets and the routine connectors.
-- ---------------------------------------------------------------------------
alter table companies             enable row level security;
alter table jobs                  enable row level security;
alter table job_filters           enable row level security;
alter table job_scores            enable row level security;
alter table recruiter_submissions enable row level security;
alter table applications          enable row level security;
alter table email_events          enable row level security;
alter table phase_runs            enable row level security;
alter table accounts              enable row level security;
alter table transactions          enable row level security;
alter table email_actions         enable row level security;
alter table blocklist             enable row level security;
alter table calendar_intents      enable row level security;
alter table wedding_vendors       enable row level security;
alter table nutrition_items       enable row level security;
alter table food_log              enable row level security;
alter table health_log            enable row level security;

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
