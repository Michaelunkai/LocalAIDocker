# LocalAIDocker security boundary

The Docker project is confined to its own bind-mounted data, state, log,
evidence, backup, and secret directories. The agent receives no host Docker
socket, no privileged flag, and no host filesystem mount outside the project
workspace. The public gateway binds to `127.0.0.1` only.

Core commands use structured argv arrays with `shell=False`, finite timeouts,
bounded output, an environment allowlist, and a workspace path check. File
replacement uses a same-directory temporary file, flush/fsync, an atomic
replace, and a backup for an existing file. Symlink and junction escapes are
rejected by the host bridge.

The host bridge is a target-local, authenticated interoperability process. Its
read root is the drive containing this project; its write root is this project.
It does not provide arbitrary host writes or browser-profile access. The one
browser host operation is an explicit, credential-free HTTP(S) URL launch in
the discovered Chrome executable with a new-tab argument. The receipt is
`opened-requested`; it deliberately does not assert tab observation or control.

The browser pack runs Chromium in a separate container with a disposable user
data directory. It accepts only public HTTP(S) targets, returns a bounded DOM
excerpt, and never imports the user's Chrome cookies, extensions, profile, or
authentication state.

Research is opt-in public-read networking. Private, loopback, link-local,
reserved, and credential-bearing URLs are rejected. Core has no research
network. Container and harness packs cannot be enabled merely by creating a
file; their isolation and image acceptance tests must pass first.

API keys are generated only in target-local ignored secret files, are mounted
as Docker secrets, and are not printed or placed in prompts, task state, or
evidence.
