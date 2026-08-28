# Open Scribe Verified Actions

> **Budget:** 600 words. Record only commands successfully executed in this repository.

Before mutation, inspect checkout identity, dirt, anchors, and rollback.

## Inspect repository identity

- Command: `git status --short --branch` and `git worktree list --porcelain`.
- Expected: exact branch, worktree, dirt.
- Stop if: the checkout, owner, or dirty state conflicts with the assigned lane.

## Inspect workspace packages

- Command: `cargo metadata --locked --no-deps --format-version 1`.
- Expected: each intended crate appears once here.
- Stop if: a shared crate gains a native dependency or metadata resolves outside this root.

## Validate the founding scaffold

- Command: `./script/check.sh --scaffold`.
- Expected: exit 0 with `SCAFFOLD_GREEN`.
- Stop if: runtime is overstated or a boundary fails.

## Inspect final local changes

- Command: `git diff --check`, `git diff --stat`, and `git status --short --branch`.
- Expected: clean whitespace and bounded paths.
- Stop if: unexpected files, another writer's changes, or generated artifacts appear.

## Validate the Milestone 0 native proof

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
- Proof: Rust/UniFFI guards, WASM checks, fresh bindings, Swift state/accessibility tests, unsigned-app launch, and diff hygiene.
- Stop if: hot-path values cross UniFFI, Starting becomes durable, recording truth diverges, or fixtures are claimed as I/O.

## Validate durable preparation and media-open

- Commands: `./script/check.sh --m1-storage` for Rust preparation; `./script/check.sh --m1-media-open` for Swift/Rust media-open integration.
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
- Stop if: post-seal writes occur, unrelated state closes, writer counters are overstated, Recording is asserted, or a higher plane is claimed.

## Validate durable interruption state

- Command: `./script/check.sh --m1-interruption-state`.
- Expected: `M1_INTERRUPTION_STATE_GREEN`.
- Proof: earlier gates; typed content-free reasons; journal-first interrupted projection; idempotent replay; restart reconciliation; unchanged partial media; coarse bindings; focused Swift failures.
- Stop if: interruption edits media, recovery is called playable, `Recording` is asserted, or a higher plane is claimed.

## Validate explicit live microphone capture

- Command: `./script/check.sh --m1-live-microphone`.
- Expected: `M1_LIVE_MICROPHONE_GREEN` after consent, capture, seal, digest, and playability checks; proof media is deleted.
- Does not prove: multi-source Recording, recovery, signing, or release.

## Validate forced-termination recovery

- Command: `./script/check.sh --m1-forced-termination-recovery`.
- Expected: `M1_FORCED_TERMINATION_RECOVERY_GATE_GREEN`.
- Proof: microphone; external kill; strict CAF recovery; persistent playback; independent decode; unchanged SHA-256; idempotence.
- Stop if: recovery mutates media, promotes invalid media, duplicates a receipt, or asserts `Recording`.

## Admission rule

Release readiness: `./script/release.sh prepare <semver>`; a hold names exact blockers and performs no publication.

Do not add hypothetical build, launch, test, deploy, signing, notarization, capture, or release actions. Execute and inspect them first. Canonical unimplemented scripts fail closed by design.
