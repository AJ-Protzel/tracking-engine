"""Shared shapes.

`RawJob` is what a source connector returns: whatever that API gave us, lightly
coerced. `Job` is the normalized row that lands in Postgres. Every connector
produces `RawJob`; only `normalize.py` produces `Job`. Keeping those separate is
what lets a new source be added without touching the filter or storage layers.
"""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel

EmploymentType = str  # 'full_time' | 'contract' | 'c2h' | 'part_time' | 'intern'
Region = str  # 'remote-us' | 'ca-norcal' | 'ca-other' | 'wa' | 'other'


class RawJob(BaseModel):
    """One posting as the source described it."""

    source: str
    source_job_id: str
    company: str
    title: str
    location_raw: str | None = None
    description: str | None = None
    apply_url: str
    posted_at: datetime | None = None
    salary_min: int | None = None
    salary_max: int | None = None
    employment_type_raw: str | None = None


class Job(BaseModel):
    """One posting, normalized. Mirrors the `jobs` table."""

    source: str
    source_job_id: str
    company: str
    title: str
    location_raw: str | None = None
    region: Region | None = None
    employment_type: EmploymentType | None = None
    salary_min: int | None = None
    salary_max: int | None = None
    description: str | None = None
    apply_url: str
    posted_at: datetime | None = None

    @property
    def dedupe_key(self) -> tuple[str, str, str]:
        """Cross-source identity.

        The same posting appears on Greenhouse and on an aggregator with
        different ids. `(source, source_job_id)` will not catch that; this will.
        """
        return (
            self.company.strip().casefold(),
            self.title.strip().casefold(),
            (self.location_raw or "").strip().casefold(),
        )


class FilterResult(BaseModel):
    """Why a job did or did not survive the hard filters."""

    passed: bool
    kill_rule: str | None = None

    @classmethod
    def kill(cls, rule: str) -> FilterResult:
        return cls(passed=False, kill_rule=rule)

    @classmethod
    def keep(cls) -> FilterResult:
        return cls(passed=True)
