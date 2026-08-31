"""Greenhouse job boards.

GET https://boards-api.greenhouse.io/v1/boards/{slug}/jobs?content=true

`content=true` returns the full HTML description in the list call, which saves a
second request per posting. No auth.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from ..models import RawJob
from .base import get_json

SOURCE = "greenhouse"
BASE = "https://boards-api.greenhouse.io/v1/boards/{slug}/jobs"


def fetch(slug: str, company_name: str | None = None) -> list[RawJob]:
    payload = get_json(BASE.format(slug=slug), params={"content": "true"})
    return [
        job
        for entry in payload.get("jobs", [])
        if (job := _parse(entry, slug, company_name)) is not None
    ]


def _parse(entry: dict[str, Any], slug: str, company_name: str | None) -> RawJob | None:
    job_id = entry.get("id")
    title = entry.get("title")
    url = entry.get("absolute_url")
    if not (job_id and title and url):
        return None

    return RawJob(
        source=SOURCE,
        source_job_id=str(job_id),
        company=company_name or slug,
        title=title,
        location_raw=(entry.get("location") or {}).get("name"),
        description=entry.get("content"),
        apply_url=url,
        posted_at=_parse_date(entry.get("updated_at") or entry.get("created_at")),
        employment_type_raw=_metadata_value(entry, "employment type"),
        raw=entry,
    )


def _metadata_value(entry: dict[str, Any], needle: str) -> str | None:
    for item in entry.get("metadata") or []:
        if needle in (item.get("name") or "").casefold():
            value = item.get("value")
            if isinstance(value, list):
                return ", ".join(str(v) for v in value)
            return str(value) if value is not None else None
    return None


def _parse_date(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
