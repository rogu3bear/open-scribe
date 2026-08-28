---
artifact: hypothesis
version: "1.0"
created: 2026-08-27
status: partially-tested-hold
---

# Hypothesis: one-source loss remains truthful and recoverable

## Hypothesis Statement

**We believe that** continuing an exact Open Scribe recording after one authorized audio source is lost

**for** a Mac operator recording a live conversation from microphone plus system audio

**will** preserve the healthy source while exposing the failed source and missing interval as durable degraded evidence

**as measured by** zero false complete-capture claims and correct media/journal outcomes in every required loss and revocation trial.

## Background & Rationale

### Problem Context

ADR 0005 requires `Recording` with degraded health when one durable source remains and `Interrupted` only when no source remains. The current exact artifact has source-level writers and interruption recovery, but no live receipt proves that distinction.

### Supporting Evidence

- Rust owns session/source lifecycle and the `Recording` transition.
- Swift maintains independent microphone and system-audio writers.
- Focused tests prove fail-closed adapter behavior and byte-preserving multi-track recovery.
- Live dual-source loss, TCC revocation, degraded continuation, and UI truth remain unproved.

### Alternative Hypotheses Considered

- Stop both sources on any failure. This is simpler but discards healthy evidence and contradicts ADR 0005.
- Continue silently. This preserves bytes but violates explicit capture authority and is rejected.

## Target User Segment

### Definition

Individual Apple-silicon Mac operators who deliberately record meetings using microphone plus authorized system audio.

### Segment Size

Not measured; this is a safety qualification of one runtime contract, not a market-size estimate.

### Current Behavior

The source candidate can enter dual-source `Recording` under focused tests. No exact artifact has demonstrated live degraded continuation.

## Success Metrics

### Primary Metric

| Metric | Current Baseline | Target | Minimum Detectable Effect |
|---|---|---|---|
| Truthful preservation trials | 0 qualified trials | 3 of 3 required scenarios pass | Any failure is detectable and blocks Build small |

### Secondary Metrics

| Metric | Current Baseline | Expected Direction |
|---|---|---|
| Healthy-source playable duration after loss | Unknown | Continues increasing until explicit stop |
| Failed-source lifecycle/event agreement | Unknown | One named loss boundary with no post-loss capture claim |
| Relaunch recovery idempotence | Focused tests only | One stable conversation with no duplicate recovery receipt |

### Guardrail Metrics

| Metric | Current Value | Acceptable Range |
|---|---|---|
| Source media byte preservation | Focused tests pass | No recovery or analysis rewrite of captured bytes |
| False complete-capture presentation | Unproved | Exactly zero |
| Unnamed or content-bearing diagnostics | Unproved | Exactly zero |

## Validation Approach

### Method

Controlled exact-artifact runtime experiment with independent CAF, SQLite, journal, process-log, and relaunch inspection.

### Sample Size & Duration

- Sample size: one baseline, one named stream-loss run, and one permission-revocation run.
- Duration: each run continues long enough to establish two durable first samples, a post-loss healthy interval, explicit stop, independent playback, and one relaunch.
- Traffic allocation: not applicable; no user A/B allocation.

### Pass/Fail Criteria

- **Validated if:** all three scenarios satisfy their predeclared state, media, journal, playback, and no-overclaim bars.
- **Invalidated if:** any healthy source is discarded unnecessarily, any failed source is represented as continuing, captured bytes are changed, or durable and visible state disagree.
- **Inconclusive if:** the exact failure or revocation cannot be induced and independently timestamped on the bound artifact.

## Risks & Assumptions

### Key Assumptions

- ScreenCaptureKit and TCC expose an observable stop/revocation boundary on the test host.
- The unsigned development artifact has the same source-loss logic intended for later signed qualification.

### Risks

- Resetting TCC may change future permission posture without immediately stopping an existing stream.
- Silence can be mistaken for source loss unless the stream-stop event is independently observed.
- A development artifact cannot prove signed entitlement enforcement.

## Timeline

| Phase | Date | Duration |
|---|---|---|
| Setup and artifact binding | 2026-08-27 | One focused build |
| Runtime trials | 2026-08-27 | Three bounded runs |
| Independent inspection | 2026-08-27 | Immediately after each run |
| Decision | 2026-08-27 | After the final receipt |

## Interim outcome

- Control capture passed with two durable, independently decodable source tracks.
- Active-stream permission revocation was inconclusive because TCC reset changed future-launch authority without stopping the running ScreenCaptureKit stream.
- Forced-termination recovery failed the no-false-complete guardrail on a stale-linked Rust artifact. The hypothesis remains unvalidated until an app relinked with the current atomic recovery implementation passes the exact runtime recovery and a reproducible named stream-loss trial.
