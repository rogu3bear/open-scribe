# Open Scribe Verified Actions

> **Budget:** 600 words. Record only commands successfully executed in this repository.

## Inspect repository state

- Commands: `git status --short --branch`, `git worktree list --porcelain`, `git diff --check`, `git diff --stat`.
- Stop if: checkout identity, dirty ownership, whitespace, scope, or generated-artifact residue conflicts with the lane.

## Inspect workspace packages

- Command: `cargo metadata --locked --no-deps --format-version 1`.
- Stop if: a crate duplicates, resolves outside this root, or leaks native dependencies into shared code.

## Validate the founding scaffold

- Command: `./script/check.sh --scaffold`.
- Expected: exit 0 with `SCAFFOLD_GREEN`.
- Stop if: runtime is overstated or a boundary fails.

## Validate the M0 native proof

- Command: `./script/check.sh --m0-native`.
- Expected: `M0_NATIVE_GREEN`, then `M0_NATIVE_CHECK_GREEN`.
- Proof: scaffold, Rust/Swift boundary, bindings, app assembly, process identity, scene logs.
- Stop if: bindings drift, Swift bypasses Rust truth, protected capability appears, or signing/release is claimed.

## Close Milestone 0

- Command: `./script/check.sh --m0`.
- Expected: `M0_COMPLETE_GREEN`.
- Stop if: any component fails or a higher proof is claimed.

## Validate deterministic state fixtures

- Command: `./script/check.sh --state-fixtures`.
- Expected: `STATE_FIXTURES_GREEN`.
- Proof: Rust/UniFFI guards, one Rust-owned runtime/library snapshot, WASM checks, fresh bindings, Swift state/accessibility tests, unsigned-app launch, diff hygiene.
- Stop if: hot-path values cross UniFFI, fixture state reaches product surfaces, Starting becomes durable, or recording truth diverges.

## Validate durable preparation and media-open

- Commands: `./script/check.sh --m1-storage` (Rust preparation); `./script/check.sh --m1-media-open` (Swift/Rust media-open integration).
- Expected: the command's named green receipt.
- Proof: durable schema/journal, interruption/tamper checks, create-new CAF, fresh bindings, Xcode/M0.
- Stop if: preparation becomes Recording, invalid evidence is repaired, buffers cross UniFFI, or higher proof is claimed.

## Validate the microphone foundation

- Command: `./script/check.sh --m1-microphone-foundation`.
- Expected: `M1_MICROPHONE_FOUNDATION_GREEN`.
- Proof: earlier gates, durable first sample, bounded Swift buffers, synthetic conversion, coarse bindings, permissions/entitlements, unsigned build, focused tests.
- Stop if: hot media crosses UniFFI, first sample asserts Recording, callbacks block, or higher proof is claimed.

## Validate bounded segment sealing

- Command: `./script/check.sh --m1-segment-sealing`.
- Expected: `M1_SEGMENT_SEALING_GREEN`.
- Proof: earlier gates; close-before-receipt; Rust identity/length/header/SHA-256; journal-first, segment-local projection; interruption convergence.
- Stop if: post-seal writes occur, unrelated state closes, writer counters overstate, Recording is asserted, or a higher plane is claimed.

## Validate durable interruption state

- Command: `./script/check.sh --m1-interruption-state`.
- Expected: `M1_INTERRUPTION_STATE_GREEN`.
- Proof: earlier gates; typed content-free reasons; journal-first interrupted projection; idempotent replay; restart reconciliation; unchanged partial media; coarse bindings; focused Swift failures.
- Stop if: interruption edits media, recovery is called playable, `Recording` is asserted, or a higher plane is claimed.

## Requalify short live dual-source capture

- Command: `./script/check.sh --m1-dual-source-runtime` (alias: `--m1-live-microphone`).
- Commit `467ed2e` app passed `M1_DUAL_SOURCE_RUNTIME_GREEN` (mono microphone, stereo system audio); proof media is retained.
- Does not prove: source loss, degraded continuation, permission revocation, application-scoped selection, long-session synchronization, signing, release.

## Requalify forced-termination recovery

- Command: `./script/check.sh --m1-forced-termination-recovery`.
- Expected: `M1_FORCED_TERMINATION_RECOVERY_GATE_GREEN`.
- Earlier app proved two-source recovery, native playback, unchanged CAF digests, and idempotence. Current gate source requires rotation before kill; no current-app receipt exists.
- Stop if: recovery mutates media, promotes invalid media, duplicates a receipt, or asserts `Recording`.

## Validate recorder components

- Commands (via `disk-guard run … --`): `cargo test --locked -p open-scribe-store`; `bash script/build_and_run.sh --verify-recording` (`RECORDING_COMPONENTS_GREEN`); `bash script/check_foundational_workflow.sh <app binary>` (`FOUNDATION_SYNTHETIC_GREEN`).
- Excludes: real capture, audible playback, signing, release.

## Admission rule

Release readiness: `./script/release.sh prepare <semver>`; a hold names exact blockers and performs no publication.

Do not add hypothetical build, launch, test, deploy, signing, notarization, capture, or release actions. Execute and inspect them first. Canonical unimplemented scripts fail closed by design.
