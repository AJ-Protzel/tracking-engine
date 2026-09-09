-- 006 — accountant rebuilt around SimpleFIN
--
-- Applied to qarwswpnzignofrwdqye on 2026-09-05, but applied with raw SQL rather
-- than through apply_migration, so it appears in NEITHER Supabase's migration
-- history NOR this folder. This file is the record, written after the fact by
-- reading the live database on 2026-09-05.
--
-- Do not run it blind against a live database. It is here so the shape exists
-- somewhere versioned, and so 001 stops being the only description of
-- accountant_transactions -- which by then described columns that no longer
-- exist. Phase 3 was still selecting those columns; that is what this file is
-- meant to prevent next time.
--
-- What changed, and why:
--   Transactions come from SimpleFIN only. The email sweep's per-receipt insert
--   was removed the same day -- two feeds for one charge produce duplicates that
--   nothing reconciles. The old accountant_transactions was dropped and rebuilt,
--   taking its five email-sourced rows with it.

-- ---------------------------------------------------------------------------
-- accountant_transactions — 8 columns, down from 15
-- ---------------------------------------------------------------------------
-- Gone: name, merchant, direction, wedding, notes, created_at, superseded_by.
--
--   amount      is now SIGNED. Negative is money out, positive is money in, on
--               credit and debit alike. There is no direction column.
--   account_id  is now NOT NULL. Every row resolves to an account.
--   external_id is now NOT NULL and UNIQUE. It is the dedupe key.
--   wedding     is gone, and so is the wedding_vendors table it was derived
--               from -- both dropped 2026-09-05. Wedding spending is tracked by
--               hand outside this database now. accountant_wallet,
--               accountant_credit_cycles and the accountant_credits_available
--               view went in the same pass.

create table if not exists accountant_transactions (
  id          bigserial primary key,
  account_id  bigint not null references accountant_accounts (id),
  date        date not null,
  amount      numeric(12,2) not null,
  description text not null,
  category    text,
  source      text not null default 'simplefin',
  external_id text not null unique,
  constraint accountant_transactions_category_check check (category = any (array[
    'dining','grocery','shopping','utility','gas','travel','transfer','income','fee'])),
  -- 'email' is deliberately absent. The email sweep no longer writes here.
  constraint accountant_transactions_source_check check (source = any (array[
    'simplefin','csv','manual']))
);

create index if not exists accountant_transactions_date_idx     on accountant_transactions (date desc);
create index if not exists accountant_transactions_account_idx  on accountant_transactions (account_id, date desc);
create index if not exists accountant_transactions_category_idx on accountant_transactions (category);

-- ---------------------------------------------------------------------------
-- The merchant maps — keyed by merchant, not by charge
-- ---------------------------------------------------------------------------
-- This is the point of the redesign: categorize a merchant once and every future
-- charge from it lands categorized with nobody looking at it. Phase 2 fills
-- these from accountant_uncategorized each morning.

create table if not exists accountant_merchant_aliases (
  raw_pattern text primary key,   -- case-insensitive substring, longest wins
  clean_name  text not null
);

create table if not exists accountant_merchant_categories (
  clean_name text primary key,
  category   text not null,
  constraint accountant_merchant_categories_category_check check (category = any (array[
    'dining','grocery','shopping','utility','gas','travel','transfer','income','fee']))
);

-- accountant_accounts gained bank, type, simplefin_account_id; names shortened
-- because bank is its own column now. Ids 9-12 (Wealthfront, Fidelity) are
-- active = false and unlinked.
create unique index if not exists accountant_accounts_simplefin_account_id_key
  on accountant_accounts (simplefin_account_id) where simplefin_account_id is not null;

-- ---------------------------------------------------------------------------
-- accountant_clean_name — read this before writing an alias pattern
-- ---------------------------------------------------------------------------
-- The fallback is NOT the raw string. With no alias match it returns initcap()
-- of the text with [0-9#*] stripped and whitespace collapsed, and that is what
-- gets stored. So 'SQ *LA FIESTA TAQUERI 8005551234 CA' is stored as
-- 'Sq La Fiesta Taqueri Ca'.
--
-- Consequence: a raw_pattern containing a digit, * or # can never match a stored
-- description, because those characters were stripped before storage. The insert
-- succeeds and the row stays uncategorized forever. Patterns must be letters and
-- spaces only.

create or replace function accountant_clean_name(raw text) returns text
language sql stable as $$
  select coalesce(
    (select a.clean_name from accountant_merchant_aliases a
      where position(lower(a.raw_pattern) in lower(raw)) > 0
      order by length(a.raw_pattern) desc limit 1),
    initcap(regexp_replace(regexp_replace(raw, '[0-9#*]+', ' ', 'g'), '\s+', ' ', 'g'))
  );
$$;

-- accountant_ingest(rows jsonb) returns table(inserted int, skipped int)
-- The only sanctioned way to add transactions. Resolves description through the
-- alias map, applies the category map, and dedupes on external_id.
-- Body omitted here; read it from the live database with:
--   select prosrc from pg_proc where proname = 'accountant_ingest';

-- ---------------------------------------------------------------------------
-- Views — read money through these, never the base table
-- ---------------------------------------------------------------------------
-- accountant_ledger        id, bank, account, type, date, amount, category,
--                          description, wedding   (wedding derived, not stored)
-- accountant_monthly       month, category, net, spent, received, txns
--                          transfers excluded; null categories still counted
-- accountant_uncategorized description, txns, first_seen, last_seen
--                          the work queue phase 2 drains each morning
--
-- Definitions omitted; read them with:
--   select definition from pg_views where viewname like 'accountant%';

-- ---------------------------------------------------------------------------
-- NOT APPLIED — two gaps found 2026-09-05, both awaiting Adrien's decision
-- ---------------------------------------------------------------------------
-- 1. RLS did not survive the rebuild. accountant_transactions,
--    accountant_merchant_aliases, accountant_merchant_categories,
--    accountant_simplefin_accounts and accountant_sync_runs all have
--    relrowsecurity = false, against a project model of RLS-on-no-policies
--    everywhere else. No anon/authenticated table grants exist in public, so
--    these are not reachable through PostgREST today -- the exposure is one
--    forgotten grant away, not present. Defense in depth, not a live hole:
--
--      alter table accountant_transactions         enable row level security;
--      alter table accountant_merchant_aliases     enable row level security;
--      alter table accountant_merchant_categories  enable row level security;
--      alter table accountant_simplefin_accounts   enable row level security;
--      alter table accountant_sync_runs            enable row level security;
--
-- 2. accountant_ingest is SECURITY DEFINER and EXECUTE still defaults to PUBLIC,
--    so it is callable by anon at /rest/v1/rpc/accountant_ingest with the
--    publishable key. That bypasses RLS by design and lets anyone holding that
--    key insert transaction rows. Insert only -- it returns counts, not data --
--    so this is pollution, not exfiltration.
--
--    Checked 2026-09-05: accountant-simplefin-sweep builds its client with
--    SUPABASE_SERVICE_ROLE_KEY, so revoking anon/authenticated does not touch the
--    1pm sweep. Note the grant back to service_role -- EXECUTE defaults to
--    PUBLIC, and service_role holds it only THROUGH public, so a bare
--    "revoke from public" takes service_role with it and breaks the sweep. That
--    exact mistake was made once already on prune_old_data():
--
--      revoke execute on function accountant_ingest(jsonb) from public, anon, authenticated;
--      grant  execute on function accountant_ingest(jsonb) to service_role;
--
-- Both functions also carry a mutable search_path, which is the usual companion
-- warning to SECURITY DEFINER:
--   alter function accountant_clean_name(text) set search_path = public, pg_temp;
--   alter function accountant_ingest(jsonb)    set search_path = public, pg_temp;
