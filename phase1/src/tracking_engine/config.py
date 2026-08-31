"""Config loading.

`profile.yaml` is public and holds every tunable decision. `identity.yaml` is
gitignored and holds personal details; nothing in the ingest or filter path
touches it, so its absence is not an error here.
"""

from __future__ import annotations

import functools
import re
from pathlib import Path
from typing import Any

import yaml


def _find_repo_root() -> Path:
    """Walk up until the shared config directory turns up.

    Counting parents broke the moment this package moved into phase1/. Looking
    for a landmark survives the next reorganization too, and config/ is shared
    by every phase so it will not move without the whole repo moving.
    """
    for candidate in Path(__file__).resolve().parents:
        if (candidate / "config" / "profile.yaml").is_file():
            return candidate
    raise FileNotFoundError(
        f"config/profile.yaml not found above {Path(__file__).resolve()}"
    )


REPO_ROOT = _find_repo_root()
CONFIG_DIR = REPO_ROOT / "config"


def _load_yaml(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as fh:
        return yaml.safe_load(fh) or {}


@functools.lru_cache(maxsize=1)
def load_profile(path: Path | None = None) -> dict[str, Any]:
    return _load_yaml(path or CONFIG_DIR / "profile.yaml")


@functools.lru_cache(maxsize=1)
def load_companies(path: Path | None = None) -> list[dict[str, Any]]:
    data = _load_yaml(path or CONFIG_DIR / "companies.yaml")
    return data.get("companies", [])


@functools.lru_cache(maxsize=1)
def load_bullets(path: Path | None = None) -> dict[str, Any]:
    return _load_yaml(path or CONFIG_DIR / "bullets.yaml")


def load_identity(path: Path | None = None) -> dict[str, Any]:
    """Personal fields. Returns {} when the file is absent.

    A fresh clone has no identity.yaml -- that is the expected state, not a
    failure. Only the tailoring step needs it, and it runs elsewhere.
    """
    target = path or CONFIG_DIR / "identity.yaml"
    if not target.exists():
        return {}
    return _load_yaml(target)


@functools.lru_cache(maxsize=256)
def compiled(pattern: str) -> re.Pattern[str]:
    """Compile once. The filter runs these over thousands of postings a night."""
    return re.compile(pattern)
