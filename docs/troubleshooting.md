# LocalAIDocker troubleshooting

Run the read-only checks first:

```powershell
& 'F:\study\AI\_ML\LocalAI\LocalAIDocker\scripts\llm.ps1' -Check
& 'F:\study\AI\_ML\LocalAI\LocalAIDocker\scripts\llm.ps1' -Doctor -Json
```

The launcher uses these stable exit codes:

| Code | Meaning |
| ---: | --- |
| 0 | Verified success or ready |
| 2 | Invalid command or configuration |
| 10 | Docker CLI or daemon unavailable |
| 11 | Runtime not ready |
| 12 | Installation or repair failed |
| 13 | Backend violates policy |
| 14 | No verified model fits |
| 15 | Model server failed |
| 16 | Requested pack unavailable or failed acceptance |
| 17 | Artifact or provenance mismatch |
| 18 | User interruption |
| 19 | External dependency unavailable |

The no-argument command performs a target-owned rebuild/recreate cycle, prints
`[+NNNNNNms]` progress lines, validates the locked model and images, and enters
interactive mode only after authenticated inference succeeds. It never starts
Docker Desktop or changes the Docker context. Docker must already be available
in the selected context.

If an image pull reports a transient EOF, the launcher retries it once. If the
second attempt fails, it stops without declaring readiness. If the model hash
or deployment receipt does not match, do not delete unrelated Docker data;
inspect the target-local evidence and rerun explicit `-Repair` after the Docker
daemon is healthy.

Hyper-V on Windows is a CPU fallback. Verified RTX acceleration requires an
explicit native Linux Docker context with working NVIDIA Container Toolkit.
