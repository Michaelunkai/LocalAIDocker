# LocalAIDocker capability contract

The capability manifest is the source of truth for what the agent may claim.
Core is the verified LocalAI text runtime and is available offline after the
model and images have been installed. Optional packs are independently built,
smoke-tested, and recorded in `state\current-deployment.json`.

| Pack | Isolation | Current behavior |
| --- | --- | --- |
| core | LocalAI, gateway, agent, and target-local bridge | Text inference, bounded agent tasks, target-local writes, read-only Windows inspection, structured commands, and explicit Chrome URL launch receipts |
| gpu | Native Linux Docker context only | Requires a verified NVIDIA Container Toolkit path; never claimed on Hyper-V CPU |
| coding | Agent image | Git, ripgrep, C/C++ build tools, Node, Go, Rust, and Java smoke-tested when installed |
| media | Agent image | ffmpeg and ImageMagick smoke-tested when installed |
| documents | Agent image | Pandoc, Poppler, Ghostscript, and Tesseract smoke-tested when installed |
| browser | Isolated Chromium container | Public URL opening and DOM observation only; no host browser profile or cookies; separate from core's requested host-Chrome launch |
| research | Agent public-read network | Bounded public fetch with URL validation and provenance |
| containers | Not enabled by default | Requires a separately verified rootless nested engine; no host Docker socket |
| harness | Not enabled by default | Requires a separately pinned and verified harness image |

`verified`, `not-installed`, `failed`, and `unverified-external` are distinct
states. A model response never upgrades a capability state.

The model registry currently locks a Qwen2.5-Coder 1.5B GGUF candidate for
`fast` and a Qwen2.5-Coder 7B Q4_K_M candidate for `balanced`, `quality`, and
`coding`. The 7B candidate is selected only for its explicitly requested
profile and is downloaded independently; `vision` still has no verified
candidate and must not be presented as ready.
