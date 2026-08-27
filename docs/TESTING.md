# Open Scribe Testing

## Test Strategy

Open Scribe tests the evidence chain in order: source/configuration, deterministic unit and integration behavior, build, installed/runtime behavior, recovery, signed artifact, and release. A lower plane never proves a higher one. `./script/check.sh --m1-segment-sealing` is the deterministic early-M1 gate; the separate, explicit `./script/check.sh --m1-live-microphone` runtime gate adds one short real-device and playable-CAF proof. Each receipt proves only the inclusions and exclusions it names.

Characterization tests pin observed behavior before correction. Safety-critical invariants—durable media before capture claims, audio survival independent of transcription, required-source truth, and recovery—need tests at the layer that owns the claim plus runtime evidence on an exact artifact.

## Safety Net Map

| Surface | Existing Safety Net | Important Gap | Priority | Owner |
|---|---|---|---:|---|
| Rust domain/types | Unit tests and fixture compatibility checks | Migration/backward-compatibility corpus remains small | P1 | Durable-state owner |
| Rust store/journal | Preparation, media-open, first-sample, sealing, digest, and recovery-classification tests | No playable interrupted-media recovery proof | P0 | Durable-state owner |
| UniFFI boundary | Binding regeneration and coarse evidence-object tests | No live multi-source coordinator contract | P1 | Integration owner |
| CAF writer and microphone adapter | Deterministic buffer, failure, race, stop barrier, receipt tests, and one short real-device proof | No route-change, disk-pressure, or long-run proof | P0 | Native runtime owner |
| Live recording controller | Happy path plus permission denial, start failure, callback failure, and stop-before-first-sample characterization | Retry/cleanup/recovery behavior is not yet specified | P0 | Native runtime owner |
| Single-instance guard | Exact lock ownership unit test | AppDelegate conflates an existing instance with lock-file I/O failure | P1 | Native shell owner |
| Menu-bar UI | Build and scene-launch fixture | No UI automation for source selection, durable state transitions, or error recovery | P1 | UX/QA owner |
| System/application audio | Founding requirements only | No selected-source implementation or proof | P0 | Platform capture owner |
| Playback/import/transcription/diarization | Founding requirements only | Not implemented | P1 after recorder | Conversation-loop owner |
| Release | Scaffold/build checks | No signed, notarized, installed, upgrade, rollback, or public-source binding | P1 before release | Release owner |

## Characterization Backlog

- [x] **P0 — Native runtime owner:** pin that capture is not shown until durable first-sample evidence exists.
- [x] **P0 — Native runtime owner:** pin current permission-denial, start-failure, capture-failure, and stop-before-first-sample behavior.
- [ ] **P0 — Native runtime owner:** characterize cleanup after preparation succeeds but capture start or sealing fails.
- [ ] **P0 — Durable-state owner:** characterize discovery of open and interrupted segments after forced termination.
- [ ] **P0 — Platform capture owner:** characterize required-source loss independently for microphone and the selected system-audio mode.
- [ ] **P1 — Conversation-loop owner:** characterize transcription retry/replacement while the sealed audio remains unchanged.
- [ ] **P1 — Library owner:** characterize import deduplication, unsupported media, large files, and partial metadata.

## CI Gates

| Gate | Command / Receipt | What It Proves | Explicitly Does Not Prove |
|---|---|---|---|
| Scaffold | `./script/check.sh --scaffold` | Doctrine and founding scaffold consistency | Product runtime |
| Early-M1 candidate | `./script/check.sh --m1-segment-sealing` | Deterministic early-M1 source/build/test chain named by the receipt | Real capture, playable recovery, transcription, signing, or release |
| Short live microphone | `./script/check.sh --m1-live-microphone` | Explicit local microphone permission, capture, sealing, digest, and playable CAF on the built app | System audio, `Recording`, recovery, long sessions, signing, or release |
| Release preparation contract | `./script/check.sh --release-prepare` | Semantic input validation, stable unresolved holds, artifact-verifier rejection paths, and read-only exact-source binding | Closed P0s, signed-artifact success, notarization, publication, or release |
| Diff hygiene | `git diff --check` | Patch whitespace validity | Functional correctness |
| Working-tree inventory | `git status --short --branch` | Exact local residue | Candidate admission or commit cleanliness |

New gates must fail closed, clean up processes and temporary state they own, print proof and exclusion sets, and bind runtime claims to the exact built artifact.
