from __future__ import annotations

import hashlib
import ipaddress
import json
import os
import pathlib
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from .policy import PolicyError, scoped_path, workspace_root


@dataclass(frozen=True)
class ToolSpec:
    name: str
    description: str
    mutability: str
    privilege: str
    network: str
    scope: str
    confirmation: str
    pack: str = "core"
    timeout_seconds: int = 120
    output_limit_bytes: int = 200_000
    input_schema: dict[str, Any] | None = None

    def manifest(self) -> dict[str, Any]:
        result = asdict(self)
        if result["input_schema"] is None:
            result["input_schema"] = {"type": "object"}
        return result


_POLICY_FIELDS = ("mutability", "privilege", "network", "scope", "confirmation")
_POLICY_CACHE: dict[str, Any] | None = None
_POLICY_LOAD_ERROR: str | None = None


def _policy_candidates() -> list[Path]:
    candidates: list[Path] = []
    configured = os.environ.get("POLICY_FILE", "").strip()
    if configured:
        candidates.append(Path(configured))
    candidates.append(Path("/app/config/policy.json"))
    candidates.append(Path(__file__).resolve().parents[1] / "config" / "policy.json")
    result: list[Path] = []
    for candidate in candidates:
        if candidate not in result:
            result.append(candidate)
    return result


def _load_declared_policy() -> dict[str, Any] | None:
    global _POLICY_CACHE, _POLICY_LOAD_ERROR
    if _POLICY_CACHE is not None or _POLICY_LOAD_ERROR is not None:
        return _POLICY_CACHE
    for path in _policy_candidates():
        try:
            if not path.is_file():
                continue
            with path.open("r", encoding="utf-8") as handle:
                loaded = json.load(handle)
            if not isinstance(loaded, dict) or not isinstance(loaded.get("tools"), dict):
                raise ValueError("policy manifest must contain a tools object")
            _POLICY_CACHE = loaded
            return _POLICY_CACHE
        except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
            _POLICY_LOAD_ERROR = f"{path}: {exc}"
            return None
    _POLICY_LOAD_ERROR = "no policy manifest was found"
    return None


def policy_validation_errors() -> list[str]:
    policy = _load_declared_policy()
    if policy is None:
        return [_POLICY_LOAD_ERROR or "policy manifest could not be loaded"]
    declared = policy.get("tools", {})
    errors: list[str] = []
    for name, spec in REGISTRY.items():
        entry = declared.get(name)
        if not isinstance(entry, dict):
            errors.append(f"{name}: missing from policy manifest")
            continue
        for field in _POLICY_FIELDS:
            if entry.get(field) != getattr(spec, field):
                errors.append(f"{name}: policy field {field} does not match registry")
        if entry.get("pack", "core") != spec.pack:
            errors.append(f"{name}: policy field pack does not match registry")
        if int(entry.get("timeout_seconds", spec.timeout_seconds)) != spec.timeout_seconds:
            errors.append(f"{name}: policy timeout does not match registry")
        if int(entry.get("output_limit_bytes", spec.output_limit_bytes)) != spec.output_limit_bytes:
            errors.append(f"{name}: policy output limit does not match registry")
    extras = sorted(set(declared) - set(REGISTRY))
    errors.extend(f"{name}: policy declares an unimplemented tool" for name in extras)
    return errors


def _policy_allows(spec: ToolSpec) -> bool:
    return not any(error.startswith(spec.name + ":") for error in policy_validation_errors())


REGISTRY: dict[str, ToolSpec] = {
    "read_file": ToolSpec(
        "read_file",
        "Read a UTF-8 text file inside the agent workspace.",
        "read",
        "user",
        "none",
        "workspace",
        "none",
        input_schema={"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]},
    ),
    "write_file": ToolSpec(
        "write_file",
        "Atomically write a UTF-8 file inside the agent workspace.",
        "write",
        "user",
        "none",
        "workspace",
        "per-task",
        input_schema={"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}, "required": ["path", "content"]},
    ),
    "run_command": ToolSpec(
        "run_command",
        "Run one structured argv command in the agent workspace without a shell.",
        "external-effect",
        "user",
        "none",
        "workspace",
        "per-task",
        timeout_seconds=120,
        input_schema={"type": "object", "properties": {"argv": {"type": "array", "items": {"type": "string"}}, "cwd": {"type": "string"}, "timeout_seconds": {"type": "integer"}}, "required": ["argv"]},
    ),
    "list_windows_directories": ToolSpec(
        "list_windows_directories",
        "List directories inside the explicitly configured LocalAIDocker project root, including recursive subdirectories when requested.",
        "read",
        "user",
        "host-local",
        "windows-read-only",
        "per-task",
        timeout_seconds=330,
        output_limit_bytes=20_000_000,
        input_schema={"type": "object", "properties": {"path": {"type": "string"}, "recursive": {"type": "boolean"}, "max_items": {"type": "integer"}}, "required": ["path"]},
    ),
    "read_windows_file": ToolSpec(
        "read_windows_file",
        "Read a bounded UTF-8 file from the explicitly configured LocalAIDocker project root.",
        "read",
        "user",
        "host-local",
        "windows-read-only",
        "per-task",
        timeout_seconds=30,
        input_schema={"type": "object", "properties": {"path": {"type": "string"}, "max_bytes": {"type": "integer"}}, "required": ["path"]},
    ),
    "write_windows_file": ToolSpec(
        "write_windows_file",
        "Atomically write a file inside the LocalAIDocker project through the authenticated host bridge.",
        "write",
        "user",
        "host-local",
        "project-write",
        "per-action",
        input_schema={"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}, "required": ["path", "content"]},
    ),
    "browser_open_url": ToolSpec(
        "browser_open_url",
        "Open an http or https URL in the isolated browser service; opening is reported separately from observation or control.",
        "external-effect",
        "user",
        "public-read",
        "isolated-browser",
        "per-action",
        pack="browser",
        timeout_seconds=35,
        input_schema={"type": "object", "properties": {"url": {"type": "string"}}, "required": ["url"]},
    ),
    "open_default_browser": ToolSpec(
        "open_default_browser",
        "Open a URL in the installed Windows Chrome browser as a new tab. The result proves launch was requested, not that a tab was observed or controlled.",
        "external-effect",
        "user",
        "host-local",
        "default-browser",
        "per-action",
        timeout_seconds=35,
        input_schema={"type": "object", "properties": {"url": {"type": "string"}, "new_tab": {"type": "boolean"}}, "required": ["url"]},
    ),
    "list_processes": ToolSpec(
        "list_processes",
        "List a bounded snapshot of Windows processes through the local bridge.",
        "read",
        "user",
        "host-local",
        "process-list",
        "per-task",
        timeout_seconds=30,
        input_schema={"type": "object", "properties": {}},
    ),
    "research_fetch": ToolSpec(
        "research_fetch",
        "Fetch a public web URL with bounded size and timeout.",
        "external-effect",
        "user",
        "public-read",
        "temporary",
        "per-action",
        pack="research",
        timeout_seconds=20,
        output_limit_bytes=2_000_000,
        input_schema={"type": "object", "properties": {"url": {"type": "string"}}, "required": ["url"]},
    ),
    "coding_toolchain_status": ToolSpec(
        "coding_toolchain_status",
        "Report the verified coding executables present in the isolated agent image.",
        "read",
        "user",
        "none",
        "container-toolchain",
        "none",
        pack="coding",
        input_schema={"type": "object", "properties": {}},
    ),
    "media_toolchain_status": ToolSpec(
        "media_toolchain_status",
        "Report the verified media executables present in the isolated agent image.",
        "read",
        "user",
        "none",
        "container-toolchain",
        "none",
        pack="media",
        input_schema={"type": "object", "properties": {}},
    ),
    "document_toolchain_status": ToolSpec(
        "document_toolchain_status",
        "Report the verified document executables present in the isolated agent image.",
        "read",
        "user",
        "none",
        "container-toolchain",
        "none",
        pack="documents",
        input_schema={"type": "object", "properties": {}},
    ),
}


def enabled_tools(installed_packs: set[str]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for spec in REGISTRY.values():
        if not _policy_allows(spec):
            continue
        if spec.pack != "core" and spec.pack not in installed_packs:
            continue
        if spec.network == "host-local" and os.environ.get("HOST_BRIDGE_AVAILABLE", "0") != "1":
            continue
        result.append(spec.manifest())
    return result


def _sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _bounded_text(data: bytes, limit: int) -> str:
    if len(data) <= limit:
        return data.decode("utf-8", errors="replace")
    return data[:limit].decode("utf-8", errors="replace") + f"\n[output truncated at {limit} bytes]"


_RUNNER_ENV = {
    "coding": "CODING_RUNNER_URL",
    "media": "MEDIA_RUNNER_URL",
    "documents": "DOCUMENTS_RUNNER_URL",
}
_RUNNER_COMMANDS = {
    "coding": {
        "git", "rg", "fd", "fdfind", "gcc", "g++", "cc", "c++", "make",
        "node", "npm", "npx", "go", "rustc", "cargo", "java", "javac",
        "pytest", "python", "python3", "dotnet", "ruby", "php", "lua",
    },
    "media": {"ffmpeg", "ffprobe", "convert", "magick", "identify"},
    "documents": {"pandoc", "pdftotext", "pdfinfo", "gs", "tesseract"},
}


def _installed_packs() -> set[str]:
    return {item.strip().lower() for item in os.environ.get("AGENT_PACKS", "core").split(",") if item.strip()}


def _runner_pack(argv: list[str]) -> str | None:
    executable = pathlib.Path(argv[0]).name.lower()
    installed = _installed_packs()
    for pack, commands in _RUNNER_COMMANDS.items():
        if pack in installed and executable in commands:
            return pack
    return None


def _runner_request(pack: str, route: str, arguments: dict[str, Any], timeout: float = 30.0) -> dict[str, Any]:
    variable = _RUNNER_ENV[pack]
    base = os.environ.get(variable, "").rstrip("/")
    if not base:
        raise PolicyError(f"{pack} capability runner is not configured")
    body = json.dumps(arguments).encode("utf-8")
    request = urllib.request.Request(base + route, data=body if arguments else None, method="POST" if arguments else "GET")
    if arguments:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            result = json.loads(response.read(3 * 1024 * 1024).decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read(4096).decode("utf-8", errors="replace")
        raise PolicyError(f"{pack} capability runner rejected the request ({exc.code}): {detail}") from exc
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise PolicyError(f"{pack} capability runner is unavailable: {exc}") from exc
    if not isinstance(result, dict):
        raise PolicyError(f"{pack} capability runner returned an invalid response")
    return result


def _read_workspace_file(arguments: dict[str, Any]) -> dict[str, Any]:
    path = scoped_path(str(arguments.get("path", "")))
    if not path.is_file():
        raise PolicyError("the selected workspace path is not a file")
    limit = min(16 * 1024 * 1024, max(1, int(arguments.get("max_bytes", 4 * 1024 * 1024))))
    if path.stat().st_size > limit:
        raise PolicyError(f"file exceeds the read limit of {limit} bytes")
    raw = path.read_bytes()
    return {"status": "verified", "path": str(path), "bytes": len(raw), "sha256": _sha256(path), "text": raw.decode("utf-8", errors="replace")}


def _write_workspace_file(arguments: dict[str, Any]) -> dict[str, Any]:
    path = scoped_path(str(arguments.get("path", "")))
    root = workspace_root()
    if path == root:
        raise PolicyError("a directory cannot be replaced")
    path.parent.mkdir(parents=True, exist_ok=True)
    backup: str | None = None
    if path.exists():
        if not path.is_file():
            raise PolicyError("the destination is not a regular file")
        backup_path = path.with_name(path.name + f".bak.{int(time.time())}")
        shutil.copy2(path, backup_path)
        backup = str(backup_path)
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = pathlib.Path(temporary_name)
    try:
        content = str(arguments.get("content", "")).encode("utf-8")
        with os.fdopen(fd, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        return {"status": "verified", "path": str(path), "bytes": len(content), "sha256": _sha256(path), "backup": backup}
    finally:
        temporary.unlink(missing_ok=True)


def _run_command(arguments: dict[str, Any]) -> dict[str, Any]:
    argv = arguments.get("argv")
    if not isinstance(argv, list) or not argv or any(not isinstance(value, str) or not value for value in argv):
        raise PolicyError("run_command requires a non-empty argv array")
    if any("\x00" in value for value in argv):
        raise PolicyError("NUL bytes are not allowed in argv")
    runner_pack = _runner_pack(argv)
    if runner_pack:
        return _runner_request(runner_pack, "/v1/run", arguments, timeout= min(900.0, max(1.0, float(arguments.get("timeout_seconds", 120)) + 5.0)))
    cwd = scoped_path(str(arguments.get("cwd", ".")))
    if not cwd.is_dir():
        raise PolicyError("command cwd is not a workspace directory")
    timeout = min(900, max(1, int(arguments.get("timeout_seconds", 120))))
    env = {key: value for key, value in os.environ.items() if key in {"PATH", "HOME", "LANG", "LC_ALL", "PYTHONPATH"}}
    started = time.monotonic()
    try:
        completed = subprocess.run(argv, cwd=str(cwd), env=env, shell=False, capture_output=True, text=False, timeout=timeout, check=False)
        timed_out = False
    except subprocess.TimeoutExpired as exc:
        completed = None
        timed_out = True
        output = (exc.stdout or b"") + (exc.stderr or b"")
    else:
        output = (completed.stdout or b"") + (completed.stderr or b"")
    return {
        "status": "timed-out" if timed_out else "completed",
        "argv": argv,
        "cwd": str(cwd),
        "exit_code": None if completed is None else completed.returncode,
        "elapsed_ms": int((time.monotonic() - started) * 1000),
        "output": _bounded_text(output, REGISTRY["run_command"].output_limit_bytes),
    }


def _bridge_request(
    route: str,
    arguments: dict[str, Any],
    timeout: float = 30.0,
    explicit_user_intent: bool = False,
) -> dict[str, Any]:
    base = os.environ.get("HOST_BRIDGE_URL", "http://gateway:8080/host-bridge").rstrip("/")
    key_path = pathlib.Path(os.environ.get("HOST_BRIDGE_KEY_FILE", "/run/secrets/host_bridge_key"))
    try:
        key = key_path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise PolicyError(f"host bridge credential is unavailable: {exc}") from exc
    if not key:
        raise PolicyError("host bridge credential is empty")
    body = json.dumps(arguments).encode("utf-8")
    request = urllib.request.Request(base + route, data=body, method="POST")
    request.add_header("Authorization", "Bearer " + key)
    request.add_header("Content-Type", "application/json")
    if explicit_user_intent:
        request.add_header("X-LocalAIDocker-User-Intent", "explicit")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            result = json.loads(response.read(20 * 1024 * 1024).decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read(4096).decode("utf-8", errors="replace")
        raise PolicyError(f"host bridge rejected the request ({exc.code}): {detail}") from exc
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise PolicyError(f"host bridge unavailable: {exc}") from exc
    if not isinstance(result, dict):
        raise PolicyError("host bridge returned an invalid response")
    return result


def _browser_request(arguments: dict[str, Any], timeout: float = 35.0) -> dict[str, Any]:
    base = os.environ.get("BROWSER_URL", "http://browser:8787").rstrip("/")
    key_path = pathlib.Path(os.environ.get("BROWSER_API_KEY_FILE", "/run/secrets/browser_api_key"))
    try:
        key = key_path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise PolicyError(f"browser capability credential is unavailable: {exc}") from exc
    if not key:
        raise PolicyError("browser capability credential is empty")
    body = json.dumps(arguments).encode("utf-8")
    request = urllib.request.Request(base + "/v1/browser/open", data=body, method="POST")
    request.add_header("Authorization", "Bearer " + key)
    request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            result = json.loads(response.read(3 * 1024 * 1024).decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read(4096).decode("utf-8", errors="replace")
        raise PolicyError(f"isolated browser rejected the request ({exc.code}): {detail}") from exc
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise PolicyError(f"isolated browser unavailable: {exc}") from exc
    if not isinstance(result, dict):
        raise PolicyError("isolated browser returned an invalid response")
    return result


def _public_addresses(hostname: str, port: int) -> list[str]:
    try:
        raw = socket.getaddrinfo(hostname, port, type=socket.SOCK_STREAM)
    except socket.gaierror as exc:
        raise PolicyError(f"research hostname did not resolve: {hostname}") from exc
    addresses: list[str] = []
    for item in raw:
        address = item[4][0]
        try:
            parsed = ipaddress.ip_address(address)
        except ValueError as exc:
            raise PolicyError(f"research hostname returned an invalid address: {address}") from exc
        # IPv4-mapped IPv6 addresses otherwise look like an IPv6 result while
        # carrying an IPv4 private/loopback destination.  Apply the policy to
        # the mapped IPv4 value as well, preventing a DNS result from bypassing
        # the public-target check through ::ffff:x.x.x.x notation.
        policy_address = getattr(parsed, "ipv4_mapped", None) or parsed
        if (
            not policy_address.is_global
            or policy_address.is_private
            or policy_address.is_loopback
            or policy_address.is_link_local
            or policy_address.is_multicast
            or policy_address.is_reserved
            or policy_address.is_unspecified
        ):
            raise PolicyError(f"research target resolves to a non-public address: {address}")
        if address not in addresses:
            addresses.append(address)
    if not addresses:
        raise PolicyError("research hostname has no usable public address")
    return addresses


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req: urllib.request.Request, fp: Any, code: int, msg: str, headers: Any, newurl: str) -> None:
        return None


def _research_fetch(arguments: dict[str, Any]) -> dict[str, Any]:
    url = str(arguments.get("url", ""))
    current_url = url
    opener = urllib.request.build_opener(_NoRedirect())
    for redirect_count in range(4):
        parsed = urllib.parse.urlparse(current_url)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname:
            raise PolicyError("research_fetch accepts only an absolute http or https URL")
        if parsed.username or parsed.password:
            raise PolicyError("credentials in research URLs are rejected")
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
        _public_addresses(parsed.hostname, port)
        request = urllib.request.Request(
            current_url,
            headers={
                "User-Agent": "LocalAIDocker-Research/2",
                "Accept": "text/html,text/plain,application/json,application/xml,text/xml,application/pdf;q=0.5,*/*;q=0.1",
            },
        )
        try:
            with opener.open(request, timeout=20) as response:
                content_type = response.headers.get_content_type().lower()
                if not (
                    content_type.startswith("text/")
                    or content_type in {"application/json", "application/xml", "text/xml", "application/pdf"}
                ):
                    raise PolicyError(f"research response content type is not accepted: {content_type}")
                raw = response.read(2 * 1024 * 1024 + 1)
                if len(raw) > 2 * 1024 * 1024:
                    raise PolicyError("research response exceeds the 2 MiB limit")
                return {
                    "status": "verified",
                    "url": current_url,
                    "content_type": content_type,
                    "retrieved_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "text": _bounded_text(raw, 2 * 1024 * 1024),
                }
        except urllib.error.HTTPError as exc:
            if exc.code not in {301, 302, 303, 307, 308}:
                raise PolicyError(f"research fetch failed with HTTP {exc.code}") from exc
            location = exc.headers.get("Location")
            if not location:
                raise PolicyError("research redirect did not provide a destination") from exc
            current_url = urllib.parse.urljoin(current_url, location)
            continue
        except urllib.error.URLError as exc:
            raise PolicyError(f"research fetch failed: {exc}") from exc
    raise PolicyError("research redirect limit exceeded")


def _toolchain_status(pack: str) -> dict[str, Any]:
    if pack not in _installed_packs():
        raise PolicyError(f"{pack} capability pack is not installed")
    return _runner_request(pack, "/status", {})


def execute_tool(name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    if name not in REGISTRY:
        raise PolicyError(f"unknown tool: {name}")
    spec = REGISTRY[name]
    if not _policy_allows(spec):
        raise PolicyError(f"tool '{name}' is unavailable because the policy manifest does not verify it")
    if spec.network == "host-local" and os.environ.get("HOST_BRIDGE_AVAILABLE", "0") != "1":
        raise PolicyError("host interoperability bridge is unavailable")
    if name == "read_file":
        return _read_workspace_file(arguments)
    if name == "write_file":
        return _write_workspace_file(arguments)
    if name == "run_command":
        return _run_command(arguments)
    if name == "list_windows_directories":
        return _bridge_request("/v1/files/list", arguments, timeout=330.0)
    if name == "read_windows_file":
        return _bridge_request("/v1/files/read", arguments)
    if name == "write_windows_file":
        return _bridge_request("/v1/files/write", arguments, explicit_user_intent=True)
    if name == "browser_open_url":
        return _browser_request(arguments)
    if name == "open_default_browser":
        return _bridge_request("/v1/browser/open", arguments, timeout=35.0, explicit_user_intent=True)
    if name == "list_processes":
        return _bridge_request("/v1/process/list", arguments)
    if name == "research_fetch":
        return _research_fetch(arguments)
    if name == "coding_toolchain_status":
        return _toolchain_status("coding")
    if name == "media_toolchain_status":
        return _toolchain_status("media")
    if name == "document_toolchain_status":
        return _toolchain_status("documents")
    raise PolicyError(f"tool is not implemented: {name}")
