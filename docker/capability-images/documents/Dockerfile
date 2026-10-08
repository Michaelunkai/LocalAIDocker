ARG BASE_IMAGE=python:3.12-slim@sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea
FROM ${BASE_IMAGE}

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 DEBIAN_FRONTEND=noninteractive
WORKDIR /app

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends pandoc poppler-utils ghostscript tesseract-ocr; \
    rm -rf /var/lib/apt/lists/*; \
    useradd --create-home --user-group --uid 10004 runner; \
    mkdir -p /workspace; \
    chown -R runner:runner /workspace

COPY agent/tool_runner.py /app/tool_runner.py
RUN python -m py_compile /app/tool_runner.py
USER 10004:10004
EXPOSE 8783
CMD ["python", "/app/tool_runner.py"]
