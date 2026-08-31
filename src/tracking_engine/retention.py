"""Nightly pruning, run at the end of phase 1a.

The free Supabase tier caps the database at 500 MB. On 2026-08-30 it had
already reached 252 MB after a single night, essentially all of it the raw API
payload column, which is why that column no longer exists. Retention keeps the
remainder flat rather than merely slower-growing.

The work happens in `prune_old_data()` in the database rather than here: it is
several correlated deletes, and doing them in one round trip inside one
transaction is both faster and harder to half-apply.
"""

from __future__ import annotations

import logging
from typing import Any

from supabase import Client

log = logging.getLogger("tracking_engine.retention")

# Phase 3 paints a warning card above this. The cap is 500 MB; 350 leaves room
# to notice and act before anything actually breaks.
WARN_BYTES = 350 * 1024 * 1024


def prune(db: Client) -> dict[str, Any]:
    """Delete stale rows and report what went and how large the database is."""
    response = db.rpc("prune_old_data", {}).execute()
    result = response.data or {}

    log.info(
        "Retention: %s jobs, %s phase_runs, %s email_actions deleted; database %s",
        result.get("jobs_deleted"),
        result.get("phase_runs_deleted"),
        result.get("email_actions_deleted"),
        result.get("db_pretty"),
    )
    if result.get("over_threshold"):
        log.warning(
            "Database is %s, past the %d MB warning line -- phase 3 will flag it",
            result.get("db_pretty"), WARN_BYTES // (1024 * 1024),
        )
    return result
