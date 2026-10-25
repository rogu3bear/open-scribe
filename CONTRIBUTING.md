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

For a contributor candidate, commit the coherent slice after its focused checks,
then run the single source/build/test entry on that clean commit. Measure existing
targets and free space first; choose the Disk Guard budget from that measurement.

```bash
candidate="$PWD/apps/macos/.build/candidates/$(git rev-parse HEAD)/candidate.json"
disk-guard run --budget-gb <measured> --volume "$PWD" -- ./script/check.sh --candidate "$candidate"
```

The gate runs scaffold, clippy, boundary/entitlement checks, the complete web
build, fresh UniFFI bindings, one unsigned native `build-for-testing`, the full
Swift suite, recorder components, synthetic process recovery,
and the default thirteen-case permission-free M1 failure matrix. It does not
perform a foreground or scene launch. It still runs the Xcode test host and
isolated synthetic child processes, including `--verify-recording`, the
foundational workflow, and injected failures. Scene launch remains
`./script/check.sh --m0-native`. The matrix
checks source loss, sleep/wake, storage pressure and forced termination through
production controller/storage entry points with synthetic capture adapters.
Its ENOSPC case fills a dedicated 1.5 GiB sparse APFS image; include that growth
in the measured allowance. Only the owned mount and child app are cleaned up;
the image, source media and receipts remain as evidence. It never selects the
separate real-device `live-pause-resume` case. This is not the attended M1
permission, hardware, perceptual playback or two-hour synchronization matrix.
Its candidate record binds SHA, tree, executable, debug dylib, Info.plist, Rust
library, test executable, test-run description, and build log. A new candidate
directory is required for a build; existing evidence is never overwritten.

Runtime consumers accept `--candidate "$candidate"` and never build:
`--verify-recording`, `--foundational-workflow`, `--m1-dual-source-runtime`, and
`--m1-forced-termination-recovery`, all through `script/check.sh`. Source or
artifact drift fails before execution. The last two require explicit live
microphone/system-audio authority; recovery also starts native playback. Keep
those permission-dependent runs separate from contributor checks. The
foundational workflow defaults to synthetic; its optional `--live` mode also
requires capture and playback authority. See [Testing](docs/TESTING.md).

The standalone `--m1-injected-failures --candidate "$candidate" [--case CASE]`
consumer can run missing cases. Successful contributor qualification already
provides every default receipt. To repeat the matrix, qualify a new candidate
in a new directory; never remove existing receipts to rerun the consumer.

`script/build_candidate.sh <absolute-record>` is the build-only step. Pass that
record to `check.sh --candidate` to qualify it without rebuilding the app.
A build-only record does not qualify runtime gates until the canonical gate
produces matching source/native check receipts. A failed build keeps its
logs and never emits a usable record. A source change requires a new commit and
candidate; a documentation-only receipt commit does not retarget historical proof.

## Pull requests

PRs should name:

- active milestone and intended outcome;
- exact files and architecture boundary changed;
- tests/checks executed and their result;
- highest evidence plane proved;
- unresolved decisions, known failures, and anything intentionally not completed.

A build is not a runtime proof, and a runtime proof is not a release or deployment receipt.
