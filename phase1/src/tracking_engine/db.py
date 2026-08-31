"""Supabase access. Every write is idempotent.

Running ingest twice in a row must insert nothing the second time -- that is the
definition of done for step 1, and it is enforced by the `(source,
source_job_id)` unique constraint plus upsert rather than by checking first.
"""

from __future__ import annotations

import logging
import os
from datetime import UTC, datetime
from typing import Any

from supabase import Client, create_client

from .models import FilterResult, Job

log = logging.getLogger(__name__)


def client() -> Client:
    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_SERVICE_KEY")
    if not url or not key:
        raise RuntimeError(
            "SUPABASE_URL and SUPABASE_SERVICE_KEY must be set. "
            "In GitHub Actions these come from repository secrets."
        )
    return create_client(url, key)


# ---------------------------------------------------------------------------
# Companies
# ---------------------------------------------------------------------------

def active_companies(db: Client) -> list[dict[str, Any]]:
    response = (
        db.table("companies").select("*").eq("active", True).order("tier").execute()
    )
    return response.data or []


def mark_company_ok(db: Client, company_id: int) -> None:
    db.table("companies").update(
        {"last_ok_at": datetime.now(UTC).isoformat(), "fail_count": 0}
    ).eq("id", company_id).execute()


def mark_company_failed(db: Client, company: dict[str, Any]) -> bool:
    """Bump the failure count. Deactivate after 5 consecutive misses.

    Returns True when this call deactivated the company, so the caller can
    report it -- a slug that silently stops working is exactly the kind of decay
    that makes a pipeline quietly useless.
    """
    fail_count = (company.get("fail_count") or 0) + 1
    deactivate = fail_count >= 5
    payload: dict[str, Any] = {"fail_count": fail_count}
    if deactivate:
        payload["active"] = False
    db.table("companies").update(payload).eq("id", company["id"]).execute()
    if deactivate:
        log.warning("Deactivated %s (%s/%s) after %d consecutive failures",
                    company.get("name"), company.get("ats"), company.get("slug"), fail_count)
    return deactivate


# ---------------------------------------------------------------------------
# Jobs
# ---------------------------------------------------------------------------

# Sized against the steady state, not the first run. On night one most rows are
# INSERTs and 500 is comfortable; every night after that the same ~10k postings
# are still live, so the upsert is almost entirely UPDATEs, which are far slower.
# At 500 that reliably hit Postgres's statement timeout (57014) and failed the
# whole run. 100 stays well inside it.
UPSERT_BATCH = 100


def upsert_jobs(db: Client, jobs: list[Job]) -> list[dict[str, Any]]:
    """Insert new postings, refresh `last_seen_at` on ones already stored.

    `first_seen_at` is never overwritten: the daily scoring pass selects on it,
    so bumping it would make an old posting look new every night.

    Sent in batches. Even without the raw payload a night's haul across 150
    boards is large enough that a single request times out against PostgREST
    and takes the whole run with it.
    """
    if not jobs:
        return []

    now = datetime.now(UTC).isoformat()
    rows = []
    for job in jobs:
        row = job.model_dump(mode="json", exclude={"dedupe_key"})
        row["last_seen_at"] = now
        rows.append(row)

    stored: list[dict[str, Any]] = []
    for start in range(0, len(rows), UPSERT_BATCH):
        batch = rows[start:start + UPSERT_BATCH]
        response = (
            db.table("jobs")
            .upsert(batch, on_conflict="source,source_job_id", ignore_duplicates=False)
            .execute()
        )
        stored.extend(response.data or [])
        log.info("Upserted %d/%d jobs", len(stored), len(rows))
    return stored


def write_filter_results(db: Client, results: dict[int, FilterResult]) -> None:
    if not results:
        return
    rows = [
        {"job_id": job_id, "passed": result.passed, "kill_rule": result.kill_rule}
        for job_id, result in results.items()
    ]
    for start in range(0, len(rows), UPSERT_BATCH):
        db.table("job_filters").upsert(
            rows[start:start + UPSERT_BATCH], on_conflict="job_id"
        ).execute()


def blocked_employers(db: Client) -> list[dict[str, Any]]:
    """Active, unexpired recruiter submissions. The view handles both filters."""
    response = db.table("v_blocked_employers").select("*").execute()
    return response.data or []


def skip_for_recruiter_conflict(
    db: Client, job_id: int, submission: dict[str, Any]
) -> None:
    """Record the job as skipped rather than dropping it.

    It stays visible in the digest under "Held -- agency owns this client",
    because sometimes the right move is to call that recruiter about that exact
    role instead of letting it pass.
    """
    reason = (
        f"recruiter_conflict: {submission.get('agency')} "
        f"submitted {submission.get('submitted_at')}"
    )
    db.table("applications").upsert(
        {"job_id": job_id, "status": "skipped", "skip_reason": reason},
        on_conflict="job_id",
    ).execute()


# ---------------------------------------------------------------------------
# Phase telemetry
# ---------------------------------------------------------------------------
#
# Every phase writes one `phase_runs` row, and phase 3 reads the newest row per
# phase to build the artifact. This is what lets a paused phase render as
# "nothing changed, last ran <time>" instead of an error or a blank card, which
# is the whole reason the phases can be paused independently.

def start_run(db: Client, phase: str) -> int:
    response = db.table("phase_runs").insert({"phase": phase}).execute()
    return response.data[0]["id"]


def finish_run(
    db: Client, run_id: int, *, ok: bool,
    counts: dict[str, Any] | None = None,
    summary: dict[str, Any] | None = None,
    error: str | None = None,
) -> None:
    """Always called, success or failure.

    A run that dies without writing a row looks identical to a run that never
    fired, and a pipeline that fails silently is worse than no pipeline.
    """
    db.table("phase_runs").update(
        {
            "finished_at": datetime.now(UTC).isoformat(),
            "status": "ok" if ok else "failed",
            "counts": counts or {},
            "summary": summary,
            "error": error,
        }
    ).eq("id", run_id).execute()
