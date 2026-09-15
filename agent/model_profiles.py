from __future__ import annotations

import json
from pathlib import Path


def load_models(path: str = "/app/config/models.lock.json") -> list[dict]:
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle).get("models", [])


def choose(profile: str, path: str = "/app/config/models.lock.json") -> dict:
    candidates = [item for item in load_models(path) if profile in item.get("profiles", [])]
    if not candidates:
        raise LookupError(f"no locked model is available for profile {profile}")
    return candidates[0]

