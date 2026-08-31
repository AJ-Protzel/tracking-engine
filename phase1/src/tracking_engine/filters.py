"""Hard filters. Pure functions, no I/O, heavily tested.

These run before any model sees a posting. They are cheap, deterministic, and
they cut roughly 85% of ingested volume -- which is the point, because the
expensive judgment step should only ever see plausible jobs.

Two rules govern everything in this file:

1.  **Every rejection records which rule rejected it.** `FilterResult.kill_rule`
    is written to `job_filters.kill_rule` on every single killed posting. The
    seniority and sales rules are deliberately broad and will produce false
    positives; the only way to loosen them responsibly is with a count of how
    often each one fired and what it caught. Tuning by intuition is how a filter
    quietly starts hiding good jobs.

2.  **The allow-override runs before the kill rules, not after.** "Sales
    Operations Analyst" and "Salesforce Administrator" both contain a killed
    token and are both real, non-quota roles. Implementing this as kill-then-
    rescue instead of override-then-kill is an easy mistake that silently drops
    an entire title family.
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from typing import Any

from .config import compiled
from .models import FilterResult, Job

# Anything at or below this looks like an hourly rate rather than an annual
# salary. Postings do not label which one they mean with any consistency.
HOURLY_THRESHOLD = 1000

_LEGAL_SUFFIXES = (
    "inc", "inc.", "llc", "l.l.c.", "corp", "corp.", "corporation",
    "ltd", "ltd.", "limited", "co", "co.", "company", "plc", "gmbh", "lp", "llp",
)


# ---------------------------------------------------------------------------
# Title / description rules
# ---------------------------------------------------------------------------

def title_is_overridden(title: str, profile: dict[str, Any]) -> bool:
    """True when a title is explicitly rescued from the kill rules.

    Runs FIRST. A match here means the title kill rules never execute for this
    posting -- see the module docstring.
    """
    for pattern in profile.get("title_allow_override", []):
        if compiled(pattern).search(title):
            return True
    return False


def title_kill(title: str, profile: dict[str, Any]) -> str | None:
    """Return the pattern that kills this title, or None."""
    if title_is_overridden(title, profile):
        return None
    for pattern in profile.get("hard_kills", {}).get("title_regex", []):
        if compiled(pattern).search(title):
            return f"title:{pattern}"
    return None


def description_kill(description: str | None, profile: dict[str, Any]) -> str | None:
    """Return the pattern that kills this description, or None.

    Note the `5+ years` rule will occasionally catch "5 years of combined
    experience preferred", which is a posting worth seeing. That is a known and
    accepted false positive; `job_filters.kill_rule` is what makes its real rate
    measurable so the rule can be loosened with evidence.
    """
    if not description:
        return None
    for pattern in profile.get("hard_kills", {}).get("description_regex", []):
        if compiled(pattern).search(description):
            return f"description:{pattern}"
    return None


def soft_flags(job: Job, profile: dict[str, Any]) -> list[str]:
    """Non-fatal warnings surfaced in the digest.

    These do not kill anything. They exist because some titles are ambiguous
    enough that the posting needs eyes on it before a queue slot is spent.
    """
    haystack = f"{job.title}\n{job.description or ''}"
    hits: list[str] = []
    for flag in profile.get("soft_flags", []):
        if compiled(flag["pattern"]).search(haystack):
            hits.append(flag["note"])
    return hits


# ---------------------------------------------------------------------------
# Geography
# ---------------------------------------------------------------------------

def geography_kill(job: Job, profile: dict[str, Any]) -> str | None:
    geo = profile.get("geography", {})
    location = (job.location_raw or "").strip()

    if job.region == "remote-us":
        return None if geo.get("remote_us") == "allow" else "geography:remote_not_allowed"

    if not location:
        # No location and not flagged remote. Keep it -- the scoring step can
        # read the description. Killing on absent data hides good postings.
        return None

    lowered = location.casefold()

    for metro in geo.get("deny_metros", []):
        if metro.casefold() in lowered:
            return f"geography:deny_metro:{metro}"

    for state in geo.get("deny_states", []):
        if _mentions_state(lowered, state):
            return f"geography:deny_state:{state}"

    # `region` is the authority here. normalize.classify_region already decided
    # whether this posting is Northern California, elsewhere in California,
    # Washington, remote-US, or somewhere else entirely.
    #
    # An earlier version kept anything it could not parse, on the theory that
    # killing on a parse failure hides good jobs. Against live aggregator data
    # that let through Toronto, Macau, Pune and Glasgow -- the feeds are global,
    # so "unparsed" is overwhelmingly "not here" rather than "ambiguous".
    if job.region in {"ca-norcal", "ca-other", "wa"}:
        return None

    return f"geography:outside_allowed_region:{job.region}"


def _mentions_state(lowered_location: str, state: str) -> bool:
    """Match a state by postal abbreviation or full name.

    The abbreviation must sit where a state actually sits -- after a comma, or
    as the whole string. A bare `\\bor\\b` would read "San Francisco or Seattle"
    as Oregon and kill it, and "CA" appears inside enough ordinary words to be
    worth the same care.
    """
    abbrev = state.casefold()
    full = {"ca": "california", "wa": "washington", "or": "oregon"}.get(abbrev)

    if compiled(rf"(?:^|,\s*){abbrev}\b").search(lowered_location):
        return True
    if full and compiled(rf"\b{full}\b").search(lowered_location):
        return True
    return False


# ---------------------------------------------------------------------------
# Compensation and employment type
# ---------------------------------------------------------------------------

def compensation_kill(job: Job, profile: dict[str, Any]) -> str | None:
    """Kill only when the posting proves it pays below the floor.

    California requires pay ranges on postings, so this has teeth in-state.
    Most out-of-state postings omit salary entirely -- those are kept and
    flagged, never killed, or the filter would erase most of the country.
    """
    comp = profile.get("compensation", {})
    ceiling = job.salary_max or job.salary_min
    if ceiling is None:
        return None  # keep_and_flag

    if ceiling <= HOURLY_THRESHOLD:
        floor = comp.get("hourly_floor_w2")
        if floor and ceiling < floor:
            return f"compensation:below_hourly_floor:{ceiling}<{floor}"
        return None

    floor = comp.get("salary_floor_usd")
    if floor and ceiling < floor:
        return f"compensation:below_salary_floor:{ceiling}<{floor}"
    return None


def employment_type_kill(job: Job, profile: dict[str, Any]) -> str | None:
    types = profile.get("employment_types", {})
    if job.employment_type is None:
        return None
    if job.employment_type in types.get("deny", []):
        return f"employment_type:{job.employment_type}"
    allow = types.get("allow", [])
    if allow and job.employment_type not in allow:
        return f"employment_type:not_allowed:{job.employment_type}"
    return None


# ---------------------------------------------------------------------------
# Recruiter conflict
# ---------------------------------------------------------------------------

def normalize_company(name: str) -> str:
    """Casefold, strip legal suffixes and punctuation, collapse whitespace."""
    cleaned = compiled(r"[^\w\s]").sub(" ", name.casefold())
    tokens = [t for t in cleaned.split() if t not in _LEGAL_SUFFIXES]
    return " ".join(tokens)


def recruiter_conflict(job: Job, submissions: Iterable[dict[str, Any]]) -> dict[str, Any] | None:
    """Return the blocking submission if an agency owns this employer, else None.

    Matching is normalized equality, then domain. It is deliberately NOT fuzzy.

    A false positive here silently hides a job Adrien could have had, and
    nothing in the system would ever surface that it happened -- which is the
    failure mode you cannot detect from the outside. A false negative, by
    contrast, is caught by a human reading the digest before applying. When in
    doubt, do not block.

    Callers pass rows from `v_blocked_employers`, which has already filtered to
    active, unexpired submissions.
    """
    job_key = normalize_company(job.company)
    if not job_key:
        return None

    job_domain = _domain_of(job.apply_url)

    for row in submissions:
        if normalize_company(row.get("client_name", "")) == job_key:
            return row
        client_domain = (row.get("client_domain") or "").strip().casefold()
        if client_domain and job_domain and _domain_matches(job_domain, client_domain):
            return row
    return None


def _domain_matches(job_domain: str, client_domain: str) -> bool:
    """Exact host, or a subdomain of it.

    Postings live at `careers.example.com` while the submission recorded
    `example.com`. Requiring the leading dot keeps this from matching
    `notexample.com`, which is a different company.
    """
    return job_domain == client_domain or job_domain.endswith(f".{client_domain}")


def _domain_of(url: str) -> str | None:
    match = compiled(r"^https?://([^/]+)").search(url or "")
    if not match:
        return None
    host = match.group(1).casefold()
    return host[4:] if host.startswith("www.") else host


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def evaluate(job: Job, profile: dict[str, Any]) -> FilterResult:
    """Run every hard rule in order. First kill wins and is recorded.

    Recruiter conflict is deliberately NOT part of this -- it needs a database
    read, and this module stays pure. It runs after these rules and before
    scoring; see `run_ingest.py`.
    """
    checks: Sequence[str | None] = (
        title_kill(job.title, profile),
        description_kill(job.description, profile),
        geography_kill(job, profile),
        compensation_kill(job, profile),
        employment_type_kill(job, profile),
    )
    for rule in checks:
        if rule:
            return FilterResult.kill(rule)
    return FilterResult.keep()
