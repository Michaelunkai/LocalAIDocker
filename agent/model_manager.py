from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import tempfile
import time
import urllib.request


MAX_DOWNLOAD_SECONDS = 30 * 60
READ_TIMEOUT_SECONDS = 30
ALLOWED_CONTENT_TYPES = {
    "application/octet-stream",
    "application/gguf",
    "binary/octet-stream",
}


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url: str, target: pathlib.Path, expected_size: int, expected_sha: str) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=target.name + ".", suffix=".part", dir=target.parent)
    digest = hashlib.sha256()
    size = 0
    started = time.monotonic()
    last_report = 0.0
    last_reported_size = 0
    print(
        f"MODEL_DOWNLOAD_STARTED filename={target.name} total_bytes={expected_size}",
        flush=True,
    )
    try:
        request = urllib.request.Request(
            url,
            headers={
                "Accept": "application/octet-stream",
                "User-Agent": "LocalAIDocker-ModelManager/1",
            },
        )
        with os.fdopen(fd, "wb") as out, urllib.request.urlopen(request, timeout=READ_TIMEOUT_SECONDS) as response:
            content_type = response.headers.get_content_type().lower()
            if content_type not in ALLOWED_CONTENT_TYPES:
                raise RuntimeError(f"model response content type is not accepted: {content_type}")
            remote_size = response.headers.get("Content-Length")
            if remote_size is not None and int(remote_size) != expected_size:
                raise RuntimeError("model response Content-Length does not match the lock")
            while True:
                if time.monotonic() - started > MAX_DOWNLOAD_SECONDS:
                    raise RuntimeError("model download exceeded its deadline")
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                size += len(chunk)
                if size > expected_size:
                    raise RuntimeError("download exceeded locked size")
                digest.update(chunk)
                out.write(chunk)
                now = time.monotonic()
                if (
                    size == expected_size
                    or size - last_reported_size >= 64 * 1024 * 1024
                    or now - last_report >= 1.0
                ):
                    percent = (size / expected_size * 100.0) if expected_size else 100.0
                    elapsed_ms = int((now - started) * 1000)
                    print(
                        "MODEL_DOWNLOAD_PROGRESS "
                        f"filename={target.name} bytes={size} total_bytes={expected_size} "
                        f"percent={percent:.2f} elapsed_ms={elapsed_ms}",
                        flush=True,
                    )
                    last_report = now
                    last_reported_size = size
            out.flush()
            os.fsync(out.fileno())
        if size != expected_size or digest.hexdigest() != expected_sha:
            raise RuntimeError("model artifact size or SHA-256 mismatch")
        os.replace(temp_name, target)
        print(
            f"MODEL_DOWNLOAD_VERIFIED filename={target.name} bytes={size} sha256={expected_sha}",
            flush=True,
        )
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def write_atomic_text(target: pathlib.Path, text: str) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{target.name}.", suffix=".tmp", dir=target.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, target)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def validate_lock(lock: dict) -> None:
    if not isinstance(lock, dict) or not isinstance(lock.get("models"), list) or not lock["models"]:
        raise RuntimeError("model lock does not contain any candidates")
    for model in lock["models"]:
        model_id = str(model.get("id", ""))
        revision = str(model.get("revision", ""))
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", model_id):
            raise RuntimeError(f"invalid locked model id: {model_id}")
        if not re.fullmatch(r"[0-9a-fA-F]{40}", revision):
            raise RuntimeError(f"model {model_id} does not use a full locked revision")
        if not str(model.get("license", "")).strip():
            raise RuntimeError(f"model {model_id} has no declared license")
        artifacts = model.get("artifacts")
        if not isinstance(artifacts, list) or not artifacts:
            raise RuntimeError(f"model {model_id} has no artifacts")
        for artifact in artifacts:
            filename = str(artifact.get("filename", ""))
            url = str(artifact.get("url", ""))
            if not filename or pathlib.PurePosixPath(filename).name != filename:
                raise RuntimeError(f"model {model_id} has an unsafe artifact filename")
            if revision.lower() not in url.lower():
                raise RuntimeError(f"model {model_id} artifact URL is not pinned to its revision")
            size = int(artifact.get("size_bytes", 0))
            digest = str(artifact.get("sha256", ""))
            if size <= 0 or not re.fullmatch(r"[0-9a-fA-F]{64}", digest):
                raise RuntimeError(f"model {model_id} has invalid artifact size or SHA-256")


def main() -> None:
    lock_path = pathlib.Path(os.environ.get("MODEL_LOCK_FILE", "/app/config/models.lock.json"))
    output = pathlib.Path(os.environ.get("MODEL_OUTPUT_DIR", "/models"))
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    validate_lock(lock)
    for model in lock.get("models", []):
        model_dir = output / model["id"]
        model_dir.mkdir(parents=True, exist_ok=True)
        for artifact in model.get("artifacts", []):
            target = model_dir / artifact["filename"]
            if target.exists() and target.stat().st_size == artifact["size_bytes"]:
                digest = sha256_file(target)
                if digest == artifact["sha256"]:
                    print(
                        f"MODEL_ARTIFACT_VERIFIED filename={target.name} bytes={artifact['size_bytes']} sha256={artifact['sha256']}",
                        flush=True,
                    )
                    continue
            download(artifact["url"], target, artifact["size_bytes"], artifact["sha256"])
        main_artifact = next(item for item in model["artifacts"] if item["role"] == "main")
        config = "\n".join([
            f"name: {model['id']}",
            "backend: llama-cpp",
            "parameters:",
            f"  model: {model['id']}/{main_artifact['filename']}",
            "context_size: 4096",
            "threads: 8",
            "template:",
            "  use_tokenizer_template: true",
            "options:",
            "  - use_jinja:true",
            "",
        ])
        write_atomic_text(output / f"{model['id']}.yaml", config)
        print(f"MODEL_VERIFIED id={model['id']}")


if __name__ == "__main__":
    main()
