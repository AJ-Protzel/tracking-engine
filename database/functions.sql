-- The three functions, exactly as the live database holds them.
--
-- Generated 2026-09-09 with pg_get_functiondef, not written by hand, so this is
-- the real source rather than a copy that drifted. Regenerate the same way:
--
--   select string_agg(pg_get_functiondef(p.oid), E';\n\n' order by p.proname)
--     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public';
--
-- This is the one part of the schema that could not be reconstructed from
-- SCHEMA.md if it were lost. Tables and constraints are described there in
-- prose; logic has to be kept as logic.
--
-- Every definition is CREATE OR REPLACE, so running this file against the live
-- database is safe and idempotent.

CREATE OR REPLACE FUNCTION public.accountant_clean_name(raw text)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce(
    (select a.clean_name from accountant_merchant_aliases a
      where position(lower(a.raw_pattern) in lower(raw)) > 0
      order by length(a.raw_pattern) desc limit 1),
    initcap(regexp_replace(regexp_replace(raw, '[0-9#*]+', ' ', 'g'), '\s+', ' ', 'g'))
  );
$function$
;

CREATE OR REPLACE FUNCTION public.accountant_ingest(rows jsonb)
 RETURNS TABLE(inserted integer, skipped integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare ins int := 0; skp int := 0;
begin
  with incoming as (
    select
      (r->>'account_id')::bigint                as account_id,
      (r->>'date')::date                        as date,
      (r->>'amount')::numeric(12,2)             as amount,
      accountant_clean_name(r->>'description')  as description,
      coalesce(r->>'source','simplefin')        as source,
      r->>'external_id'                         as external_id
    from jsonb_array_elements(rows) as r
  ),
  ready as (
    select i.*, c.category
    from incoming i
    left join accountant_merchant_categories c on c.clean_name = i.description
  ),
  done as (
    insert into accountant_transactions
      (account_id, date, amount, description, category, source, external_id)
    select account_id, date, amount, description, category, source, external_id
    from ready
    on conflict (external_id) do nothing
    returning 1
  )
  select count(*)::int into ins from done;
  select (jsonb_array_length(rows) - ins)::int into skp;
  return query select ins, skp;
end $function$
;

CREATE OR REPLACE FUNCTION public.prune_old_data()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;
