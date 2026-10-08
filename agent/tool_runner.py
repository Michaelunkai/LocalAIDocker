from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


ROOT = pathlib.Path(os.environ.get("WORKSPACE_ROOT", "/workspace")).resolve()
PACK = os.environ.get("TOOL_PACK", "unknown")
HOST = os.environ.get("TOOL_RUNNER_BIND", "0.0.0.0:8781")
_, _, port_text = HOST.rpartition(":")
PORT = int(port_text or "8781")
OUTPUT_LIMIT = 200_000
MAX_REQUEST = 2 * 1024 * 1024
BLOCKED_EXECUTABLES = {
    "sudo",
    "su",
    "docker",
    "podman",
    "nerdctl",
    "ssh",
    "scp",
    "sftp",
    "curl",
    "wget",
    "nc",
    "ncat",
    "netcat",
    "rm",
    "rmdir",
    "mkfs",
    "mount",
    "umount",
    "shutdown",
    "reboot",
}
TOOLCHAIN_COMMANDS = {
    "coding": {
        "git": ("git",),
        "rg": ("rg",),
        "fd": ("fd", "fdfind"),
        "gcc": ("gcc",),
        "g++": ("g++",),
        "node": ("node",),
        "npm": ("npm",),
        "go": ("go",),
        "rustc": ("rustc",),
        "cargo": ("cargo",),
        "java": ("java",),
    },
    "media": {
        "ffmpeg": ("ffmpeg",),
        "convert": ("convert",),
        "magick": ("magick",),
    },
    "documents": {
        "pandoc": ("pandoc",),
        "pdftotext": ("pdftotext",),
        "gs": ("gs",),
        "tesseract": ("tesseract",),
    },
}


def _json_bytes(value: dict[str, Any]) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def _bounded_text(data: bytes, limit: int = OUTPUT_LIMIT) -> str:
    if len(data) <= limit:
        return data.decode("utf-8", errors="replace")
    return data[:limit].decode("utf-8", errors="replace") + f"\n[output truncated at {limit} bytes]"


def _scoped_path(value: str) -> pathlib.Path:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise ValueError("invalid working directory")
    candidate = pathlib.Path(value).resolve() if pathlib.Path(value).is_absolute() else (ROOT / value).resolve()
    try:
        candidate.relative_to(ROOT)
    except ValueError as exc:
        raise ValueError("working directory is outside the selected workspace") from exc
    if not candidate.is_dir():
        raise ValueError("working directory is not a workspace directory")
    return candidate


def _run(arguments: dict[str, Any]) -> dict[str, Any]:
    argv = arguments.get("argv")
    if not isinstance(argv, list) or not argv or any(not isinstance(item, str) or not item for item in argv):
        raise ValueError("run requires a non-empty argv array")
    if any("\x00" in item for item in argv):
        raise ValueError("NUL bytes are not allowed in argv")
    executable = pathlib.Path(argv[0]).name.lower()
    if executable in BLOCKED_EXECUTABLES:
        raise ValueError(f"executable is blocked in the isolated {PACK} runner: {executable}")
    cwd = _scoped_path(arguments.get("cwd", "."))
    timeout = min(900, max(1, int(arguments.get("timeout_seconds", 120))))
    env = {
        key: value
        for key, value in os.environ.items()
        if key in {"PATH", "HOME", "LANG", "LC_ALL", "PYTHONPATH"}
    }
    started = time.monotonic()
    timed_out = False
    completed: subprocess.CompletedProcess[bytes] | None = None
    try:
        completed = subprocess.run(
            argv,
            cwd=str(cwd),
            env=env,
            shell=False,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
        output = (completed.stdout or b"") + (completed.stderr or b"")
    except subprocess.TimeoutExpired as exc:
        timed_out = True
        output = (exc.stdout or b"") + (exc.stderr or b"")
    return {
        "status": "timed-out" if timed_out else "completed",
        "pack": PACK,
        "argv": argv,
        "cwd": str(cwd),
        "exit_code": None if completed is None else completed.returncode,
        "elapsed_ms": int((time.monotonic() - started) * 1000),
        "output": _bounded_text(output),
    }


def _status() -> dict[str, Any]:
    expected = TOOLCHAIN_COMMANDS.get(PACK, {})
    present: dict[str, str] = {}
    for logical_name, candidates in expected.items():
        present[logical_name] = next((shutil.which(candidate) or "" for candidate in candidates if shutil.which(candidate)), "")
    missing = [name for name, path in present.items() if not path]
    return {
        "status": "verified" if not missing else "partial",
        "pack": PACK,
        "present": present,
        "missing": missing,
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "LocalAIDockerToolRunner/1"

    def log_message(self, format: str, *args: Any) -> None:
        # Keep diagnostics on stderr; responses are always explicit JSON.
        super().log_message(format, *args)

    def _send(self, status: int, payload: dict[str, Any]) -> None:
        body = _json_bytes(payload)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            self._send(200, {"status": "tool-runner-ready", "pack": PACK})
            return
        if self.path == "/status":
            self._send(200, _status())
            return
        self._send(404, {"status": "error", "reason": "route not found"})

    def do_POST(self) -> None:  # noqa: N802
        if self.path not in {"/v1/run", "/v1/status"}:
            self._send(404, {"status": "error", "reason": "route not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > MAX_REQUEST:
                raise ValueError("request body exceeds the runner limit")
            arguments = json.loads(self.rfile.read(length).decode("utf-8"))
            if not isinstance(arguments, dict):
                raise ValueError("request body must be a JSON object")
            if self.path == "/v1/status":
                self._send(200, _status())
                return
            self._send(200, _run(arguments))
        except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
            self._send(400, {"status": "rejected", "reason": str(exc)})


if __name__ == "__main__":
    ROOT.mkdir(parents=True, exist_ok=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
