from __future__ import annotations

import json
import os
from pathlib import Path


class PolicyError(ValueError):
    pass


def workspace_root() -> Path:
    root = Path(os.environ.get("WORKSPACE_ROOT", "/workspace")).resolve()
    root.mkdir(parents=True, exist_ok=True)
    return root


def scoped_path(user_path: str) -> Path:
    if not user_path or "\x00" in user_path:
        raise PolicyError("invalid path")
    root = workspace_root()
    candidate = (root / user_path).resolve() if not os.path.isabs(user_path) else Path(user_path).resolve()
    try:
        candidate.relative_to(root)
    except ValueError as exc:
        raise PolicyError("path is outside the selected workspace") from exc
    return candidate


def load_policy(path: str = "/app/config/policy.json") -> dict:
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)

