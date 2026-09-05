# Phase 2 — Email

Sweeps the inbox, records what it did, and queues anything that belongs on a
calendar. Runs as a scheduled cloud session with the Gmail connector, so the
"source code" here is a prompt rather than Python.

Two files live here.

## 2 — email sweep · 7:15am PT · `routine_2_email.md`

Classifies every untouched thread into one of eight labels — Needs Response,
Jobs, Bills, Newsletters, Save, Flagged for Review, Money Out, Money In — across
the primary, promotions, social, and updates categories, plus one light pass
over spam to rescue obvious false positives. Drafts replies to personal mail
that wants one.

Two things it does that the old sweeper did not:

- **Money In / Money Out threads become `transactions` rows.** An interim feed
  until real account access exists. It only catches what emails a receipt, and
  the report says so rather than implying the picture is complete.
- **Threads with a real date and time become `calendar_intents` rows** for 2b.

Writes an `email_actions` row per thread, which is what makes the sweep
auditable after the fact, and one `phase_runs` row. Sends no email — the report
replaced the digest.

### Nothing labeled is ever auto-deleted

The previous version trashed Needs Response and Flagged for Review threads after
seven days. That is removed. Deleting a person's unanswered mail on a timer is
only correct until the one time it isn't.

Two automatic trash paths remain, both deliberate: senders marked `Blocked` in
the `blocklist` table, and newsletters trashed the same day after being
summarized.

## 2b — calendar drain · 7:45am PT · `routine_2b_calendar.md`

Reads pending `calendar_intents` and creates the events. Split from the sweep so
a calendar outage cannot take the inbox pass down with it — and so intents queue
harmlessly while the calendars don't exist yet.

Google Calendar, not iCloud: there is no iCloud connector, so Apple calendars
are unreachable. The calendars themselves (Work, Health, Holiday, Wedding,
Birthday, and a Claude fallback) have to be created by hand — the connector can
read and write events but cannot create a calendar.

Rules:

- Create an event only when a time is given. No time, no event.
- Always attach the address on a destination event.
- Leave a note on the event when time or location is missing.
- Route by content: doctor to Health, interview to Work.
- When nothing fits, use Claude.
- Mark the intent drained. Never create the same event twice.
