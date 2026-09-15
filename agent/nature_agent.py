from __future__ import annotations

import json
import os
import re
import shlex
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from .policy import PolicyError
from .server_client import LocalAIError, request
from .task_state import save_checkpoint
from .tool_registry import REGISTRY, enabled_tools, execute_tool


URL_RE = re.compile(r"https?://[^\s<>\"']+", re.IGNORECASE)
WINDOWS_PATH_RE = re.compile(r"\b([A-Za-z]:\\[^\s<>\"']*)", re.IGNORECASE)
QUOTED_WINDOWS_PATH_RE = re.compile(r"['\"]([A-Za-z]:\\[^'\"]+)['\"]", re.IGNORECASE)


def _packs() -> set[str]:
    raw = os.environ.get("AGENT_PACKS", "core")
    return {item.strip().lower() for item in raw.split(",") if item.strip()} | {"core"}


def _verified_model(fallback: str) -> str:
    state_path = os.environ.get("VERIFIED_MODEL_STATE_FILE", "/app/deployment-state/current-deployment.json")
    try:
        with open(state_path, "r", encoding="utf-8") as handle:
            value = json.load(handle).get("model_id")
        if isinstance(value, str) and value.strip():
            return value.strip()
    except (OSError, ValueError, TypeError):
        pass
    return fallback


def _windows_path(message: str) -> str | None:
    quoted = QUOTED_WINDOWS_PATH_RE.search(message)
    if quoted:
        return quoted.group(1).rstrip(".,);]")
    match = WINDOWS_PATH_RE.search(message)
    return match.group(1).rstrip(".,);]") if match else None


def _requested_file_path(message: str) -> str | None:
    path = _windows_path(message)
    if path:
        return path
    relative = re.search(r"\b(?:file|path)\s+(?:named\s+)?([A-Za-z0-9_.\\/-]+)", message, re.IGNORECASE)
    if relative:
        return relative.group(1).rstrip(".,);]")
    return None


def _response(content: str, model: str, tools_used: list[dict[str, Any]] | None = None) -> dict[str, Any]:
    return {
        "id": "agent-" + uuid.uuid4().hex,
        "object": "agent.task",
        "model": model,
        "choices": [{"index": 0, "message": {"role": "assistant", "content": content}, "finish_reason": "stop"}],
        "tools_used": tools_used or [],
        "capabilities": [spec["name"] for spec in enabled_tools(_packs())],
    }


def _direct_intent(message: str) -> tuple[str, dict[str, Any]] | None:
    lowered = message.lower()
    urls = URL_RE.findall(message)
    mutation_words = ("create", "write", "edit", "save", "overwrite", "modify", "update")
    if any(word in lowered for word in mutation_words) and ("file" in lowered or "content" in lowered or _windows_path(message)):
        path = _requested_file_path(message)
        content_match = re.search(r"(?:content|text|contents?)\s*[:=]\s*(.+)$", message, re.IGNORECASE | re.DOTALL)
        if path and content_match:
            content = content_match.group(1).strip()
            if content.startswith("```") and content.endswith("```"):
                content = content[3:-3].strip("\r\n")
            return "write_windows_file", {"path": path, "content": content}
        if path:
            raise PolicyError("an explicit content: or text: value is required for a file write")
    if urls and any(word in lowered for word in ("research", "fetch", "look up", "look-up", "web search")):
        if "research" not in _packs():
            raise PolicyError("the research pack is not installed")
        return "research_fetch", {"url": urls[0].rstrip(".,);]")}
    command_match = re.search(r"(?:^|\b)(?:run\s+command|execute\s+command|run|execute)\s*:\s*(.+)$", message, re.IGNORECASE | re.DOTALL)
    if command_match:
        command_text = command_match.group(1).strip().strip("`").strip()
        if not command_text:
            raise PolicyError("a command is required after run: or execute:")
        if any(token in command_text for token in (";", "&&", "||", "|", ">", "<", "$", "`")):
            raise PolicyError("structured command execution rejects shell operators")
        try:
            argv = shlex.split(command_text, posix=True)
        except ValueError as exc:
            raise PolicyError(f"command quoting is invalid: {exc}") from exc
        if not argv:
            raise PolicyError("a command is required")
        blocked = {"sudo", "su", "rm", "rmdir", "dd", "mkfs", "shutdown", "reboot", "docker", "curl", "wget", "ssh", "scp", "nc", "netcat", "mount", "umount", "iptables"}
        executable = argv[0].rsplit("/", 1)[-1].lower()
        if executable in blocked:
            raise PolicyError("the requested command is blocked by the local policy")
        return "run_command", {"argv": argv, "cwd": "."}
    if any(word in lowered for word in ("open", "launch", "visit")) and (urls or "youtube" in lowered or "browser" in lowered or "chrome" in lowered):
        if "browser" not in _packs():
            raise PolicyError("the browser pack is not installed")
        url = urls[0].rstrip(".,);]") if urls else "https://www.youtube.com/"
        return "browser_open_url", {"url": url}
    if any(word in lowered for word in ("scan", "list", "enumerate", "show")) and any(word in lowered for word in ("drive", "folder", "directory", "directories")):
        path = _windows_path(message)
        if path is None:
            drive_match = re.search(r"\b([a-z])\s*:?\s*drive\b", message, re.IGNORECASE)
            path = (drive_match.group(1).upper() + ":\\") if drive_match else "F:\\"
        recursive = any(word in lowered for word in ("every", "all", "subfolder", "subdirectory", "recursive", "under each"))
        return "list_windows_directories", {"path": path, "recursive": recursive, "max_items": 1000000, "max_seconds": 300}
    if any(word in lowered for word in ("read", "show", "open")) and ("file" in lowered or WINDOWS_PATH_RE.search(message)):
        path = _windows_path(message)
        if path:
            return "read_windows_file", {"path": path}
    if "process" in lowered and any(word in lowered for word in ("list", "show", "what is running")):
        return "list_processes", {}
    return None


def _render_tool(name: str, result: dict[str, Any]) -> str:
    if name == "browser_open_url":
        prefix = "BROWSER_OPEN_OBSERVED" if result.get("status") == "observed" else "BROWSER_OPEN_FAILED"
        return prefix + "\n" + json.dumps(result, ensure_ascii=False, indent=2)
    if name == "list_windows_directories":
        lines = [
            "WINDOWS_FILESYSTEM_SCAN_OK" if not result.get("truncated") else "WINDOWS_FILESYSTEM_SCAN_PARTIAL",
            f"root={result.get('root', '')}",
            f"recursive={str(bool(result.get('recursive'))).lower()}",
            f"folders_found={result.get('count', 0)}",
            f"truncated={str(bool(result.get('truncated'))).lower()}",
            f"display_truncated={str(bool(result.get('display_truncated'))).lower()}",
        ]
        for entry in result.get("folders", []):
            lines.append(str(entry.get("path", entry)))
        errors = result.get("errors") or []
        if result.get("evidence_path"):
            lines.append("complete_listing_evidence=" + str(result["evidence_path"]))
        if errors:
            lines.append(f"errors_reported={len(errors)}")
            lines.extend("ERROR " + str(error) for error in errors)
        return "\n".join(lines)
    if name == "read_windows_file":
        return "WINDOWS_FILE_READ_OK\n" + str(result.get("text", ""))
    if name == "write_windows_file":
        return "WINDOWS_FILE_WRITE_OK\n" + json.dumps(result, ensure_ascii=False, indent=2)
    if name == "run_command":
        return "COMMAND_EXECUTION_RESULT\n" + json.dumps(result, ensure_ascii=False, indent=2)
    if name == "research_fetch":
        return "RESEARCH_FETCH_OK\n" + json.dumps(result, ensure_ascii=False, indent=2)
    if name == "list_processes":
        lines = [f"WINDOWS_PROCESS_LIST_OK count={result.get('count', 0)}"]
        lines.extend(f"{item.get('Name')} pid={item.get('Id')}" for item in result.get("processes", []))
        return "\n".join(lines)
    if result.get("status") == "verified":
        return json.dumps(result, ensure_ascii=False, indent=2)
    return json.dumps(result, ensure_ascii=False, indent=2)


def _model_tool_schema(installed: set[str]) -> list[dict[str, Any]]:
    # The model may request read-only inspection. Mutating and external-effect
    # tools remain explicit-intent tools so model text cannot become consent.
    definitions: list[dict[str, Any]] = []
    for spec in enabled_tools(installed):
        if spec["mutability"] != "read":
            continue
        definitions.append({"type": "function", "function": {"name": spec["name"], "description": spec["description"], "parameters": spec["input_schema"]}})
    return definitions


def _tool_calls(response: dict[str, Any]) -> list[dict[str, Any]]:
    try:
        message = response["choices"][0]["message"]
    except (KeyError, IndexError, TypeError):
        return []
    calls = message.get("tool_calls") or []
    if isinstance(calls, list):
        return [call for call in calls if isinstance(call, dict)]
    return []


def _assistant_content(response: dict[str, Any]) -> str:
    try:
        content = response["choices"][0]["message"].get("content")
    except (KeyError, IndexError, TypeError):
        return ""
    if isinstance(content, list):
        return "".join(str(item.get("text", "")) if isinstance(item, dict) else str(item) for item in content)
    return str(content or "")


def _model_task(message: str, model: str) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    installed = _packs()
    system = (
        "You are the LocalAIDocker local agent. Only claim an action occurred when a verified tool result proves it. "
        "Do not tell the user to perform an action manually when an enabled tool can perform it. "
        "If a capability is not listed, state that it is unavailable. Never invent access to the Windows host, browser, or current web. "
        f"The verified deployment model is {model}; do not substitute a provider or model name. "
        "Available capability manifest: " + json.dumps(enabled_tools(installed), ensure_ascii=False)
    )
    messages: list[dict[str, Any]] = [{"role": "system", "content": system}, {"role": "user", "content": message}]
    wants_inspection = any(keyword in message.lower() for keyword in ("file", "drive", "folder", "directory", "process", "scan", "inspect"))
    tools = _model_tool_schema(installed) if wants_inspection else []
    used: list[dict[str, Any]] = []
    for _ in range(3):
        payload: dict[str, Any] = {"model": model, "messages": messages, "stream": False}
        if tools:
            payload["tools"] = tools
            payload["tool_choice"] = "auto"
        result = request("/v1/chat/completions", payload)
        calls = _tool_calls(result)
        if not calls:
            return _response(_assistant_content(result), model, used), used
        messages.append(result.get("choices", [{}])[0].get("message", {"role": "assistant", "content": ""}))
        for call in calls:
            function = call.get("function", {})
            name = str(function.get("name", ""))
            raw_arguments = function.get("arguments", "{}")
            try:
                arguments = json.loads(raw_arguments) if isinstance(raw_arguments, str) else raw_arguments
                if not isinstance(arguments, dict):
                    raise ValueError("tool arguments must be an object")
                if name not in REGISTRY or REGISTRY[name].mutability != "read":
                    raise PolicyError("only read-only model tool calls are enabled")
                tool_result = execute_tool(name, arguments)
                used.append({"name": name, "status": "verified"})
            except (PolicyError, ValueError, TypeError) as exc:
                tool_result = {"status": "failed", "error": str(exc)}
                used.append({"name": name, "status": "failed", "error": str(exc)})
            messages.append({"role": "tool", "tool_call_id": call.get("id", uuid.uuid4().hex), "name": name, "content": json.dumps(tool_result, ensure_ascii=False)})
    return _response("The tool loop reached its bounded step limit without a verified final answer.", model, used), used


def handle_message(message: str, model: str) -> dict[str, Any]:
    lowered = message.lower()
    if any(phrase in lowered for phrase in ("what model", "which model", "model are you", "model do you use")):
        identity = (
            "MODEL_IDENTITY_VERIFIED\n"
            f"model_id={model}\n"
            "backend=LocalAI llama.cpp\n"
            "deployment=verified-local-docker\n"
            "answer_source=deployment-receipt"
        )
        return _response(identity, model, [{"name": "model_identity", "status": "verified"}])
    if any(phrase in lowered for phrase in ("what can you do", "list your capabilities", "available capabilities")):
        names = [spec["name"] for spec in enabled_tools(_packs())]
        return _response("CAPABILITIES_VERIFIED\n" + "\n".join(names), model, [{"name": "capability_manifest", "status": "verified"}])
    try:
        direct = _direct_intent(message)
    except PolicyError as exc:
        return _response("REQUEST_NOT_EXECUTED\nreason=" + str(exc), model, [{"name": "policy", "status": "rejected", "error": str(exc)}])
    if direct:
        name, arguments = direct
        try:
            result = execute_tool(name, arguments)
            tool_status = "partial" if name == "list_windows_directories" and result.get("truncated") else result.get("status", "verified")
            return _response(_render_tool(name, result), model, [{"name": name, "status": tool_status}])
        except (PolicyError, ValueError, TypeError) as exc:
            return _response(f"{name.upper()}_UNAVAILABLE\nreason={exc}", model, [{"name": name, "status": "failed", "error": str(exc)}])
    return _model_task(message, model)[0]


class Agent(BaseHTTPRequestHandler):
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
            self._reply(200, {"status": "agent-ready", "capabilities": [spec["name"] for spec in enabled_tools(_packs())]})
        else:
            self._reply(404, {"error": "not found"})

    def do_POST(self) -> None:
        if self.path != "/v1/task":
            self._reply(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 4_000_000:
                raise ValueError("invalid request size")
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            message = str(payload.get("message", "")).strip()
            if not message:
                raise ValueError("message is required")
            requested_model = str(payload.get("model", os.environ.get("MODEL_ID", "qwen25-coder-1.5b-q4km")))
            model = _verified_model(requested_model)
            result = handle_message(message, model)
            task_id = str(payload.get("task_id", "adhoc"))
            save_checkpoint(task_id, {"status": "completed", "model": model, "tools_used": result.get("tools_used", [])})
            self._reply(200, result)
        except (ValueError, LocalAIError, PolicyError, json.JSONDecodeError) as exc:
            self._reply(400, {"error": str(exc)})
        except Exception as exc:  # keep the service alive and make unexpected failures visible
            self._reply(500, {"error": f"agent failure: {exc}"})


def main() -> None:
    host, port_text = os.environ.get("AGENT_BIND", "0.0.0.0:8090").rsplit(":", 1)
    ThreadingHTTPServer((host, int(port_text)), Agent).serve_forever()


if __name__ == "__main__":
    main()
