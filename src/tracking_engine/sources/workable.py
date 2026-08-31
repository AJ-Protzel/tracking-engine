"""Workable job boards.

GET https://www.workable.com/api/accounts/{slug}?details=true

Heavy in mid-size and non-tech employers, which is most of the Sacramento
region. No auth.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from ..models import RawJob
from .base import get_json

SOURCE = "workable"
BASE = "https://www.workable.com/api/accounts/{slug}"


def fetch(slug: str, company_name: str | None = None) -> list[RawJob]:
    payload = get_json(BASE.format(slug=slug), params={"details": "true"})
    entries = payload.get("jobs", []) if isinstance(payload, dict) else []
    resolved = company_name or (payload.get("name") if isinstance(payload, dict) else None)
    return [
        job
        for entry in entries
        if (job := _parse(entry, slug, resolved)) is not None
    ]


def _parse(entry: dict[str, Any], slug: str, company_name: str | None) -> RawJob | None:
    job_id = entry.get("shortcode") or entry.get("id")
    title = entry.get("title")
    url = entry.get("url") or entry.get("application_url")
    if not (job_id and title and url):
        return None

    return RawJob(
        source=SOURCE,
        source_job_id=str(job_id),
        company=company_name or slug,
        title=title,
        location_raw=_location(entry),
        description=entry.get("description"),
        apply_url=url,
        posted_at=_parse_date(entry.get("published_on") or entry.get("created_at")),
        employment_type_raw=entry.get("employment_type"),
        raw=entry,
    )


def _location(entry: dict[str, Any]) -> str | None:
    if entry.get("telecommuting"):
        return "Remote"
    location = entry.get("location") or {}
    if isinstance(location, str):
        return location
    parts = [location.get("city"), location.get("region"), location.get("country")]
    joined = ", ".join(p for p in parts if p)
    return joined or None


def _parse_date(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
