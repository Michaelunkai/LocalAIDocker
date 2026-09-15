from __future__ import annotations

import json
import os
import urllib.error
import urllib.request


class LocalAIError(RuntimeError):
    pass


def _url(path: str) -> str:
    return os.environ.get("LOCALAI_URL", "http://localai:8080").rstrip("/") + path


def request(path: str, payload: dict | None = None, timeout: float = 180.0) -> dict:
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request_obj = urllib.request.Request(_url(path), data=body, method="POST" if body else "GET")
    request_obj.add_header("Accept", "application/json")
    if body:
        request_obj.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request_obj, timeout=timeout) as response:
            return json.loads(response.read(2_000_000).decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise LocalAIError(str(exc)) from exc

