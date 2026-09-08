# Phase 3 — Present

Reads the tables and renders one page, ready before 8:30am. It replaces three
separate status emails that used to arrive in the inbox phase 2 is trying to
clean.

Holds `routine_3_artifact.md` and `template.html`.

## 3 — build the report · 8:00am PT

Read-only against the database apart from one narrow write: it drains the
renames and recategorizations he made on yesterday's page into the merchant
maps before it reads them. Publishes to a stable URL so the home-screen icon
never breaks, and is designed for a phone first because that is where it is
read.

Cards:

| Card | Source |
|---|---|
| Finances | `accountant_monthly` and `accountant_ledger`. Renders empty and says so until data exists |
| Over Time | The same transaction array as Finances, read as a line across every month |
| Email | `engine_email_actions` from today's sweep |
| Food | `doctor_food_log`, both people, last 7 days |
| Phase health | Newest `engine_phase_runs` row per phase |

## Edits made on the page

Tapping a transaction on the report opens a rename-and-categorize panel. What he
saves goes into the artifact's own db store, not into Postgres — the page has no
database credentials and should not have any. The 8:00am run drains that store
first thing, before it reads anything, so an edit made today is in the data
tomorrow and the row stops being marked *edited* on its own.

A merchant-scope edit writes the two merchant maps as well as the rows, which is
the point of those maps: name a merchant once and every future charge from it
arrives named and categorized with nobody looking at it.

## The part that matters most

**This phase never fails because another phase didn't run.**

It reads the newest `engine_phase_runs` row for each phase and renders accordingly:

- row says `ok` → show the data
- row says `ok` but nothing happened → *"nothing changed"*
- row is `failed` → say so, and show the last good data with its timestamp
- **no row at all** → *"did not run since 07:15 yesterday"*

That distinction is the whole reason the phases are separate folders and
separate schedules. Pausing phase 2 for a week should cost one card, not the
morning report.

Same rule for the data itself: an empty `accountant_transactions` table draws an empty
graph that says it is waiting for data. It does not draw nothing, and it does
not throw. Read money through the views rather than the base table, so a schema
change costs an afternoon rather than a broken morning — which is exactly what
the 2026-09-05 rebuild would have cost otherwise.

## Expect to edit this one

Phase 3 is the phase that changes constantly, because presentation preferences
are specific and only become clear once you are looking at the real thing. That
is fine — it reads the database and writes a page. Nothing else depends on it,
so it can be rewritten as often as it needs to be without touching anything
upstream.
