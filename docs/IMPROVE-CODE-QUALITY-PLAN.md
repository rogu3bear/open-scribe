# Open Scribe Code-Quality Improvement Plan

## Context

- **Product:** an open-source macOS application that turns live or imported audio into a durable, locally managed conversation record with transcript and speaker attribution.
- **Failure to prevent:** claiming that a conversation is being recorded when durable media does not exist, or losing captured audio because transcription or another downstream operation fails.
- **Current focus:** the early-M1 microphone path from explicit menu-bar intent through permission, durable preparation, first-sample evidence, close, and segment sealing.
- **Stack:** SwiftUI and AVFoundation for macOS UI/platform adapters; Rust and SQLite/WAL for durable state; coarse UniFFI coordination; Leptos for the public website.
- **Stage:** pre-production; no qualified pilot or public release artifact exists.
- **Outbound surface:** no native application provider calls are implemented. The current website is a static public surface. Model downloads, remote transcription, and remote intelligence remain future, explicitly authorized surfaces.
- **Authority:** `docs/product/FOUNDING_PRD.md` is canonical. Tests characterize current implementation behavior; they do not supersede product requirements.

The `--force-auto` intake was treated as authority to infer this bounded first-run plan and add reversible documentation/tests. It did not authorize Git operations, release actions, live provider mutations, or work beyond the current milestone.

## Phase Status

| Phase | Status | Last Updated | Notes |
|---|---|---:|---|
| 1. Safety Net | in-progress | 2026-08-27 | Baseline mapped; controller failures and retry characterized; one short real capture passed. Forced-termination proof remains absent. |
| 2. Dependency Audit | pending | 2026-08-27 | No native outbound dependency exists yet; perform before adding models/providers. |
| 3. Boundary Review | pending | 2026-08-27 | Begin only after Phase 1 admits the target runtime seam. |
| 4. Correctness | pending | 2026-08-27 | Failure cleanup, retry, and recovery semantics need a product decision plus tests. |
| 5. Simplification | pending | 2026-08-27 | No broad refactor before behavior is pinned. |
| 6. Operational Hardening | pending | 2026-08-27 | Disk pressure, source loss, route changes, long runs, and forced termination are unproven. |
| 7. Trust Boundary | deferred | 2026-08-27 | Required before any provider, model download, update, or telemetry surface is introduced. |
| 8. Performance | deferred | 2026-08-27 | No production load; two-hour sync and callback-budget evidence will make this relevant. |
| 9. Observability | deferred | 2026-08-27 | Specify privacy-preserving local diagnostics after recorder states stabilize. |

## Key Decisions

| Decision | Rationale | Evidence Needed to Revisit |
|---|---|---|
| Improve the live microphone controller first. | It is the newly UI-wired seam nearest the current milestone boundary and has only happy-path coverage. | A different module becomes the demonstrated release blocker. |
| Preserve explicit retry and cleanup behavior. | Permission denial and capture failures now return to a startable failed state and clear live controller references. | A recovery design that changes partial-session ownership. |
| Keep `Capturing microphone` distinct from `Recording`. | The controller has first-sample durability evidence but no authoritative Rust recording transition or required-source proof. | Runtime evidence for every required source and the approved transition. |
| Retain verifier-owned process cleanup. | The admitted harness terminates the exact proof process and no longer collides with later XCTest hosts. | A regression that reproduces process-lock collision on the current gate. |
| Treat open source as an inspectability constraint, not release proof. | Public code increases licensing, reproducibility, security, and claim-accuracy obligations. | Signed/notarized artifact, source binding, third-party review, and release receipts. |

## Next Actions

- [ ] **P0 — Native runtime owner — before the next capture slice:** define failure cleanup, retry, and recovery ownership; then convert the current characterization into intended-behavior tests.
- [x] **P0 — QA/runtime owner — bounded short-capture claim:** `M1_LIVE_MICROPHONE_GREEN` proved permission through playable sealed media and deleted proof audio on commit `ffa2d7a`.
- [ ] **P0 — Product/native owner — before multi-source work:** select and validate one application/system-audio capture mode and define required-source loss behavior.
- [ ] **P1 — Durability owner — before transcription:** demonstrate forced-termination discovery and playable recovery without relying on transcription.
- [ ] **P1 — Open-source/release owner — before public release:** bind license notices, reproducible build instructions, threat review, signed/notarized artifact, and public claims to one candidate.
- [ ] **P2 — Product research owner — after a qualified recorder exists:** run the two-real-meeting replacement experiment and measure replay/revisit behavior.
