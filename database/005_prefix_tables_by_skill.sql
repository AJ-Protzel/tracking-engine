-- ---------------------------------------------------------------------------
-- Prefix every table with the thing that owns it (2026-09-04).
--
-- The point is not tidiness. A skill can now be told "you own every table named
-- doctor_*" instead of being handed a list, so adding a table later needs no
-- skill edit -- the skill discovers it. Enumerating table names in a skill
-- description is the thing that goes stale; a prefix rule does not.
--
--   doctor_*      the doctor skill: food, nutrition reference, health entries
--   accountant_*  the accountant skill: money, accounts, wedding vendors
--   engine_*      the pipeline itself. No skill owns these; phases 2, 2b and 3
--                 read and write them, and a skill should leave them alone.
--
-- Underscores, not spaces or hyphens: "doctor - food_log" is not a valid bare
-- identifier and would need double quotes in every statement forever. The
-- phases write SQL by hand every morning, and one forgotten quote is a failed
-- unattended run.
--
-- Ownership here means "which skill tracks this", not "who writes it".
-- accountant_transactions is written by phase 2's email sweep and only read by
-- the accountant; doctor_food_log is written by the doctor skill and read by
-- phase 3. The prefix answers "whose data is this", which is the question that
-- was actually being asked.
-- ---------------------------------------------------------------------------

alter table food_log        rename to doctor_food_log;
alter table nutrition_items rename to doctor_nutrition_items;
alter table health_log      rename to doctor_health_log;

alter table transactions    rename to accountant_transactions;
alter table accounts        rename to accountant_accounts;
alter table wedding_vendors rename to accountant_wedding_vendors;

alter table phase_runs       rename to engine_phase_runs;
alter table email_actions    rename to engine_email_actions;
alter table blocklist        rename to engine_blocklist;
alter table calendar_intents rename to engine_calendar_intents;

-- Indexes and constraints follow their table automatically but keep their old
-- names, which leaves the schema reading half-migrated. Metadata-only, no
-- rewrite, no meaningful lock.
alter index food_log_pkey                rename to doctor_food_log_pkey;
alter index food_log_date_idx            rename to doctor_food_log_date_idx;
alter index nutrition_items_pkey         rename to doctor_nutrition_items_pkey;
alter index health_log_pkey              rename to doctor_health_log_pkey;
alter index health_log_person_date_idx   rename to doctor_health_log_person_date_idx;
alter index health_log_type_status_idx   rename to doctor_health_log_type_status_idx;

alter index transactions_pkey            rename to accountant_transactions_pkey;
alter index transactions_date_idx        rename to accountant_transactions_date_idx;
alter index transactions_external_id_key rename to accountant_transactions_external_id_key;
alter index accounts_pkey                rename to accountant_accounts_pkey;
alter index accounts_name_key            rename to accountant_accounts_name_key;
alter index wedding_vendors_pkey         rename to accountant_wedding_vendors_pkey;

alter index phase_runs_pkey              rename to engine_phase_runs_pkey;
alter index phase_runs_phase_started_idx rename to engine_phase_runs_phase_started_idx;
alter index email_actions_pkey           rename to engine_email_actions_pkey;
alter index email_actions_acted_idx      rename to engine_email_actions_acted_idx;
alter index email_actions_run_id_idx     rename to engine_email_actions_run_id_idx;
alter index blocklist_pkey               rename to engine_blocklist_pkey;
alter index calendar_intents_pkey        rename to engine_calendar_intents_pkey;
alter index calendar_intents_gmail_thread_id_title_starts_at_key
                                         rename to engine_calendar_intents_thread_title_start_key;

-- ---------------------------------------------------------------------------
-- THE TRAP IN THIS MIGRATION.
--
-- A plpgsql body is stored as text and is not resolved until the function runs,
-- so `alter table ... rename` does NOT reach inside it. prune_old_data() still
-- said `delete from phase_runs` after every rename above succeeded, and would
-- have failed silently at the end of the next sweep -- long after this migration
-- looked like it worked. Recreating it is part of the rename, not a follow-up.
--
-- The same applies to any view, trigger function, or policy added later.
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
    'over_threshold',        db_bytes > 350 * 1024 * 1024
  );
end;
$$;

revoke all on function public.prune_old_data() from public, anon, authenticated;
grant execute on function public.prune_old_data() to service_role;
