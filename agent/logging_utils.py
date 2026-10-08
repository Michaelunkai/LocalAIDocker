from __future__ import annotations

import hashlib
import json
import logging
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


_CONFIGURED: set[str] = set()


def configure_logging(component: str) -> logging.Logger:
    """Create redacted JSON-lines logging for a long-running service.

    The service logs are deliberately metadata-only.  Request bodies, prompts,
    headers, URLs, filesystem paths, commands, and credentials never enter the
    durable log stream.
    """
    logger = logging.getLogger(f"localaidocker.{component}")
    logger.setLevel(logging.INFO)
    logger.propagate = False
    if component in _CONFIGURED:
        return logger

    formatter = logging.Formatter("%(message)s")
    stream = logging.StreamHandler()
    stream.setFormatter(formatter)
    logger.addHandler(stream)

    log_file = os.environ.get("LOG_FILE", "").strip()
    if log_file:
        try:
            path = Path(log_file)
            path.parent.mkdir(parents=True, exist_ok=True)
            file_handler = logging.FileHandler(path, encoding="utf-8")
            file_handler.setFormatter(formatter)
            logger.addHandler(file_handler)
        except OSError:
            # Docker stdout/stderr remains the fallback evidence channel.
            logger.warning(json.dumps({"event": "log_file_unavailable", "component": component}))

    _CONFIGURED.add(component)
    return logger


def identifier_hash(value: object) -> str:
    """Return a short stable identifier for log correlation without disclosure."""
    return hashlib.sha256(str(value).encode("utf-8", "replace")).hexdigest()[:16]


def emit_event(logger: logging.Logger, event: str, **fields: Any) -> None:
    """Emit a small, safe JSON record.

    This is a second defense against accidental sensitive-data logging if a
    caller later adds a field with an unsafe name.
    """
    blocked_fragments = (
        "body",
        "content",
        "cookie",
        "credential",
        "header",
        "key",
        "message",
        "password",
        "path",
        "prompt",
        "secret",
        "token",
        "url",
    )
    safe: dict[str, Any] = {
        "ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
        "event": event,
    }
    for raw_name, value in fields.items():
        name = str(raw_name)
        if any(fragment in name.lower() for fragment in blocked_fragments):
            continue
        if isinstance(value, (str, int, float, bool)) or value is None:
            safe[name] = value if not isinstance(value, str) else value[:128]
        else:
            safe[name] = str(value)[:128]
    logger.info(json.dumps(safe, ensure_ascii=True, sort_keys=True))
