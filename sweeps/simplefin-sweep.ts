// accountant-simplefin-sweep — the only writer of accountant_transactions.
//
// Deployed as a Supabase edge function on project qarwswpnzignofrwdqye. No
// Claude routine touches the accountant tables; this function loads them, the
// `accountant` skill curates them on demand, and phase 3 reads the views.
//
// Modes
//   dry_run  — fetch a short window, map it, write nothing but a run row.
//   sweep    — the daily job. Window derived from the oldest per-account
//              watermark minus 5 days, clamped to [14, 90] days. One request.
//   backfill — manual, resumable. Walks 90-day windows backwards from a stored
//              cursor, capped per run, stopping after two empty windows.
//
// SimpleFIN's limit is on the span of ONE request (90 days), not on total
// history, so backdated windows reach further back than the daily sweep can.
// Budget is 24 requests/day, so the per-run cap matters.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const PACIFIC = "America/Los_Angeles";
const DAY = 86400;
const MAX_WINDOW_DAYS = 90;   // SimpleFIN's per-request span limit
const SWEEP_LOOKBACK_PAD = 5; // re-pull this many days behind the watermark
const SWEEP_MIN_DAYS = 14;
// Pending charges are carried. Excluding them held the table two to three days
// behind every card, which read as a dead feed rather than the settlement lag
// it was. They are provisional — the amount can move, and some never settle —
// so a pending row stays rewritable and a settled one does not.
const BACKFILL_FLOOR = "2019-01-01";
const BACKFILL_DEFAULT_WINDOWS = 6;
const BACKFILL_MAX_WINDOWS = 20;
const EMPTY_WINDOWS_TO_STOP = 2;

const pacificDate = (unix: number) =>
  new Date(unix * 1000).toLocaleDateString("en-CA", { timeZone: PACIFIC });
const toUnix = (iso: string) => Math.floor(Date.parse(iso + "T00:00:00Z") / 1000);
const toISO = (unix: number) => new Date(unix * 1000).toISOString().slice(0, 10);
const todayPacific = () => new Date().toLocaleDateString("en-CA", { timeZone: PACIFIC });

function splitAccessUrl(raw: string) {
  const u = new URL(raw.trim());
  const auth = btoa(decodeURIComponent(u.username) + ":" + decodeURIComponent(u.password));
  u.username = ""; u.password = "";
  return { base: u.toString().replace(/\/$/, ""), auth };
}

type Window = { start: number; end: number | null };

async function fetchWindow(base: string, auth: string, w: Window) {
  const qs = new URLSearchParams({ "start-date": String(w.start), pending: "1" });
  if (w.end !== null) qs.set("end-date", String(w.end));
  const res = await fetch(base + "/accounts?" + qs.toString(), {
    headers: { Authorization: "Basic " + auth },
  });
  if (!res.ok) {
    throw new Error("SimpleFIN " + res.status + ": " + (await res.text()).slice(0, 300));
  }
  return await res.json();
}

// v1 sends `errors` + account.org; v2 sends `errlist` + connections. Handle both.
function feedErrorsOf(payload: any): string[] {
  return [
    ...(Array.isArray(payload?.errors) ? payload.errors.map(String) : []),
    ...(Array.isArray(payload?.errlist)
      ? payload.errlist.map((e: any) =>
          typeof e === "string" ? e : String(e.code) + ": " + String(e.msg))
      : []),
  ];
}

function mapRows(payload: any, byExternal: Map<string, any>) {
  const connById = new Map<string, string>(
    (payload?.connections ?? []).map((c: any) => [String(c.conn_id), c.name ?? c.org_name ?? ""]));
  const accounts: any[] = Array.isArray(payload?.accounts) ? payload.accounts : [];
  const orgOf = (a: any) =>
    a?.org?.name ?? a?.org?.domain ?? connById.get(String(a?.conn_id)) ?? null;

  const rows: any[] = [];
  const unmapped: string[] = [];
  let txnsSeen = 0;

  for (const a of accounts) {
    const txns = Array.isArray(a.transactions) ? a.transactions : [];
    txnsSeen += txns.length;
    const acct = byExternal.get(String(a.id));
    if (!acct) {
      unmapped.push((orgOf(a) ?? "?") + " / " + (a?.name ?? "?") + " [" + a.id + "]");
      continue;
    }
    for (const t of txns) {
      const amt = Number(t.amount);
      if (!isFinite(amt) || amt === 0) continue;
      const pending = !!t.pending;
      // `posted` is 0 until a charge settles, and pacificDate(0) is 1969.
      // transacted_at is when it actually happened, which is the date he
      // recognises anyway.
      const when = Number(t.posted) || Number(t.transacted_at) || 0;
      if (!when) continue;
      rows.push({
        account_id: acct.id,
        date: pacificDate(when),
        amount: amt,                       // already signed: - out, + in
        description: String(t.description ?? "").trim(),
        source: "simplefin",
        external_id: "simplefin:" + t.id,
        pending,
      });
    }
  }
  return { rows, unmapped, txnsSeen, accountsSeen: accounts.length };
}

async function ingest(db: any, rows: any[]) {
  let inserted = 0, skipped = 0;
  const errors: string[] = [];
  for (let i = 0; i < rows.length; i += 200) {
    const { data, error } = await db.rpc("accountant_ingest", { rows: rows.slice(i, i + 200) });
    if (error) errors.push(error.message);
    else if (data?.[0]) { inserted += data[0].inserted ?? 0; skipped += data[0].skipped ?? 0; }
  }
  return { inserted, skipped, errors };
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body, null, 2),
    { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req: Request) => {
  const started = Date.now();
  const qs = new URL(req.url).searchParams;
  let body: any = {};
  try { body = (await req.json()) ?? {}; } catch (_) { /* no body */ }

  const param = (k: string) => qs.get(k) ?? (body?.[k] != null ? String(body[k]) : null);
  const mode = param("mode") ?? "sweep";
  if (!["dry_run", "backfill", "sweep"].includes(mode)) {
    return json({ error: "unknown mode: " + mode }, 400);
  }

  const accessUrl = Deno.env.get("SIMPLEFIN_ACCESS_URL");
  if (!accessUrl) return json({ error: "SIMPLEFIN_ACCESS_URL not set" }, 500);

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );

  const { base, auth } = splitAccessUrl(accessUrl);

  const { data: mapped } = await db.from("accountant_accounts")
    .select("id, bank, name, simplefin_account_id")
    .not("simplefin_account_id", "is", null);
  const byExternal = new Map<string, any>(
    (mapped ?? []).map((r: any) => [r.simplefin_account_id, r]));

  const { data: marks } = await db.from("accountant_account_watermarks")
    .select("account_id, bank, account, active, linked, txns, last_txn");
  const linked = (marks ?? []).filter((m: any) => m.linked && m.active);

  const fail = async (msg: string, note: string) => {
    await db.from("accountant_phase_runs").insert({ mode, errors: [msg], note });
    return json({ error: msg }, 502);
  };

  // ---------------------------------------------------------------- dry_run
  if (mode === "dry_run") {
    const days = Number(param("days") ?? 7);
    const w: Window = { start: Math.floor(Date.now() / 1000) - days * DAY, end: null };
    let payload: any;
    try { payload = await fetchWindow(base, auth, w); }
    catch (e) { return await fail(String((e as any)?.message ?? e), "fetch failed"); }

    const feedErrors = feedErrorsOf(payload);
    const { rows, unmapped, txnsSeen, accountsSeen } = mapRows(payload, byExternal);

    await db.from("accountant_phase_runs").insert({
      mode, accounts_seen: accountsSeen, txns_seen: txnsSeen,
      rows_inserted: 0, rows_skipped: rows.length,
      errors: feedErrors.length ? feedErrors : null,
      note: "dry run, " + days + "d window, wrote nothing to accountant_transactions",
    });
    return json({
      mode, days, window: { from: toISO(w.start), to: "now" },
      accounts_seen: accountsSeen, txns_seen: txnsSeen, candidates: rows.length,
      unmapped, feed_errors: feedErrors, sample: rows.slice(0, 10),
      ms: Date.now() - started,
    });
  }

  // ------------------------------------------------------------------ sweep
  if (mode === "sweep") {
    // Window comes from the oldest per-account watermark, not a fixed 24h, so
    // an account whose bank posted late still gets picked up. One request
    // covers every account, so the OLDEST watermark sets the window for all.
    const today = toUnix(todayPacific());
    const withTxns = linked.filter((m: any) => m.last_txn);
    const anyEmpty = linked.length !== withTxns.length;

    let days: number;
    let basis: string;
    if (anyEmpty || withTxns.length === 0) {
      days = MAX_WINDOW_DAYS;
      basis = "at least one linked account has no transactions yet";
    } else {
      const oldest = withTxns
        .map((m: any) => toUnix(m.last_txn))
        .reduce((a: number, b: number) => Math.min(a, b));
      const raw = Math.ceil((today - oldest) / DAY) + SWEEP_LOOKBACK_PAD;
      days = Math.min(MAX_WINDOW_DAYS, Math.max(SWEEP_MIN_DAYS, raw));
      basis = "oldest watermark " + toISO(oldest) + " + " + SWEEP_LOOKBACK_PAD + "d pad";
    }

    const w: Window = { start: today - days * DAY, end: null };
    let payload: any;
    try { payload = await fetchWindow(base, auth, w); }
    catch (e) { return await fail(String((e as any)?.message ?? e), "fetch failed"); }

    const errors = feedErrorsOf(payload);
    const { rows, unmapped, txnsSeen, accountsSeen } = mapRows(payload, byExternal);
    const ing = await ingest(db, rows);
    errors.push(...ing.errors);
    if (unmapped.length) errors.push("unmapped accounts skipped: " + unmapped.join(", "));

    // A pending charge the bank has dropped never settles. Anything still
    // pending inside the window just covered, that the feed no longer lists,
    // is deleted — so the table matches what the bank says right now.
    const keep = rows.filter((r: any) => r.pending).map((r: any) => r.external_id);
    const { data: pruned, error: pruneErr } = await db.rpc("accountant_prune_pending", {
      since: toISO(w.start), keep,
    });
    if (pruneErr) errors.push("prune pending: " + pruneErr.message);

    await db.from("accountant_phase_runs").insert({
      mode, accounts_seen: accountsSeen, txns_seen: txnsSeen,
      rows_inserted: ing.inserted, rows_skipped: ing.skipped,
      errors: errors.length ? errors : null,
      note: days + "d window (" + basis + ")",
    });

    return json({
      mode, days, basis, window: { from: toISO(w.start), to: "now" },
      accounts_seen: accountsSeen, txns_seen: txnsSeen, candidates: rows.length,
      inserted: ing.inserted, skipped: ing.skipped,
      pending: keep.length, pending_dropped: pruned ?? 0, errors,
      ms: Date.now() - started,
    });
  }

  // --------------------------------------------------------------- backfill
  // Resumable. State lives in accountant_backfill_state (single row, id = 1).
  const reset = param("reset") === "true";
  const from = param("from");
  const maxWindows = Math.min(BACKFILL_MAX_WINDOWS,
    Math.max(1, Number(param("windows") ?? BACKFILL_DEFAULT_WINDOWS)));

  const { data: stateRows } = await db.from("accountant_backfill_state")
    .select("*").eq("id", 1);
  let state: any = stateRows?.[0];
  if (!state) {
    state = { id: 1, cursor_end: todayPacific(), windows_done: 0,
              requests_made: 0, rows_inserted: 0, exhausted: false };
    await db.from("accountant_backfill_state").insert(state);
  }
  if (reset || from) {
    state.cursor_end = from ?? todayPacific();
    state.exhausted = false;
  }
  if (state.exhausted) {
    return json({
      mode, done: true, cursor_end: state.cursor_end,
      note: "backfill already exhausted; pass reset=true or from=YYYY-MM-DD to run it again",
    });
  }

  const floor = toUnix(BACKFILL_FLOOR);
  const windows: any[] = [];
  const errors: string[] = [];
  let cursor = toUnix(state.cursor_end);
  let emptyStreak = 0;
  let totalInserted = 0, totalSkipped = 0, requests = 0, exhausted = false;

  for (let i = 0; i < maxWindows; i++) {
    const start = Math.max(floor, cursor - MAX_WINDOW_DAYS * DAY);
    if (start >= cursor) {
      exhausted = true;
      errors.push("reached floor " + BACKFILL_FLOOR);
      break;
    }
    const w: Window = { start, end: cursor };

    let payload: any;
    try { payload = await fetchWindow(base, auth, w); requests++; }
    catch (e) {
      // Two-retry cap: stop the run, leave the cursor where it is, report it.
      errors.push("window " + toISO(start) + ".." + toISO(cursor) + ": " +
        String((e as any)?.message ?? e));
      break;
    }

    errors.push(...feedErrorsOf(payload));
    const m = mapRows(payload, byExternal);
    if (m.unmapped.length) errors.push("unmapped in " + toISO(start) + ": " + m.unmapped.join(", "));

    const ing = await ingest(db, m.rows);
    errors.push(...ing.errors);
    totalInserted += ing.inserted;
    totalSkipped += ing.skipped;

    windows.push({
      from: toISO(start), to: toISO(cursor), txns_seen: m.txnsSeen,
      candidates: m.rows.length, inserted: ing.inserted, skipped: ing.skipped,
    });

    cursor = start;
    if (m.txnsSeen === 0) {
      emptyStreak++;
      if (emptyStreak >= EMPTY_WINDOWS_TO_STOP) { exhausted = true; break; }
    } else {
      emptyStreak = 0;
    }
    if (start <= floor) { exhausted = true; break; }
  }

  const note = "backfill: " + requests + " request(s), " + windows.length +
    " window(s), cursor now " + toISO(cursor) + (exhausted ? ", exhausted" : "");

  await db.from("accountant_backfill_state").update({
    cursor_end: toISO(cursor),
    windows_done: (reset || from ? 0 : (state.windows_done ?? 0)) + windows.length,
    requests_made: (reset || from ? 0 : (state.requests_made ?? 0)) + requests,
    rows_inserted: (reset || from ? 0 : (state.rows_inserted ?? 0)) + totalInserted,
    exhausted,
    last_note: note,
    updated_at: new Date().toISOString(),
  }).eq("id", 1);

  await db.from("accountant_phase_runs").insert({
    mode,
    accounts_seen: linked.length,
    txns_seen: windows.reduce((n: number, x: any) => n + x.txns_seen, 0),
    rows_inserted: totalInserted, rows_skipped: totalSkipped,
    errors: errors.length ? errors : null,
    note,
  });

  return json({
    mode, requests, windows, inserted: totalInserted, skipped: totalSkipped,
    cursor_end: toISO(cursor), exhausted, errors, ms: Date.now() - started,
  });
});
