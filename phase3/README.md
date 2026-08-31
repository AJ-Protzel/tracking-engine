# Phase 3 — Present

Reads the tables and renders one page, ready before 8:30am. It replaces three
separate status emails that used to arrive in the inbox phase 2 is trying to
clean.

Not built yet. Will hold `routine_3_artifact.md` and a page template.

## 3 — build the report · 8:00am PT

Read-only against the database. Publishes to a stable URL so the home-screen
icon never breaks, and is designed for a phone first because that is where it is
read.

Cards:

| Card | Source |
|---|---|
| Finances | `transactions`. Renders empty and says so until data exists |
| Jobs | `v_queue` — apply link, cover letter, plus high-fit jobs blocked on compounding |
| Email | `email_actions` from today's sweep |
| Food | `food_log`, both people, last 7 days |
| Phase health | Newest `phase_runs` row per phase |

## The part that matters most

**This phase never fails because another phase didn't run.**

It reads the newest `phase_runs` row for each phase and renders accordingly:

- row says `ok` → show the data
- row says `ok` but nothing happened → *"nothing changed"*
- row is `failed` → say so, and show the last good data with its timestamp
- **no row at all** → *"did not run since 07:15 yesterday"*

That distinction is the whole reason the phases are separate folders and
separate schedules. Pausing phase 2 for a week should cost one card, not the
morning report.

Same rule for the data itself: an empty `transactions` table draws an empty
graph that says it is waiting for data. It does not draw nothing, and it does
not throw.

## Expect to edit this one

Phase 3 is the phase that changes constantly, because presentation preferences
are specific and only become clear once you are looking at the real thing. That
is fine — it reads the database and writes a page. Nothing else depends on it,
so it can be rewritten as often as it needs to be without touching anything
upstream.
