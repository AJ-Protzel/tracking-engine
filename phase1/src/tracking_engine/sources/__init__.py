"""Source connectors.

Every module here exports `SOURCE` and a `fetch()` that returns `list[RawJob]`.
Nothing else about a source leaks past this package.

Two shapes:
  * Per-company (greenhouse, lever, ashby, workable, recruitee) -- called once
    per slug in `companies.yaml`.
  * Board-wide (remotive, remoteok) -- called once per run.

USAJOBS and Adzuna are specified in the design and not built yet: both need a
free API key, and v1 deliberately ships without blocking on those signups.
"""

from . import ashby, greenhouse, lever, recruitee, remoteok, remotive, workable

ATS_MODULES = {
    "greenhouse": greenhouse,
    "lever": lever,
    "ashby": ashby,
    "workable": workable,
    "recruitee": recruitee,
}

BOARD_MODULES = {
    "remotive": remotive,
    "remoteok": remoteok,
}

# Sources that list only remote roles. Their location field describes *where a
# candidate may sit*, not an office -- so an empty or generic value means
# "anywhere", where on an ATS board it would just mean "unspecified".
#
# This does NOT make every posting on them US-eligible: both carry plenty of
# "Remote - Toronto" and "Remote - India" roles, which still get judged on the
# place they name.
REMOTE_ONLY_SOURCES = frozenset({"remotive", "remoteok"})

__all__ = ["ATS_MODULES", "BOARD_MODULES", "REMOTE_ONLY_SOURCES"]
