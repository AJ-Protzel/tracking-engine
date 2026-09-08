# Page — the morning report

**https://claude.ai/code/artifact/fb3d377a-c279-4b59-b182-2b90616d084d**

Private. It carries transactions, food entries and email subjects. Never share
it, and never publish it to a second URL.

## It updates itself

The page queries Supabase directly, through Adrien's own connector, every time
he opens it. No routine writes it. There is no daily render, no template to fill
and no republish.

That is the whole design, and two problems went away with it:

1. **Cost.** Rendering it used to mean reading a 68 KB template and ~2,000
   transactions into a model, then writing the entire page back out — tens of
   thousands of output tokens, every morning, to change a date and a handful of
   rows. Now it is zero: a connector call is not a model call.
2. **Drift.** Every design change he made on the page had to be backported into
   this repo or the next morning's run would flatten it. Since nothing
   regenerates the page, what he saves stays saved.

**So: never publish this artifact from a routine.** `sweep/routine.md` says the
same thing. A routine that republishes it would overwrite his edits and bring
back the cost — the two things this exists to prevent.

## How it works

Declared capabilities: `mcp` (the `Supabase` connector, `execute_sql` only) and
`db` (the artifact's own store).

Four watches, one per card, registered with `watchTool` so each refreshes on its
own and a failure is contained to the card it feeds:

| Card | Reads |
|---|---|
| Money, Over Time | `accountant_transactions`, every row |
| the `Synced` line | `max(ran_at)` from `accountant_phase_runs` |
| Nutrition | `doctor_food_log`, 7 days, both people |
| Requires Action | `engine_email_actions`, `engine_calendar_intents`, `engine_phase_runs` |

Card Credits is static markup, not daily data. The masthead date is computed in
the page.

### Everything degrades to something

The ~2,000 transactions embedded in `#txns` are the offline fallback and render
first; live rows replace them only when the query succeeds. `setRows` refuses an
empty list, so a connector that answers with nothing cannot blank the card.

Each connector error code gets its own message naming the one action that fixes
it — reconnect, add the connector, pick one. A single catch-all banner would
hide that, so do not collapse them.

An empty result is a legitimate answer (no food logged, nothing outstanding) and
is rendered as such, never as a failure.

### The store

Three collections in the artifact's own db store, all written by the page:

- `credits` — which card credits are ticked, and for which cycle
- `actions` — which Requires Action items have been dismissed
- `txn_edits` — a local record of every rename, and the retry queue

### Edits write straight to Postgres

Tapping a charge opens a rename-and-categorize panel. On save the page writes
the change to the database itself and marks its own record `applied`. A write
that fails stays unapplied and is retried on the next page load — the page
drains its own queue, so no routine has to.

`execute_sql` offers no parameter binding, so every value is escaped in the page
and the category is checked against the same nine the table's constraint allows;
a transaction id must be digits. Anything failing a check is not written.

Merchant-scope renames also upsert `accountant_merchant_aliases` and
`accountant_merchant_categories` so the next charge from that place arrives
named. `raw_pattern` has digits, `*` and `#` stripped first: `accountant_clean_name()`
strips them before storing, so a pattern containing any of them could never
match and would sit there doing nothing.

## template.html

A byte-for-byte copy of what is published, kept as a backup and as something to
read. It is **not** a build input — nothing renders from it any more.

If the two ever disagree, the published page wins; it is the one he uses. Copy
the live version back over this file rather than the other way around.

Publish updates with the Artifact tool, passing the URL above so it updates in
place, and pass no `favicon` and no `title` — a redeploy keeps them. Pass
`capabilities` **only** to change them, and when you do, restate the whole set:
a non-empty declaration revokes anything left out, which would take the card
ticks, the dismissals and the live data down together.
