"""RawJob -> Job.

Everything source-specific ends here. After this point the rest of the codebase
cannot tell whether a posting came from Greenhouse or an aggregator, which is
what keeps the filter and storage layers stable when a tenth source is added.
"""

from __future__ import annotations

import html
import re

from .models import Job, RawJob

_TAG = re.compile(r"<[^>]+>")
_WS = re.compile(r"[ \t\r\f\v]+")
_BLANK_LINES = re.compile(r"\n{3,}")

_NORCAL = (
    "sacramento", "folsom", "roseville", "el dorado hills", "rancho cordova",
    "davis", "elk grove", "citrus heights", "rocklin", "san francisco",
    "oakland", "berkeley", "san jose", "palo alto", "mountain view",
    "sunnyvale", "santa clara", "fremont", "walnut creek", "bay area",
)

_REMOTE_HINTS = ("remote", "anywhere", "work from home", "wfh", "distributed")
_US_HINTS = ("us", "usa", "united states", "u.s.")


def strip_html(value: str | None) -> str | None:
    """ATS descriptions are HTML. Store text only -- the payload is not kept."""
    if not value:
        return None
    text = _TAG.sub("\n", value)
    text = html.unescape(text)
    text = _WS.sub(" ", text)
    text = "\n".join(line.strip() for line in text.splitlines())
    text = _BLANK_LINES.sub("\n\n", text)
    return text.strip() or None


def classify_region(location: str | None, *, remote_hint: bool = False) -> str:
    """Bucket a location string.

    `remote_hint` says the *source* only lists remote roles. That is not the
    same as the role being open to the US: the remote-only boards carry plenty
    of "Remote - Toronto" and "Remote - India" postings. So a remote posting
    only counts as remote-us when it says so, or when it names no place at all.
    Anything naming a specific city falls through to normal classification and
    gets judged on that city.
    """
    if not location:
        return "remote-us" if remote_hint else "other"

    lowered = location.casefold()
    is_remote = remote_hint or any(h in lowered for h in _REMOTE_HINTS)

    if is_remote:
        if any(re.search(rf"\b{re.escape(h)}\b", lowered) for h in _US_HINTS):
            return "remote-us"
        if _is_generic_remote(lowered):
            return "remote-us"
        # Names somewhere specific -- fall through and judge it on the place.

    if any(city in lowered for city in _NORCAL):
        return "ca-norcal"
    if re.search(r"(?:^|,\s*)ca\b|\bcalifornia\b", lowered):
        return "ca-other"
    if re.search(r"(?:^|,\s*)wa\b|\bwashington\b", lowered):
        return "wa"
    return "other"


def _is_generic_remote(lowered: str) -> bool:
    """"Remote", "Anywhere", "Worldwide" -- no place named, so nothing excludes US."""
    stripped = re.sub(r"[^a-z ]", " ", lowered)
    tokens = set(stripped.split())
    generic = {"remote", "anywhere", "worldwide", "global", "work", "from", "home",
               "wfh", "distributed", "flexible", "any", "location"}
    return bool(tokens) and tokens.issubset(generic)


def classify_employment_type(raw: str | None, title: str = "") -> str | None:
    haystack = f"{raw or ''} {title}".casefold()
    if not haystack.strip():
        return None
    if re.search(r"contract[- ]to[- ]hire|c2h|temp[- ]to[- ]perm", haystack):
        return "contract_to_hire"
    if re.search(r"\b(intern|internship)\b", haystack):
        return "intern"
    if re.search(r"\b(part[- ]time|parttime)\b", haystack):
        return "part_time"
    if re.search(r"\b(contract|contractor|temporary|freelance)\b", haystack):
        return "contract"
    if re.search(r"\b(full[- ]time|fulltime|permanent|regular)\b", haystack):
        return "full_time"
    return None


# The `raw` JSON payload used to be stored alongside every posting. On 2026-08-30
# it accounted for 228 MB of a 252 MB database -- 90% of the free-tier budget for
# data nothing read. Descriptions are the only part the scorer looks at, and it
# never needs more than the opening. Storing text, capped, keeps the database
# flat instead of growing a few hundred MB a month.
DESCRIPTION_LIMIT = 4000


def truncate(text: str | None, limit: int = DESCRIPTION_LIMIT) -> str | None:
    if text is None:
        return None
    return text if len(text) <= limit else text[:limit].rstrip() + "..."


def normalize(raw: RawJob, *, remote_hint: bool = False) -> Job:
    return Job(
        source=raw.source,
        source_job_id=str(raw.source_job_id),
        company=raw.company.strip(),
        title=raw.title.strip(),
        location_raw=(raw.location_raw or "").strip() or None,
        region=classify_region(raw.location_raw, remote_hint=remote_hint),
        employment_type=classify_employment_type(raw.employment_type_raw, raw.title),
        salary_min=raw.salary_min,
        salary_max=raw.salary_max,
        description=truncate(strip_html(raw.description)),
        apply_url=raw.apply_url,
        posted_at=raw.posted_at,
    )


def dedupe(jobs: list[Job]) -> list[Job]:
    """Collapse the same posting seen through more than one source.

    Direct ATS URLs beat aggregator redirects: they convert better, and the
    aggregator's copy is often stale or truncated.
    """
    ats = {"greenhouse", "lever", "ashby", "workable", "recruitee"}
    best: dict[tuple[str, str, str], Job] = {}

    for job in jobs:
        key = job.dedupe_key
        incumbent = best.get(key)
        if incumbent is None:
            best[key] = job
            continue
        if job.source in ats and incumbent.source not in ats:
            best[key] = job
        elif job.source in ats and incumbent.source in ats:
            if len(job.description or "") > len(incumbent.description or ""):
                best[key] = job

    return list(best.values())
