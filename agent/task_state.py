from __future__ import annotations

import json
import os
import tempfile
import time
from pathlib import Path


def save_checkpoint(task_id: str, state: dict) -> Path:
    root = Path(os.environ.get("TASK_STATE_ROOT", "/workspace/state"))
    root.mkdir(parents=True, exist_ok=True)
    target = root / f"{task_id}.json"
    state = {"schema_version": 1, "task_id": task_id, "updated_at": time.time(), **state}
    fd, temp_name = tempfile.mkstemp(prefix=f".{task_id}.", dir=root)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(state, handle, sort_keys=True)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, target)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)
    return target

