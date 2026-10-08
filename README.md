# LocalAIDocker

LocalAIDocker is a self-contained Docker Compose deployment for local AI. It uses LocalAI with the llama.cpp backend, a locked GGUF model, a loopback-only authenticated gateway, and an optional guarded agent.

All project files, bind-mounted state, logs, evidence, and model artifacts belong under this directory. The project does not use the legacy launcher, a host Linux shell, or host-wide profile configuration.

## Start with a read-only check

From PowerShell:

```powershell
Set-Location 'F:\study\AI\_ML\LocalAI\LocalAIDocker'
& .\scripts\llm.ps1 -Check
& .\scripts\llm.ps1 -Doctor -Json
```

The Docker daemon must already be running. The launcher never starts Docker Desktop or changes the active Docker context.

## Run the complete application

The no-argument command is the normal full-run path. Every invocation performs a
fresh project-owned cycle with timestamped output: it validates Docker, verifies
or pulls the locked LocalAI image when absent, builds the project images,
verifies or downloads the locked model data, recreates new application
containers, waits for health, and runs an authenticated visible-answer smoke
test before reporting ready. Docker build caching may make later image builds
faster; `--force-recreate` still makes new containers on every normal run.

```powershell
& 'F:\study\AI\_ML\LocalAI\LocalAIDocker\scripts\llm.ps1'
```

Progress lines have the form `[+000123ms] ...` and continue through success or a
bounded failure. A normal run never switches contexts, starts Docker Desktop, or
uses WSL2. `-Launch` follows the same full cycle and then sends the optional task
text to the authenticated gateway.

## CPU installation

For Docker Desktop configured to use its Hyper-V backend, explicitly verify that selection in Docker Desktop and then set the process-scoped proof flag:

```powershell
$env:LOCALAI_HYPERV_VERIFIED = '1'
& .\scripts\llm.ps1 -Install -Backend hyperv-cpu -Pack core
```

The CPU mode is functional but is not presented as RTX acceleration.
The locked `fast` profile uses the smaller Qwen2.5-Coder 1.5B artifact; the
`balanced`, `quality`, and `coding` profiles use the separately locked 7B
artifact. Only the selected profile's model is downloaded and configured as
the active model.

## Native Linux GPU installation

Select a Docker context connected to a native Linux Docker Engine with NVIDIA Container Toolkit already configured. The project does not install drivers or change that host.

```powershell
& .\scripts\llm.ps1 -Install -Backend native-linux-gpu -Pack core -Pack gpu
```

Installation first verifies that `--gpus all` can run `nvidia-smi`, then downloads and hashes the locked model, builds the project images, recreates the services, and performs authenticated inference.

## Use the runtime

```powershell
& .\scripts\llm.ps1 -SelfTest
& .\scripts\llm.ps1 -Launch -Profile fast
& .\scripts\llm.ps1 'Explain the current project status.'
& .\scripts\llm.ps1 -Models
& .\scripts\llm.ps1 -Benchmark
```

Capability packs that are locally verifiable can be installed explicitly:

```powershell
& .\scripts\llm.ps1 -Install -Pack coding
& .\scripts\llm.ps1 -Install -Pack media
& .\scripts\llm.ps1 -Install -Pack documents
& .\scripts\llm.ps1 -Install -Pack research
& .\scripts\llm.ps1 -Install -Pack browser
```

Coding, media, and document packs build separate, unprivileged argv-runner
images with their tool families and run executable smoke probes; the core
agent image remains minimal. The research pack enables bounded
public fetching with DNS/private-address and redirect checks. The browser pack
builds an isolated Chromium service with no host browser profile or cookies;
its smoke test must observe a public page before the pack is marked ready.
Containers and harness remain unavailable until their isolated services have
their own image digests and acceptance proofs.

The gateway is loopback-only. It prefers `http://127.0.0.1:8080` and selects a
free persisted loopback port when that port is occupied; the exact endpoint is
printed in `LOCALAI_INTERACTIVE_READY` and stored in
`state\current-deployment.json`. The API key is generated under
`secrets\localai-api-key` during the first full deployment (or an explicit
`-Install`) and is never printed by the launcher.

After a successful no-argument run, the launcher stays open in interactive
mode instead of returning to PowerShell. Use `/help`, `/status`, or `/exit` at
the prompt. `-Launch` without task text enters the same mode; passing task text
keeps one-shot behavior.

Interactive requests are routed through the authenticated agent service, not
directly to the language model. The core agent can always prove its deployment
model and read/write its target-local workspace atomically. When the optional
target-local host bridge is healthy, it can also list directories inside the
LocalAIDocker project root, read bounded Windows files from that same root, list
a bounded Windows process snapshot, and launch an explicit Chrome URL. If that bridge is
unavailable, core inference still enters interactive mode and those host
capabilities are reported as unavailable. Large recursive scans write the complete
discovered path stream under `evidence\` and report whether enumeration or
terminal display was truncated. An explicit request naming Chrome/default
browser can launch a URL as a new Chrome tab through the authenticated,
target-local bridge; it reports `BROWSER_OPEN_REQUESTED` and never claims that
the tab was observed, controlled, or signed in. Interactive page observation
and browser control belong to the optional isolated browser pack.

The Windows interoperability bridge is a target-local, loopback-only process
started by the launcher. It is not WSL2, does not expose the Docker socket, and
does not grant the agent arbitrary host writes. Host reads are limited to the
drive containing this project; writes through the bridge are limited to this
project directory. An explicit request such as `create file named
evidence\note.txt with content: ...` uses the authenticated atomic host-write
route and records a target-local confirmation receipt. An explicit `scan my F
drive` request uses the bounded recursive directory route. An explicit `open
my default Chrome browser ... in a new tab` request uses a structured Chrome
launch route and records the result as requested rather than observed. An
explicit `run: python --version` request uses a structured argv array with no
shell parsing and bounded output.

## Status and limitations

- `LOCALAI_DOCKER_READY` means the deployment receipt, image identity, service health, and inference probe passed.
- `LOCALAI_DOCKER_NOT_READY` identifies the failed boundary and exit code.
- Optional packs are not installed by core and never block core readiness.
- A default-Chrome URL launch is a host-local requested effect and does not
  require the isolated browser pack; page observation, DOM extraction, and
  interactive browser control are available only through that isolated pack.
  Signed-in tab control and imported main-profile cookies are never used.
- Research requires the explicit research pack and provider configuration.
- A native Linux Docker Engine is required for verified NVIDIA acceleration under the no-host-Linux-shell policy.

## Verification

```powershell
& .\scripts\acceptance.ps1
& .\scripts\acceptance.ps1 -Json
```

Acceptance evidence is written only under `evidence\`.
