from __future__ import annotations

import hmac
import os
import pathlib
import urllib.parse
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


MAX_BODY = 20_000_000


def secret() -> str:
    path = pathlib.Path(os.environ.get("API_KEY_FILE", "/run/secrets/localai_api_key"))
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def host_bridge_secret() -> str:
    path = pathlib.Path(os.environ.get("HOST_BRIDGE_KEY_FILE", "/run/secrets/host_bridge_key"))
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


class Gateway(BaseHTTPRequestHandler):
    server_version = "LocalAIDockerGateway/1"

    def log_message(self, fmt: str, *args: object) -> None:
        return

    def _authorized(self) -> bool:
        supplied = self.headers.get("Authorization", "")
        expected = "Bearer " + secret()
        return bool(secret()) and hmac.compare_digest(supplied, expected)

    def _host_bridge_authorized(self) -> bool:
        supplied = self.headers.get("Authorization", "")
        expected = "Bearer " + host_bridge_secret()
        return bool(host_bridge_secret()) and hmac.compare_digest(supplied, expected)

    def _send(self, code: int, body: bytes, content_type: str = "application/json") -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path in {"/health", "/readyz"}:
            self._send(200, b'{"status":"gateway-ready"}\n')
            return
        if self.path.startswith("/host-bridge"):
            if not self._host_bridge_authorized():
                self._send(401, b'{"error":"host bridge authentication required"}\n')
                return
            self._proxy_host_bridge("GET")
            return
        if not self._authorized():
            self._send(401, b'{"error":"authentication required"}\n')
            return
        self._proxy("GET")

    def do_POST(self) -> None:
        if self.path.startswith("/host-bridge"):
            if not self._host_bridge_authorized():
                self._send(401, b'{"error":"host bridge authentication required"}\n')
                return
            self._proxy_host_bridge("POST")
            return
        if not self._authorized():
            self._send(401, b'{"error":"authentication required"}\n')
            return
        self._proxy("POST")

    def _proxy(self, method: str) -> None:
        if not (self.path.startswith("/v1/") or self.path in {"/models", "/backend-assets"}):
            self._send(404, b'{"error":"route not exposed"}\n')
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send(400, b'{"error":"invalid content length"}\n')
            return
        if length > MAX_BODY:
            self._send(413, b'{"error":"request too large"}\n')
            return
        body = self.rfile.read(length) if length else None
        upstream = os.environ.get("AGENT_URL", "http://agent:8090") if self.path == "/v1/task" else os.environ.get("LOCALAI_URL", "http://localai:8080")
        target = upstream.rstrip("/") + self.path
        request = urllib.request.Request(target, data=body, method=method)
        request.add_header("Content-Type", self.headers.get("Content-Type", "application/json"))
        try:
            request_timeout = 360 if self.path == "/v1/task" else 180
            with urllib.request.urlopen(request, timeout=request_timeout) as response:
                self._send(response.status, response.read(MAX_BODY), response.headers.get_content_type())
        except urllib.error.HTTPError as exc:
            self._send(exc.code, exc.read(MAX_BODY))
        except (urllib.error.URLError, TimeoutError) as exc:
            self._send(502, ('{"error":"backend unavailable","detail":%r}\n' % str(exc)).encode())

    def _proxy_host_bridge(self, method: str) -> None:
        allowed = {
            "/host-bridge/health": "/health",
            "/host-bridge/v1/files/list": "/v1/files/list",
            "/host-bridge/v1/files/read": "/v1/files/read",
            "/host-bridge/v1/files/write": "/v1/files/write",
            "/host-bridge/v1/process/list": "/v1/process/list",
            "/host-bridge/v1/browser/open": "/v1/browser/open",
        }
        parsed = urllib.parse.urlsplit(self.path)
        target_path = allowed.get(parsed.path)
        base = os.environ.get("HOST_BRIDGE_URL", "http://host.docker.internal:8765").rstrip("/")
        if target_path is None:
            self._send(404, b'{"error":"host bridge route not exposed"}\n')
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send(400, b'{"error":"invalid content length"}\n')
            return
        if length < 0 or length > MAX_BODY:
            self._send(413, b'{"error":"request too large"}\n')
            return
        body = self.rfile.read(length) if length else None
        request = urllib.request.Request(base + target_path, data=body, method=method)
        request.add_header("Authorization", self.headers.get("Authorization", ""))
        request.add_header("Content-Type", self.headers.get("Content-Type", "application/json"))
        try:
            request_timeout = 330 if parsed.path == "/host-bridge/v1/files/list" else 35
            with urllib.request.urlopen(request, timeout=request_timeout) as response:
                self._send(response.status, response.read(MAX_BODY), response.headers.get_content_type())
        except urllib.error.HTTPError as exc:
            self._send(exc.code, exc.read(MAX_BODY))
        except (urllib.error.URLError, TimeoutError) as exc:
            self._send(502, ('{"error":"host bridge unavailable","detail":%r}\n' % str(exc)).encode())


def main() -> None:
    host, port_text = os.environ.get("GATEWAY_BIND", "0.0.0.0:8080").rsplit(":", 1)
    ThreadingHTTPServer((host, int(port_text)), Gateway).serve_forever()


if __name__ == "__main__":
    main()
