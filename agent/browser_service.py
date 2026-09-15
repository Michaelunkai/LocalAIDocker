from __future__ import annotations

import ipaddress
import json
import os
import pathlib
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


MAX_OUTPUT_BYTES = 2 * 1024 * 1024
MAX_RUN_SECONDS = 30


def _authorized(handler: BaseHTTPRequestHandler) -> bool:
    key_path = os.environ.get("BROWSER_API_KEY_FILE", "")
    if not key_path:
        return False
    try:
        expected = pathlib.Path(key_path).read_text(encoding="utf-8").strip()
    except OSError:
        return False
    supplied = handler.headers.get("Authorization", "")
    return bool(expected) and supplied == "Bearer " + expected


def _public_url(value: str) -> str:
    parsed = urllib.parse.urlparse(value)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise ValueError("only absolute http and https URLs are accepted")
    if parsed.username or parsed.password:
        raise ValueError("credentials in browser URLs are rejected")
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    addresses = socket.getaddrinfo(parsed.hostname, port, type=socket.SOCK_STREAM)
    if not addresses:
        raise ValueError("browser hostname did not resolve")
    for item in addresses:
        address = ipaddress.ip_address(item[4][0])
        if not address.is_global or address.is_private or address.is_loopback or address.is_link_local:
            raise ValueError("browser target resolves to a non-public address")
    return parsed.geturl()


def _browser_executable() -> str:
    for name in ("chromium", "chromium-browser", "google-chrome"):
        path = shutil.which(name)
        if path:
            return path
    raise RuntimeError("isolated Chromium executable is unavailable")


def _open_page(url: str) -> dict[str, Any]:
    executable = _browser_executable()
    with tempfile.TemporaryDirectory(prefix="localaidocker-browser-") as profile:
        command = [
            executable,
            "--headless=new",
            "--disable-gpu",
            "--disable-dev-shm-usage",
            "--no-first-run",
            "--no-default-browser-check",
            "--user-data-dir=" + profile,
            "--dump-dom",
            "--virtual-time-budget=5000",
            url,
        ]
        started = time.monotonic()
        completed = subprocess.run(
            command,
            capture_output=True,
            text=False,
            timeout=MAX_RUN_SECONDS,
            shell=False,
            check=False,
        )
        output = (completed.stdout or b"") + (completed.stderr or b"")
        clipped = output[:MAX_OUTPUT_BYTES].decode("utf-8", errors="replace")
        return {
            "status": "observed" if completed.returncode == 0 else "failed",
            "requested_url": url,
            "browser": pathlib.Path(executable).name,
            "return_code": completed.returncode,
            "elapsed_ms": int((time.monotonic() - started) * 1000),
            "dom_excerpt": clipped,
            "output_truncated": len(output) > MAX_OUTPUT_BYTES,
        }


class BrowserHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args: object) -> None:
        return

    def _reply(self, code: int, payload: dict[str, Any]) -> None:
        body = (json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path == "/health":
            try:
                browser = pathlib.Path(_browser_executable()).name
                self._reply(200, {"status": "browser-ready", "browser": browser, "isolated": True})
            except RuntimeError as exc:
                self._reply(503, {"status": "browser-unavailable", "reason": str(exc)})
            return
        self._reply(404, {"error": "not found"})

    def do_POST(self) -> None:
        if self.path != "/v1/browser/open":
            self._reply(404, {"error": "not found"})
            return
        if not _authorized(self):
            self._reply(401, {"status": "rejected", "error": "authentication required"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 64 * 1024:
                raise ValueError("invalid request size")
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            url = _public_url(str(payload.get("url", "")))
            self._reply(200, _open_page(url))
        except (ValueError, json.JSONDecodeError, subprocess.TimeoutExpired) as exc:
            self._reply(400, {"status": "rejected", "error": str(exc)})
        except Exception as exc:
            self._reply(500, {"status": "failed", "error": str(exc)})


def main() -> None:
    host, port_text = os.environ.get("BROWSER_BIND", "0.0.0.0:8787").rsplit(":", 1)
    ThreadingHTTPServer((host, int(port_text)), BrowserHandler).serve_forever()


if __name__ == "__main__":
    main()
