"""Lever postings.

GET https://api.lever.co/v0/postings/{slug}?mode=json

The slug must match the company's careers URL exactly -- Lever does not
normalize it. No auth.
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

from ..models import RawJob
from .base import get_json

SOURCE = "lever"
BASE = "https://api.lever.co/v0/postings/{slug}"


def fetch(slug: str, company_name: str | None = None) -> list[RawJob]:
    payload = get_json(BASE.format(slug=slug), params={"mode": "json"})
    return [
        job
        for entry in payload
        if (job := _parse(entry, slug, company_name)) is not None
    ]


def _parse(entry: dict[str, Any], slug: str, company_name: str | None) -> RawJob | None:
    job_id = entry.get("id")
    title = entry.get("text")
    url = entry.get("hostedUrl") or entry.get("applyUrl")
    if not (job_id and title and url):
        return None

    categories = entry.get("categories") or {}
    description = entry.get("descriptionPlain") or entry.get("description")

    for section in entry.get("lists") or []:
        content = section.get("content")
        if content:
            description = f"{description or ''}\n{section.get('text', '')}\n{content}"

    return RawJob(
        source=SOURCE,
        source_job_id=str(job_id),
        company=company_name or slug,
        title=title,
        location_raw=categories.get("location"),
        description=description,
        apply_url=url,
        posted_at=_parse_epoch_ms(entry.get("createdAt")),
        employment_type_raw=categories.get("commitment"),
        raw=entry,
    )


def _parse_epoch_ms(value: Any) -> datetime | None:
    if not isinstance(value, (int, float)):
        return None
    try:
        return datetime.fromtimestamp(value / 1000, tz=UTC)
    except (OverflowError, OSError, ValueError):
        return None
