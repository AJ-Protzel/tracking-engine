# Sweep — the only scheduled Claude session

`routine.md` is the prompt. The cloud routine named **Tracking Engine Sweep**
fetches it from raw.githubusercontent.com at run time and follows everything
after the first `---`, so editing that file and pushing changes live behavior on
the next run. There is nothing to paste into the scheduler.

| | |
|---|---|
| Runs | 1:00am PT — cron `0 8 * * *` UTC |
| Prompt | `sweep/routine.md` |
| Writes | `engine_email_actions`, `engine_blocklist`, `engine_calendar_intents`, `engine_phase_runs` |
| Reads | Gmail, Google Calendar |
| Uses | the `secretary` skill for all email judgment |

## Why there is exactly one

This was three routines until 2026-09-08: an email sweep at 7:15am, a calendar
drain at 7:45am, and a page build at 8:00am. Each one paid for its own session
boot, its own connector setup, and its own run row.

The calendar drain existed because it was a separate session, and a calendar
failure should not take the inbox pass down with it. Inside one session that is
a `try`/`catch`, not a table and a second routine. The page build existed
because a model had to render the page; it no longer does — see `page/README.md`.

So the rule this repo now runs on:

> **Schedule only what arrives whether or not he asks.**

Bank transactions arrive. Email arrives. Everything else — food, health,
merchant categorization, tutoring — he initiates in a chat with the skill that
owns it, and needs no schedule at all. By that rule exactly two things are
scheduled: the SimpleFIN edge function, and this.

Adding a third is the thing to argue hardest against.

## Why it uses the secretary skill

The `secretary` skill already defines how Adrien's mail is handled: the label
map, what each label means, which calendar an event belongs on, his voice. He
uses it conversationally all day.

Before, `routine_2_email.md` restated all of that inline. Two definitions of one
job, free to drift, with nothing to say when they did.

Now the split is:

- **Skill = domain knowledge.** What the labels mean, how to route, how he
  writes. True whether the sweep runs it at 1am or he asks at 2pm.
- **Routine = execution contract.** Open a run row, caps, retry limits, batch
  the inserts, do not ask questions, close the run row. Only meaningful
  unattended, and clutter inside a skill.

The skill is managed on claude.ai, not in this repo, so it is not editable from
a clone. Change it where it lives.

## The 1am tradeoff, on purpose

The sweep covers yesterday's mail, and mail arriving between 1am and when Adrien
wakes is swept the next night. He chose that: it puts the run at the far end of
his usage window rather than thirty minutes before he reads the page.

The page does not care — it queries live, so it always shows the current state
of the database no matter when the sweep last ran.
