"""Remotive public feed.

GET https://remotive.com/api/remote-jobs

Board-wide, not per-company: one call returns everything, so it is queried by
category rather than by slug. No auth, no cap.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from ..models import RawJob
from .base import get_json

SOURCE = "remotive"
BASE = "https://remotive.com/api/remote-jobs"

# Remotive's own category slugs. Anything outside these is noise for this search.
CATEGORIES = ("data", "software-dev", "business", "product", "customer-support")


def fetch(categories: tuple[str, ...] = CATEGORIES, limit: int = 200) -> list[RawJob]:
    seen: set[str] = set()
    jobs: list[RawJob] = []

    for category in categories:
        payload = get_json(BASE, params={"category": category, "limit": limit})
        for entry in payload.get("jobs", []):
            job = _parse(entry)
            if job and job.source_job_id not in seen:
                seen.add(job.source_job_id)
                jobs.append(job)

    return jobs


def _parse(entry: dict[str, Any]) -> RawJob | None:
    job_id = entry.get("id")
    title = entry.get("title")
    url = entry.get("url")
    company = entry.get("company_name")
    if not (job_id and title and url and company):
        return None

    return RawJob(
        source=SOURCE,
        source_job_id=str(job_id),
        company=company,
        title=title,
        location_raw=entry.get("candidate_required_location") or "Remote",
        description=entry.get("description"),
        apply_url=url,
        posted_at=_parse_date(entry.get("publication_date")),
        employment_type_raw=entry.get("job_type"),
        raw=entry,
    )


def _parse_date(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
