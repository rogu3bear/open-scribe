---
artifact: experiment-design
version: "1.0"
created: 2026-08-27
status: hold-source-loss-stimulus
---

# Experiment Design: M1 dual-source loss truth

## Overview

| Field | Value |
|---|---|
| Experiment Name | M1 exact-artifact dual-source loss truth |
| Owner | Open Scribe product/runtime lane |
| Start Date | 2026-08-27 |
| End Date | 2026-08-27 |
| Status | Dual-source control/recovery passed; HOLD on unreproduced source-loss stimulus |

## Hypothesis

**We believe** source-specific degraded continuation after one authorized audio source is lost

**for** an operator recording microphone plus system audio

**will** preserve the healthy source without implying that the failed source continued

**as measured by** three of three required scenarios passing exact media, journal, durable-state, visible-state, and playback assertions.

## Background

The current candidate stops and interrupts on injected system-audio failure, while accepted ADR 0005 requires degraded `Recording` when another durable source remains. Before changing that behavior, the exact artifact must reveal whether real stream loss and permission revocation preserve enough evidence to support safe continuation.

## Variants

### Control (A): ordinary dual-source stop

- Deliberate start from the exact unsigned app.
- Wait for microphone and system-audio first-sample evidence and Rust-owned `Recording`.
- Stop explicitly without induced loss.
- Independently inspect two tracks, journal, SQLite, playback, and relaunch.

### Treatment (B1): named system stream loss

- Start identically to control.
- After both sources are durable, induce and timestamp a ScreenCaptureKit stream-stop error without stopping the microphone.
- Continue for a bounded healthy-source interval, then stop and inspect.

### Treatment (B2): Screen Recording permission revocation

- Start identically to control.
- After both sources are durable, revoke/reset Screen Recording authority and independently timestamp the observed adapter/TCC outcome.
- Never silently retry or restore; continue only if Rust and UI durably enter the approved degraded state.

## Metrics

### Primary Metric

| Metric | Definition | Current Baseline | Minimum Detectable Effect |
|---|---|---|---|
| Qualified scenario rate | Scenarios satisfying every required assertion divided by 3 | 0/3 | One failed assertion changes the decision |

### Secondary Metrics

| Metric | Definition | Purpose |
|---|---|---|
| Healthy-source continuation | Post-loss playable frames and mapped duration | Detect unnecessary data loss |
| Failed-source boundary | One named durable source event matching the observed stop/revocation time | Detect silent gaps or ambiguous attribution |
| Relaunch stability | Same conversation/tracks and no duplicate recovery run after relaunch | Detect projection/recovery drift |

### Guardrail Metrics

| Metric | Definition | Threshold |
|---|---|---|
| False complete-capture claims | UI or durable state implies failed source remains active | 0 |
| Media mutation | Digest changes during recovery/inspection | 0 changed source files |
| Hot-path coupling | Healthy writer stops because derived/UI inspection blocks | 0 observed coupling failures |

## Sample Size & Duration

This is a binary safety qualification, not a population A/B test. Statistical alpha, power, traffic, and weekly duration are not applicable. The smallest sufficient sample is one exact-candidate run for each distinct authority path: control, stream loss, and permission revocation. Any failure blocks Build small; a later M1 matrix must expand devices, OS versions, routes, pressure, and two-hour duration.

## Audience Targeting

- Include this Apple-silicon Mac, the exact current `main` artifact, real microphone input, and authorized all-system audio.
- Exclude synthetic-only capture, fixture UI, stale app bundles, and any other checkout.
- Allocation: one run per declared scenario.

## Success Criteria

### Build small

- Control produces two nontrivial independently playable CAF tracks and one coherent stopped conversation.
- B1 and B2 preserve the healthy source after the named boundary, seal or retain the failed source without fabricating continuation, and expose the exact reduced scope in Rust-owned durable state and native UI.
- Relaunch preserves bytes and returns one coherent conversation without duplicate recovery events.

### REWORK

- Media remains present and independently playable, but the app interrupts unnecessarily, misclassifies loss, cannot continue the healthy source, or lets UI authority diverge from Rust.

### HOLD

- Any source media is missing or changed, the journal cannot establish the failure boundary, the app claims complete capture after loss, or the stimulus cannot be reproduced independently.

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| TCC reset does not stop an active stream | Medium | High | Record TCC state and adapter event separately; classify inconclusive rather than infer revocation |
| System audio contains silence | High | Medium | Require stream callback/stop evidence, not waveform energy, to identify loss |
| App artifact is stale | Medium | High | Bind source SHA, tree, binary digest, build settings, and result root before launch |
| Permission prompt needs operator interaction | High | Medium | Pause only for the real macOS prompt; record the selected outcome explicitly |

### Monitoring Plan

- Capture content-free process logs for requested, both-first-samples, Recording, named loss/revocation, degraded/interrupted, stop, and relaunch.
- Snapshot SQLite and journal state at Recording, after stimulus, after stop, and after relaunch.
- Hash every CAF before and after recovery inspection.
- Stop immediately on false Recording/complete-capture state or lost media.

## Implementation Notes

- Reuse the canonical Xcode app, managed CAF writer, SQLite store, journal, and UniFFI boundary.
- Do not add a second store, UI-local lifecycle authority, or buffer callbacks across UniFFI.
- If an injection seam is missing, TDD may add only a content-free platform-event seam whose production path still originates from the real adapter.
- The proof harness must retain its result root on failure for diagnosis and delete temporary media only after emitting a successful bounded receipt.

## Results

### Bound candidate and artifact

- Source: `main == origin/main == 77ada05a8f7656a4c9775ebaf50794c0bf9c6dba`.
- Unsigned arm64 app binary SHA-256: `5d90b35653fd6be5e9e523a706ae750b85ef37f4ab85d23fb37d3cf1ad057dfb`.
- Bundle: `app.open-scribe.dev`; signature plane: ad-hoc/linker-signed only.
- The app was incrementally rebuilt after the Swift repair, but its linked Rust archive was stale: the archive mtime preceded commit `ef12a93`, which added atomic multi-source recovery.

### A — ordinary dual-source stop: PASS on the stale-linked artifact

- Result root: `/tmp/open-scribe-m1-control-log.tmwNP1`.
- Rust journaled durable first samples for microphone and system audio, then `recording_started` with both sources active.
- Explicit stop sealed two independently decodable mono 48 kHz PCM CAF files: 104,917 frames (2.185771 s) and 113,280 frames (2.360000 s).
- SQLite projected one `ready_for_review` session with no open media.

### B2 — Screen Recording permission reset: stimulus not reproduced

- Result root: `/tmp/open-scribe-m1-revocation.HjRJgM`.
- `tccutil reset ScreenCapture app.open-scribe.dev` succeeded and removed Open Scribe from the visible TCC list.
- The already-authorized ScreenCaptureKit stream remained active; both CAF files continued growing for the six-second observation interval and no adapter or journal loss event appeared.
- Therefore this run does not prove runtime revocation handling. It establishes that TCC reset is a future-launch authority change on this host, not a valid active-stream-loss stimulus.

### Forced termination and relaunch: HOLD caused by stale linked Rust

- The exact dual-source process was externally killed after both sources entered durable `Recording`.
- Relaunch recovered only the microphone event/projection, left the system-audio source and segment `capturing/open`, yet returned the session as `ready_for_review`.
- This is a false-complete recovery result and triggers the predeclared HOLD bar.
- Source inspection showed that current `main` already plans every candidate before mutation, refuses incomplete required-source projection, and includes focused atomic dual-source tests. The runtime app linked a Rust archive older than those source changes. The next action is therefore build-order rework: rebuild the existing Rust target, relink the same app, repeat forced termination/recovery, and accept only exact-candidate all-source recovery.

## Decision

**HOLD the stale-linked tested artifact and the source-loss claim.** The build-order repair succeeded: a fresh-linked exact app emitted `M1_DUAL_SOURCE_RUNTIME_GREEN` and `M1_FORCED_TERMINATION_RECOVERY_GREEN`; two real tracks stayed byte-identical across forced termination, recovered atomically, independently decoded, and produced no duplicate event or recovery run on a second relaunch. Promote only those bounded development-fixture claims. Source-loss continuation and permission-revocation behavior remain unproved until a reproducible platform loss event exists.

## References

- `docs/product/experiments/2026-08-27-m1-source-loss-build-risk-review.md`
- `docs/product/experiments/2026-08-27-m1-source-loss-hypothesis.md`
- `docs/architecture/0005-capture-media-and-timeline.md`
- `docs/architecture/0007-platform-permissions-playback-and-import.md`
- `docs/product/FIRST_CLASS_ACCEPTANCE_CRITERIA.md`
