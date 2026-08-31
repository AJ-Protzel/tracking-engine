"""Find and validate a company's ATS slug.

Slugs are the fiddliest part of the company list: plenty of employers use a slug
that looks nothing like their name, and a wrong one fails silently as an empty
board rather than as an error. Nothing goes into `companies.yaml` without being
confirmed against the live endpoint here.

    python -m tracking_engine.find_slug "Blue Shield of California" "Sutter Health"
    python -m tracking_engine.find_slug --slug blueshieldca

A non-empty board is necessary but NOT sufficient. Guessing falls back to the
first word and to initials, and those land on a real board belonging to somebody
else often enough to matter: `lever/blue` is BlueCloud Services, not Blue Shield
of California, and it answers with ten live postings. Adopting it would file
another company's jobs under this employer's name, which no later step can
detect. So every hit is checked against the name the board itself reports, and a
disagreement prints MISMATCH instead of CONFIRMED.
"""

from __future__ import annotations

import argparse
import re
import sys

from .sources import ATS_MODULES, ashby, recruitee
from .sources.base import BoardNotFound, SourceUnavailable, get_json


def candidate_slugs(name: str) -> list[str]:
    """Plausible slugs for a company name, most likely first."""
    cleaned = re.sub(r"[^\w\s-]", "", name.casefold()).strip()
    words = [w for w in cleaned.split() if w not in {"the", "of", "and", "inc", "llc", "corp"}]

    joined = "".join(words)
    hyphenated = "-".join(words)

    candidates = [joined, hyphenated]
    if len(words) > 1:
        candidates.append(words[0])
        candidates.append("".join(w[0] for w in words))
    return list(dict.fromkeys(c for c in candidates if c))


def _key(text: str) -> str:
    return re.sub(r"[^a-z0-9]", "", (text or "").casefold())


def reported_name(ats: str, slug: str) -> str | None:
    """The company name the ATS itself reports for this board.

    Returns None when the ATS exposes no company field, which is a real state
    and not a failure -- Lever's public API has no such field at all. An
    unverifiable board is reported as UNVERIFIED so it gets a human look rather
    than being quietly adopted.
    """
    try:
        if ats == "greenhouse":
            payload = get_json(f"https://boards-api.greenhouse.io/v1/boards/{slug}")
            return (payload or {}).get("name")
        if ats == "workable":
            payload = get_json(f"https://www.workable.com/api/accounts/{slug}")
            return (payload or {}).get("name")
        if ats == "ashby":
            jobs = (get_json(ashby.BASE.format(slug=slug)) or {}).get("jobs") or []
            return jobs[0].get("organizationName") if jobs else None
        if ats == "recruitee":
            offers = (get_json(recruitee.BASE.format(slug=slug)) or {}).get("offers") or []
            return offers[0].get("company_name") if offers else None
    except (BoardNotFound, SourceUnavailable):
        return None
    return None


def owns(name: str, ats: str, slug: str) -> tuple[bool | None, str | None]:
    """Does this board belong to `name`? (True/False/None-for-unverifiable.)"""
    expected, slug_key = _key(name), _key(slug)
    if slug_key and slug_key == expected:
        return True, None

    reported = reported_name(ats, slug)
    if reported is None:
        return None, None
    got = _key(reported)
    match = bool(got) and (got in expected or expected in got)
    return match, reported


def probe(slug: str) -> list[tuple[str, int]]:
    """Try a slug against all five ATS endpoints. Returns (ats, job_count)."""
    hits: list[tuple[str, int]] = []
    for ats, module in ATS_MODULES.items():
        try:
            jobs = module.fetch(slug)
        except BoardNotFound:
            continue
        except SourceUnavailable as exc:
            print(f"  {ats:<11} unavailable: {exc}", file=sys.stderr)
            continue
        # An empty board is not proof of a correct slug -- some ATSes return an
        # empty list for anything. Only a non-empty board confirms it.
        if jobs:
            hits.append((ats, len(jobs)))
    return hits


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate ATS slugs against live endpoints.")
    parser.add_argument("names", nargs="*", help="Company names to guess slugs for.")
    parser.add_argument("--slug", action="append", default=[],
                        help="Test an exact slug instead of guessing.")
    args = parser.parse_args(argv)

    if not args.names and not args.slug:
        parser.error("give at least one company name or --slug")

    for slug in args.slug:
        print(f"{slug}:")
        for ats, count in probe(slug) or []:
            reported = reported_name(ats, slug)
            who = f" -- board reports {reported!r}" if reported else ""
            print(f"  FOUND      {ats:<11} {count} postings{who}")

    for name in args.names:
        print(f"\n{name}")
        for slug in candidate_slugs(name):
            hits = probe(slug)
            for ats, count in hits:
                match, reported = owns(name, ats, slug)
                verdict = {True: "CONFIRMED", False: "MISMATCH ", None: "UNVERIFIED"}[match]
                who = f" -- board reports {reported!r}" if reported else ""
                print(f"  {verdict}  ats: {ats:<11} slug: {slug:<24} "
                      f"({count} postings){who}")
            if hits:
                break
        else:
            print("  no board found -- check their careers page URL by hand")

    return 0


if __name__ == "__main__":
    sys.exit(main())
