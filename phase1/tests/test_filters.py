"""Filter tests.

The definition of done for the filter layer is 20 realistic postings -- 10 that
should survive, 10 that should not, plus the near-misses that are easy to get
wrong -- all classified correctly.

These run against the real `config/profile.yaml`, not a fixture. A rule change
that breaks the search shows up here rather than three days later in a thin
digest.
"""

from __future__ import annotations

import pytest
from tracking_engine import filters, normalize
from tracking_engine.config import load_profile
from tracking_engine.models import Job

PROFILE = load_profile()


def job(
    title: str,
    *,
    company: str = "Example Health",
    location: str | None = "Sacramento, CA",
    description: str = "Build reports and maintain data pipelines.",
    salary_min: int | None = None,
    salary_max: int | None = None,
    employment_raw: str | None = "Full-time",
    apply_url: str = "https://boards.greenhouse.io/example/jobs/1",
) -> Job:
    return Job(
        source="greenhouse",
        source_job_id="1",
        company=company,
        title=title,
        location_raw=location,
        region=normalize.classify_region(location),
        employment_type=normalize.classify_employment_type(employment_raw, title),
        salary_min=salary_min,
        salary_max=salary_max,
        description=description,
        apply_url=apply_url,
    )


# ---------------------------------------------------------------------------
# Should survive
# ---------------------------------------------------------------------------

SHOULD_PASS = [
    pytest.param(job("Data Analyst", salary_min=70_000, salary_max=90_000), id="data-analyst"),
    pytest.param(job("Analytics Engineer", location="Remote - US"), id="analytics-eng-remote"),
    pytest.param(job("Business Systems Analyst", location="Folsom, CA"), id="bsa-folsom"),
    pytest.param(job("Data Quality Analyst", location="Seattle, WA"), id="dq-seattle"),
    pytest.param(job("ETL Developer", location="San Francisco, CA"), id="etl-sf"),
    pytest.param(job("Technical Support Engineer", location="Remote - US"), id="tse-remote"),
    pytest.param(job("Junior Data Engineer", location="Remote, US"), id="jde-no-salary"),
    pytest.param(job("Power BI Developer", location="Roseville, CA"), id="pbi-roseville"),
    # Near-miss: contract in Sacramento, above the hourly floor. Contract is an
    # allowed employment type and $58/hr clears the $32 floor.
    pytest.param(
        job("Reporting Analyst", employment_raw="Contract", salary_min=52, salary_max=58),
        id="nearmiss-sacramento-contract",
    ),
    # Near-miss: contains "Sales" and would be killed without the override.
    pytest.param(job("Sales Operations Analyst"), id="nearmiss-sales-ops-override"),
]


@pytest.mark.parametrize("posting", SHOULD_PASS)
def test_survives_hard_filters(posting: Job) -> None:
    result = filters.evaluate(posting, PROFILE)
    assert result.passed, f"{posting.title!r} was killed by {result.kill_rule}"


# ---------------------------------------------------------------------------
# Should be killed
# ---------------------------------------------------------------------------

SHOULD_KILL = [
    pytest.param(job("Senior Data Engineer"), "title", id="seniority-senior"),
    pytest.param(job("Data Analytics Intern"), "title", id="seniority-intern"),
    pytest.param(job("Account Executive"), "title", id="sales-ae"),
    pytest.param(job("Sales Engineer"), "title", id="sales-engineer"),
    pytest.param(job("Line Cook"), "title", id="food-line-cook"),
    pytest.param(job("Retail Associate"), "title", id="retail-associate"),
    pytest.param(
        job("Data Analyst", description="Requires an active security clearance."),
        "description", id="clearance",
    ),
    pytest.param(
        job("Data Analyst", description="You will cold call prospects and close deals."),
        "description", id="quota-language",
    ),
    pytest.param(job("Data Analyst", location="Los Angeles, CA"), "geography", id="deny-metro-la"),
    pytest.param(job("Data Analyst", location="Portland, OR"), "geography", id="deny-state-or"),
    pytest.param(
        job("Data Analyst", salary_min=38_000, salary_max=44_000),
        "compensation", id="below-salary-floor",
    ),
    pytest.param(
        job("Data Analyst", employment_raw="Part-time"),
        "employment_type", id="part-time",
    ),
]


@pytest.mark.parametrize("posting,expected_prefix", SHOULD_KILL)
def test_killed_by_hard_filters(posting: Job, expected_prefix: str) -> None:
    result = filters.evaluate(posting, PROFILE)
    assert not result.passed, f"{posting.title!r} survived and should not have"
    assert result.kill_rule is not None
    assert result.kill_rule.startswith(expected_prefix), (
        f"killed by {result.kill_rule!r}, expected a {expected_prefix} rule"
    )


# ---------------------------------------------------------------------------
# The years-of-experience rule, retired 2026-08-31
# ---------------------------------------------------------------------------

def test_years_of_experience_no_longer_kills() -> None:
    """This assertion was written inverted, to flip when the rule was loosened.

    It has flipped. The old test said "5 years of combined experience" is killed
    and that this is wrong; the kill_rule log then measured how wrong: 597
    postings in one night, 110 of them analyst-shaped, against 96 analyst-shaped
    postings surviving the entire filter set. One rule was discarding more
    relevant work than everything else combined let through.

    A posted "5+ years" is frequently a wish rather than a bar. The requirement
    is surfaced as a soft flag and folded into the fit score instead.
    """
    posting = job(
        "Data Analyst",
        description="5 years of combined experience across analytics preferred.",
    )
    result = filters.evaluate(posting, PROFILE)
    assert result.passed
    assert result.kill_rule is None


def test_years_requirement_is_flagged_instead_of_killed() -> None:
    """Removing the kill must not make the requirement invisible."""
    posting = job("Data Analyst", description="Requires 7+ years of SQL experience.")
    assert filters.evaluate(posting, PROFILE).passed
    flags = filters.soft_flags(posting, PROFILE)
    assert any("5+ years" in flag for flag in flags), flags


def test_active_clearance_kills_but_obtainable_does_not() -> None:
    """"Ability to obtain a clearance" is a sponsored process, not a barrier.

    The old rule matched the bare phrase "security clearance" anywhere, so a
    posting offering to sponsor one read identically to a posting demanding one.
    """
    demanded = job("Data Analyst", description="Must hold an active security clearance.")
    result = filters.evaluate(demanded, PROFILE)
    assert not result.passed
    assert result.kill_rule is not None and "clearance" in result.kill_rule

    offered = job("Data Analyst", description="Must be able to obtain a security clearance.")
    assert filters.evaluate(offered, PROFILE).passed
    assert any("obtainable" in flag for flag in filters.soft_flags(offered, PROFILE))


def test_remote_survives_any_non_deny_setting() -> None:
    """A kill switch must require the word that means no.

    `remote_us` was compared against the literal "allow", so changing it to
    "prefer" -- a strictly stronger yes -- killed every remote posting. Remote is
    where the entry-level volume is, so that failure would have been expensive
    and silent.
    """
    posting = job("Data Analyst", location="Remote - US")
    for setting in ("allow", "prefer"):
        profile = {**PROFILE, "geography": {**PROFILE["geography"], "remote_us": setting}}
        assert filters.evaluate(posting, profile).passed, setting

    denied = {**PROFILE, "geography": {**PROFILE["geography"], "remote_us": "deny"}}
    assert not filters.evaluate(posting, denied).passed


# ---------------------------------------------------------------------------
# The override must run before the kill rules, not after
# ---------------------------------------------------------------------------

@pytest.mark.parametrize(
    "title",
    [
        "Sales Operations Analyst",
        "Revenue Operations Analyst",
        "Salesforce Administrator",
        "Salesforce Data Analyst",
    ],
)
def test_allow_override_beats_kill_rules(title: str) -> None:
    assert filters.title_kill(title, PROFILE) is None, (
        f"{title!r} is a real non-quota role and must survive the sales kill rule"
    )


def test_override_does_not_rescue_actual_sales_roles() -> None:
    for title in ("Enterprise Sales Representative", "Inside Sales Associate"):
        assert filters.title_kill(title, PROFILE) is not None, (
            f"{title!r} carries a quota and must be killed"
        )


# ---------------------------------------------------------------------------
# Recruiter conflict
# ---------------------------------------------------------------------------

SUBMISSIONS = [
    {
        "client_name": "Blue Shield of California",
        "client_domain": "blueshieldca.com",
        "agency": "TEKsystems",
        "submitted_at": "2026-08-14",
    },
    {
        "client_name": "Sutter Health, Inc.",
        "client_domain": None,
        "agency": "Robert Half Technology",
        "submitted_at": "2026-08-02",
    },
]


def test_recruiter_conflict_matches_on_normalized_name() -> None:
    posting = job("Reporting Analyst", company="Sutter Health Inc")
    conflict = filters.recruiter_conflict(posting, SUBMISSIONS)
    assert conflict is not None
    assert conflict["agency"] == "Robert Half Technology"


def test_recruiter_conflict_matches_on_domain() -> None:
    posting = job(
        "Data Analyst",
        company="Blue Shield CA",
        apply_url="https://careers.blueshieldca.com/jobs/44",
    )
    assert filters.recruiter_conflict(posting, SUBMISSIONS) is not None


def test_recruiter_conflict_does_not_fuzzy_match() -> None:
    """A false positive here hides a good job and nothing surfaces that it did.

    "Blue Shield Financial" is a different company. Substring or fuzzy matching
    would block it; normalized equality must not.
    """
    posting = job("Data Analyst", company="Blue Shield Financial Group")
    assert filters.recruiter_conflict(posting, SUBMISSIONS) is None


def test_recruiter_conflict_ignores_unrelated_employer() -> None:
    posting = job("Data Analyst", company="Kaiser Permanente")
    assert filters.recruiter_conflict(posting, SUBMISSIONS) is None


# ---------------------------------------------------------------------------
# Supporting behaviour
# ---------------------------------------------------------------------------

def test_state_abbreviation_does_not_match_the_word_or() -> None:
    """"San Francisco or Seattle" is not Oregon."""
    posting = job("Data Analyst", location="San Francisco or Seattle")
    result = filters.evaluate(posting, PROFILE)
    assert result.passed, f"killed by {result.kill_rule}"


@pytest.mark.parametrize(
    "location",
    ["Toronto, ON", "Macau", "Pune Division,", "Glasgow,", "Bijnor,", "Worldwide, India"],
)
def test_foreign_locations_are_killed(location: str) -> None:
    """Regression: these all survived the first version of the geography rule.

    The board-wide feeds are global. An earlier implementation kept any location
    string it could not parse into `City, ST`, reasoning that killing on a parse
    failure hides good jobs -- which let through most of the world. On these
    sources "unparsed" means "not here", not "ambiguous".
    """
    posting = job("Data Analyst", location=location)
    result = filters.evaluate(posting, PROFILE)
    assert not result.passed, f"{location!r} survived the geography filter"
    assert result.kill_rule is not None and result.kill_rule.startswith("geography")


@pytest.mark.parametrize(
    "location,expected",
    [
        ("USA", "remote-us"),
        ("Remote", "remote-us"),
        ("Anywhere", "remote-us"),
        ("Remote - US", "remote-us"),
        ("Toronto", "other"),
        ("Remote - Canada", "other"),
    ],
)
def test_remote_only_board_still_judges_named_places(location: str, expected: str) -> None:
    """A remote-only source does not make a Toronto posting US-eligible."""
    assert normalize.classify_region(location, remote_hint=True) == expected


def test_missing_salary_is_kept_not_killed() -> None:
    posting = job("Data Analyst", location="Seattle, WA", salary_min=None, salary_max=None)
    assert filters.compensation_kill(posting, PROFILE) is None


def test_hourly_rate_below_floor_is_killed() -> None:
    posting = job("Data Analyst", employment_raw="Contract", salary_min=26, salary_max=28)
    assert filters.compensation_kill(posting, PROFILE) is not None


def test_soft_flags_warn_without_killing() -> None:
    posting = job("Solutions Engineer", description="Partner with customers on delivery.")
    flags = filters.soft_flags(posting, PROFILE)
    assert flags, "expected a soft flag on a Solutions Engineer title"


def test_normalize_company_strips_legal_suffixes() -> None:
    assert filters.normalize_company("Sutter Health, Inc.") == "sutter health"
    assert filters.normalize_company("VSP Global LLC") == "vsp global"
