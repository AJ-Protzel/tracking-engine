"""Ashby job boards.

GET https://api.ashbyhq.com/posting-api/job-board/{slug}

Returns applyUrl, a remote flag, and compensation on many postings -- the
richest of the keyless endpoints. No auth.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from ..models import RawJob
from .base import get_json

SOURCE = "ashby"
BASE = "https://api.ashbyhq.com/posting-api/job-board/{slug}"


def fetch(slug: str, company_name: str | None = None) -> list[RawJob]:
    payload = get_json(BASE.format(slug=slug), params={"includeCompensation": "true"})
    return [
        job
        for entry in payload.get("jobs", [])
        if (job := _parse(entry, slug, company_name)) is not None
    ]


def _parse(entry: dict[str, Any], slug: str, company_name: str | None) -> RawJob | None:
    job_id = entry.get("id")
    title = entry.get("title")
    url = entry.get("applyUrl") or entry.get("jobUrl")
    if not (job_id and title and url):
        return None

    salary_min, salary_max = _compensation(entry)

    return RawJob(
        source=SOURCE,
        source_job_id=str(job_id),
        company=company_name or entry.get("organizationName") or slug,
        title=title,
        location_raw=entry.get("location"),
        description=entry.get("descriptionHtml") or entry.get("descriptionPlain"),
        apply_url=url,
        posted_at=_parse_date(entry.get("publishedAt")),
        salary_min=salary_min,
        salary_max=salary_max,
        employment_type_raw=entry.get("employmentType"),
        raw=entry,
    )


def _compensation(entry: dict[str, Any]) -> tuple[int | None, int | None]:
    """Ashby nests salary under compensation.compensationTiers[].components[]."""
    compensation = entry.get("compensation") or {}
    for tier in compensation.get("compensationTiers") or []:
        for component in tier.get("components") or []:
            if (component.get("summary") or "").casefold().startswith("salary") or \
               component.get("compensationType") == "Salary":
                low, high = component.get("minValue"), component.get("maxValue")
                if low or high:
                    return _as_int(low), _as_int(high)
    return None, None


def _as_int(value: Any) -> int | None:
    try:
        return int(float(value)) if value is not None else None
    except (TypeError, ValueError):
        return None


def _parse_date(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
