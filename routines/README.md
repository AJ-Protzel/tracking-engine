# Routine prompts

Phases 1b, 2, 2b, and 3 are not Python. They run as scheduled cloud sessions
that read this database and the Gmail, Drive, and Calendar connectors, and their
"source code" is a prompt.

Those prompts live here, in version control, rather than only inside the
scheduling service. In the previous system they existed nowhere else, which
meant a bad edit was unrecoverable and there was no record of what changed or
why. The file in this directory is the source of truth; the live routine is
updated from it.

| File | Phase | Fires | What it does |
|---|---|---|---|
| `p1b_score.md` | 1b | 6:30am PT, weekdays | Dispatches ingest, filters, scores, writes cover letters |
| `p2_email.md` | 2 | 7:15am PT, daily | Sweeps the inbox, records what it did, queues calendar intents |
| `p2b_calendar.md` | 2b | 7:45am PT, daily | Drains calendar intents into Google Calendar |
| `p3_artifact.md` | 3 | 8:00am PT, daily | Builds the morning artifact from the tables |

Empty until each phase is built. Build order is in the design doc: 1a, then 1b,
then 2 and 2b, then 3.

## Changing one

Edit the file here, commit, then paste it into the routine. Two things to keep
in mind:

- **Crons are fixed UTC.** Every time above is Pacific Daylight Time. All of
  them need a one-hour bump when Pacific goes to standard time in November.
- **Each phase must write a `phase_runs` row on every exit path**, including
  failure. Phase 3 tells "ran and did nothing" apart from "never ran" by
  reading that row, and that distinction is what lets any phase be paused
  without the morning report looking broken.
