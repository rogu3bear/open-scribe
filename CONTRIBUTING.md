# Contributing to Open Scribe

Open Scribe is at founding-scaffold stage. The most valuable early contributions preserve clear boundaries rather than adding product behavior before architecture decisions are approved.

## Before changing anything

1. Read `AGENTS.md`, the founding PRD, `NORTH_STAR.md`, `ANCHOR.md`, and the task-relevant architecture file.
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
