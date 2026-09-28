# Contributing to Open Scribe

Open Scribe has Milestone 0 development proof and incomplete M1 recorder work. [Dated runtime evidence](docs/TESTING.md#foundational-recording-workflow) names the tested artifact; `script/check_m1_complete.sh` owns the remaining completion gates. Contributions must preserve milestone scope and distinguish current source from historical runtime proof.

## Before changing anything

1. Read [AGENTS.md](AGENTS.md) and [ANCHOR.md](ANCHOR.md), then follow the task-relevant owners. Product or architectural decisions also require the relevant founding PRD clauses and purpose projection.
2. Confirm the exact branch, worktree, dirty state, and ownership.
3. State which milestone and authority layer the change belongs to.
4. Keep `AGENTS.md` and `CLAUDE.md` byte-identical.

## Scope

- Do not implement capture, transcription, diarization, OCR, context observation, providers, or LLM behavior under a scaffold-only task.
- Do not introduce retired stack elements: Python, FastAPI, React, Tauri, Electron, localhost app servers, upload-first semantics, or monolithic rewritten job JSON.
- Do not add dependencies, model weights, assets, templates, or generated bindings without license/source review.
- Do not turn a placeholder into a capability claim.

## Local proof

For scaffold changes:

```bash
./script/check.sh --scaffold
git diff --check
git status --short --branch
```

Later implementation changes must use the narrowest package/test proof first and then the repository gate documented at that time.

## Pull requests

PRs should name:

- active milestone and intended outcome;
- exact files and architecture boundary changed;
- tests/checks executed and their result;
- highest evidence plane proved;
- unresolved decisions, known failures, and anything intentionally not completed.

A build is not a runtime proof, and a runtime proof is not a release or deployment receipt.
