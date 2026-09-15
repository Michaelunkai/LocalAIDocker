# Project contract

## Boundary

LocalAIDocker is a new project rooted at this directory. It has no dependency on the previous LocalAI tree, previous profile functions, or host-wide Linux configuration.

The Windows launcher invokes Docker directly with structured argument arrays. Linux processes run only inside containers. Docker Engine image and volume internals remain owned by the selected Docker daemon.

## Runtime contract

The core runtime is:

1. a pinned LocalAI image;
2. a verified GGUF artifact;
3. a private LocalAI network;
4. an authenticated loopback gateway;
5. a minimal agent image using the Python standard library;
6. a deployment receipt under `state\` and `data\deployments\`.

There is one active model deployment. Model switching requires an explicit operation and a fresh acceptance probe.

## Authority contract

Core containers do not receive the host Docker socket, host credentials, arbitrary host paths, or unrestricted network access. The agent policy is typed and capability-driven. Workspace writes stay inside the target-local workspace; optional Windows-drive inspection, project writes through the authenticated host bridge, and narrowly scoped Chrome URL-launch receipts are exposed only while that bridge is healthy. Core inference and interactive chat remain ready if the bridge is unavailable, and the agent reports those host capabilities as unavailable rather than claiming them. Coding, media, documents, research, and the isolated Chromium browser are installable packs with executable smoke probes; nested-container and harness services remain unavailable until their isolation and image acceptance proofs are present.

## Backend contract

`hyperv-cpu` is the local Windows fallback. `native-linux-gpu` is the performance mode and requires an explicitly selected native Linux Docker context with working NVIDIA passthrough. The project does not install or repair the Docker host.
