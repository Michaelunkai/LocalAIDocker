ARG BASE_IMAGE=python:3.12-slim@sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea
FROM ${BASE_IMAGE}

ARG INSTALL_PACKS=

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app

COPY agent /app/agent
COPY config/policy.json /app/config/policy.json
COPY config/profiles.json /app/config/profiles.json

RUN set -eux; \
    packages=""; \
    case ",${INSTALL_PACKS}," in \
      *,coding,*) packages="$packages git ripgrep fd-find build-essential nodejs npm golang-go rustc cargo default-jdk" ;; \
    esac; \
    case ",${INSTALL_PACKS}," in \
      *,media,*) packages="$packages ffmpeg imagemagick" ;; \
    esac; \
    case ",${INSTALL_PACKS}," in \
      *,documents,*) packages="$packages pandoc poppler-utils ghostscript tesseract-ocr" ;; \
    esac; \
    if [ -n "$packages" ]; then \
      apt-get update; \
      apt-get install -y --no-install-recommends $packages; \
      rm -rf /var/lib/apt/lists/*; \
    fi

RUN python -m compileall -q /app/agent
