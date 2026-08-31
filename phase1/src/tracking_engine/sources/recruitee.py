"""Recruitee job boards.

GET https://{slug}.recruitee.com/api/offers/

Smaller footprint than the others, and almost nobody else is polling it. No
auth.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from ..models import RawJob
from .base import get_json

SOURCE = "recruitee"
BASE = "https://{slug}.recruitee.com/api/offers/"


def fetch(slug: str, company_name: str | None = None) -> list[RawJob]:
    payload = get_json(BASE.format(slug=slug))
    return [
        job
        for entry in payload.get("offers", [])
        if (job := _parse(entry, slug, company_name)) is not None
    ]


def _parse(entry: dict[str, Any], slug: str, company_name: str | None) -> RawJob | None:
    job_id = entry.get("id")
    title = entry.get("title")
    url = entry.get("careers_url") or entry.get("careers_apply_url")
    if not (job_id and title and url):
        return None

    parts = [entry.get("city"), entry.get("state_name") or entry.get("state_code"),
             entry.get("country_code")]
    location = ", ".join(p for p in parts if p) or entry.get("location")
    if entry.get("remote"):
        location = f"Remote{f' - {location}' if location else ''}"

    return RawJob(
        source=SOURCE,
        source_job_id=str(job_id),
        company=company_name or entry.get("company_name") or slug,
        title=title,
        location_raw=location,
        description=entry.get("description"),
        apply_url=url,
        posted_at=_parse_date(entry.get("published_at") or entry.get("created_at")),
        employment_type_raw=entry.get("employment_type_code") or entry.get("category_code"),
        raw=entry,
    )


def _parse_date(value: str | None) -> datetime | None:
    if not value:
        return None
    for candidate in (value, value.replace("Z", "+00:00")):
        try:
            return datetime.fromisoformat(candidate)
        except ValueError:
            continue
    return None
