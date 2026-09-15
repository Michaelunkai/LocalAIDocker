ARG BASE_IMAGE=python:3.12-slim@sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea
FROM ${BASE_IMAGE}

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends chromium ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    useradd --create-home --user-group --uid 10001 browser

COPY agent/browser_service.py /app/browser_service.py
RUN python -m py_compile /app/browser_service.py

USER 10001:10001
ENTRYPOINT ["python", "/app/browser_service.py"]
