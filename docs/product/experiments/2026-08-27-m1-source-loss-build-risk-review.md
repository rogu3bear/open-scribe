---
artifact: build-risk-review
created: 2026-08-27
status: build-small-source-failure-seam
mode: feature-change
---

# Build Risk Review: degraded dual-source continuation

## Verdict

**Validate first.** Continuing after one source fails is valuable only if the exact app preserves the healthy source while making the missing interval and reduced capture scope impossible to mistake for a complete conversation.

## Biggest risk

- **R1 trust:** degraded continuation may keep one writer alive while durable state or native UI still implies that both required sources are safely captured.
- R2 feature-fit: stopping both sources may be safer than an unproved degraded mode, but can unnecessarily lose healthy microphone audio.
- R3 trust: permission revocation, stream failure, and silence may be collapsed into one generic failure despite requiring different evidence and operator guidance.

## Demand level

**L3 - workflow blocker.** A meeting recorder cannot complete its core job truthfully if it either discards a healthy source or silently implies that a failed source continued.

## Evidence ledger

| Signal | Strength | What it does or does not prove |
|---|---|---|
| Founding PRD and accepted ADR 0005 require source-specific degraded continuation | Medium | Establishes product intent, not runtime behavior |
| Rust required-source authority and focused multi-track recovery tests pass | Medium | Proves deterministic state and recovery seams, not live source loss |
| Unsigned native tests cover injected system-audio failure and fail-closed invalid buffers | Medium | Proves controller behavior under fakes, not TCC or ScreenCaptureKit loss |
| No exact-artifact dual-source loss or revocation receipt exists | Counter-signal | Prevents a Build small verdict today |

## Validation plan

1. Build one exact unsigned arm64 app from the bound SHA, deliberately start microphone plus all-authorized system audio, and independently verify both managed CAF tracks and Rust `Recording` authority.
2. In separate runs, induce a named ScreenCaptureKit stream loss and Screen Recording permission revocation after both first samples. Compare app presentation, SQLite state, journal events, source/segment lifecycles, and media bytes against ADR 0005.
3. Choose **Build small** only if the healthy track continues under a durable degraded state with no complete-capture claim; choose **REWORK** if evidence is preserved but authority or presentation diverges; choose **HOLD** on missing/changed media, ambiguous journal state, or an unreproducible failure stimulus.

## Routing

-> `define-hypothesis`, then `measure-experiment-design`, because the safety assumption needs one falsifiable exact-artifact test before implementation expands.

## Sources

- `docs/product/FOUNDING_PRD.md`
- `docs/architecture/0005-capture-media-and-timeline.md`
- `docs/architecture/0007-platform-permissions-playback-and-import.md`
- `ANCHOR.md`

## Experiment decision

The control proved real simultaneous microphone and system-audio capture, but the permission reset did not stop the active stream and the subsequent dual-source forced-termination run exposed a false-complete recovery projection. The tested app had been relinked against a Rust archive older than the atomic multi-source recovery source on `main`. Hold that artifact and repair the build order before attributing the result to current recovery logic.

The build-order repair then passed exact two-source capture and atomic forced-termination recovery. The remaining decision is **Build small** for one content-free, Rust-owned source-failure/degraded seam connected to the real adapter callback. This does not accept the broader source-loss hypothesis; it creates the smallest observable path needed to reproduce and qualify it.
