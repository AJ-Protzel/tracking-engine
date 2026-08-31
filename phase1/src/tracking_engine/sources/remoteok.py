"""RemoteOK public feed.

GET https://remoteok.com/api

The first element of the response is a legal/attribution notice rather than a
posting -- it has no `id`, so the parser drops it naturally. No auth.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from ..models import RawJob
from .base import get_json

SOURCE = "remoteok"
BASE = "https://remoteok.com/api"


def fetch() -> list[RawJob]:
    payload = get_json(BASE)
    if not isinstance(payload, list):
        return []
    return [job for entry in payload if (job := _parse(entry)) is not None]


def _parse(entry: Any) -> RawJob | None:
    if not isinstance(entry, dict):
        return None

    job_id = entry.get("id")
    title = entry.get("position") or entry.get("title")
    url = entry.get("apply_url") or entry.get("url")
    company = entry.get("company")
    if not (job_id and title and url and company):
        return None

    return RawJob(
        source=SOURCE,
        source_job_id=str(job_id),
        company=company,
        title=title,
        location_raw=entry.get("location") or "Remote",
        description=entry.get("description"),
        apply_url=url,
        posted_at=_parse_date(entry.get("date")),
        salary_min=_as_int(entry.get("salary_min")),
        salary_max=_as_int(entry.get("salary_max")),
        employment_type_raw=",".join(entry.get("tags") or []) or None,
        raw=entry,
    )


def _as_int(value: Any) -> int | None:
    try:
        return int(float(value)) if value else None
    except (TypeError, ValueError):
        return None


def _parse_date(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
