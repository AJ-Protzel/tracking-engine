-- 008 -- per-account staleness threshold
--
-- Applied to qarwswpnzignofrwdqye on 2026-09-06.
--
-- The health check added in 007 used a flat 3 days and flagged five of eight
-- accounts on its first real run. Three of those were correct behaviour, not
-- broken feeds: Adrien does not use BofA Customized Cash or Chase Freedom
-- Unlimited at all, and AmEx Platinum only sees the occasional autopay. A check
-- that fires every morning on accounts that are fine is a check nobody reads.
--
-- So the threshold is a property of the account. Update the number when an
-- account goes dormant or comes back into use; no code change is needed.

alter table accountant_accounts
  add column if not exists expected_idle_days integer not null default 3;

comment on column accountant_accounts.expected_idle_days is
  'Days this account can go with no transactions before the sweep flags it. Low-use accounts get a longer leash; a card in daily use should stay at 3.';

update accountant_accounts set expected_idle_days = 60 where id in (2, 3);      -- Freedom Unlimited, BofA Customized Cash: not in use
update accountant_accounts set expected_idle_days = 35 where id = 4;            -- AmEx Platinum: occasional autopays only
update accountant_accounts set expected_idle_days = 14 where id = 7;            -- AmEx Checking: ~13 transactions per quarter
update accountant_accounts set expected_idle_days = 5  where id in (1, 5, 6, 8);-- daily drivers; 3 flags a normal long weekend

-- The view carries the comparison so the edge function does not hardcode a
-- number. Dropped and recreated rather than replaced: `create or replace view`
-- cannot insert a column in the middle of the existing column list.
drop view if exists accountant_account_watermarks;

create view accountant_account_watermarks
with (security_invoker = on) as
select a.id  as account_id,
       a.bank,
       a.name as account,
       a.active,
       (a.simplefin_account_id is not null) as linked,
       count(t.id)                  as txns,
       max(t.date)                  as last_txn,
       (current_date - max(t.date)) as days_stale,
       a.expected_idle_days,
       (a.simplefin_account_id is not null
        and a.active
        and (max(t.date) is null
             or (current_date - max(t.date)) > a.expected_idle_days)) as stale
  from accountant_accounts a
  left join accountant_transactions t on t.account_id = a.id
 group by a.id, a.bank, a.name, a.active, a.simplefin_account_id, a.expected_idle_days
 order by a.id;

-- Verified after: sweep v5 returned stale: [] and errors: [] on a 28-day window.
