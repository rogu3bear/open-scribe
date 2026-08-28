# Open Scribe Technical Debt

## Debt Ledger

| ID | Area | Current Behavior / Debt | Risk | Priority | Owner | Retirement Evidence |
|---|---|---|---|---:|---|---|
| TD-003 | Single instance | `AppDelegate` treats lock-file I/O failure as if another instance exists. | Silent termination can misdiagnose a local filesystem fault. | P1 | Native shell owner | Separate user-visible paths and tests for `alreadyRunning` versus `cannotOpen`. |
| TD-004 | Recording truth | The live controller reaches `capturing` after microphone first-sample evidence but never asserts authoritative `Recording`. | UI or future code could promote one-source evidence into a false session claim. | P0 | Product/durability owners | Required-source coordinator and Rust-owned transition with tests. |
| TD-006 | Required system audio | Selected application/system audio is not implemented. | The product cannot yet record both sides of a meeting. | P0 | Platform capture owner | One validated mode, source visibility, loss behavior, and two-hour sync proof. |
| TD-009 | Default product gate | The repository’s broad default product gates intentionally fail closed. | Contributors can mistake scaffold success for application readiness. | P1 | Build/release owner | One canonical candidate gate with precise exclusions and contributor docs. |

## Retired Debt

| ID | Resolution | Evidence |
|---|---|---|
| TD-001 | Failed states are startable; permission and capture retries no longer require relaunch. | Controller tests admitted with `ffa2d7a`. |
| TD-005 | One explicit exact-artifact microphone run produced and independently validated a playable CAF. | `M1_LIVE_MICROPHONE_GREEN` on `ffa2d7a`; route, pressure, and long-run work remains under TD-006/TD-007. |
| TD-008 | Verification-owned processes are cleaned up and repeated gates no longer collide with the app lock. | Full gate and live proof admitted with `ffa2d7a`. |
| TD-010 | Architecture and operator projections now describe the admitted live-microphone slice. | `22aaa8f`. |
| TD-002 | Post-preparation failures retain typed interruption evidence; strict startup recovery converts valid process-killed microphone CAF media to persistent playable `ready_for_review` output. | `M1_FORCED_TERMINATION_RECOVERY_GATE_GREEN`; projection interruption, invalid-media, external-kill, unchanged-digest, playback, and idempotence proof. |
| TD-007 | Forced-termination microphone media is strictly validated, durably recovered, persistently rediscovered, and opened through native playback without changing source bytes. | `M1_FORCED_TERMINATION_RECOVERY_GATE_GREEN`; long-session and required-source work remains under TD-006. |

## Smell Inventory

| Smell | Location | Why It Matters | Priority | Owner | Next Safe Move |
|---|---|---|---:|---|---|
| Broad error collapse | `AppDelegate.applicationWillFinishLaunching` | Distinct lock failures produce the same action. | P1 | Native shell owner | Add characterization and split error handling. |
| String-only controller errors | `LiveMicrophoneRecordingController` | UI cannot reliably distinguish permission, source, writer, seal, and recovery actions. | P1 | Native runtime owner | Introduce typed operator-facing failure categories after the state contract is approved. |
| Recovery UI is not yet a general library | `RecoveredSessionController` + `open-scribe-store` | Forced-exit microphone sessions persist and play, but ordinary sealed sessions, imports, naming, deletion, and search do not share a complete conversation-library query. | P1 | Conversation-loop owner | Introduce one Rust-owned library projection after required-source recording is authoritative. |

## Sprout/Wrap Register

| Seam | Technique | Purpose | Status | Owner |
|---|---|---|---|---|
| `MicrophoneCapturing` / `ManagedSegmentWriting` | Wrap | Keep AVFoundation and file writing replaceable in deterministic controller tests. | Active | Native runtime owner |
| `LiveMicrophoneRecordingController` | Sprout | Coordinate the explicit menu-bar capture path without moving frame-rate media across UniFFI. | Typed interruption and forced-exit playable recovery admitted; required-source authority remains open | Native runtime owner |
| `SingleInstanceGuard` | Sprout | Isolate exact-process ownership from SwiftUI application setup. | Admitted; error split remains | Native shell owner |
| Rust evidence objects | Wrap | Admit only coarse durable state transitions across UniFFI. | Active | Durable-state owner |

## Debt Budget & Broken-Windows Policy

- P0 audio-loss, false-recording, privacy, and unrecoverable-state debt blocks feature expansion.
- Reserve **20% of each implementation slice** for retiring debt on the exact seam being changed; owner: slice lead; priority: P1.
- Characterize surprising behavior before changing it. A test that pins a bug must reference a ledger item and must not be presented as product correctness.
- Do not add unowned TODO/FIXME markers. New debt requires an ID, risk, priority, owner, and retirement evidence.
- Do not use broad cleanup or architectural rewrites to erase unknown-owner work.

## Adopted Conventions

- Rust owns durable state and authoritative evidence; Swift owns Apple-only UI and platform adapters.
- Frame-rate media stays on the Swift/native side of the ordinary UniFFI boundary.
- UI state names must match available evidence; `capturing` is not `Recording`.
- Audio preservation is independent of transcription success.
- Source, test, build, runtime, recovery, signing, release, and public-user evidence remain separate.
- Every externally sourced dependency, model, or asset needs provenance, license, integrity, update, and rollback review before adoption.
