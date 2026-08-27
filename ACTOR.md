# Open Scribe Verified Actions

> **Budget:** 600 words. Record only commands successfully executed in this repository.

Before mutation, inspect checkout identity, dirt, anchors, and rollback.

## Inspect repository identity

- Use when: starting/resuming.
- Command: `git status --short --branch` and `git worktree list --porcelain`.
- Expected: exact branch, worktree, dirt.
- Stop if: the checkout, owner, or dirty state conflicts with the assigned lane.

## Inspect workspace packages

- Use when: changing Rust membership/dependencies.
- Command: `cargo metadata --locked --no-deps --format-version 1`.
- Expected: each intended crate appears once here.
- Stop if: a shared crate gains a native dependency or metadata resolves outside this root.

## Validate the founding scaffold

- Use when: changing doctrine, manifests, placeholders, scripts, or scaffold.
- Command: `./script/check.sh --scaffold`.
- Expected: exit 0 with `SCAFFOLD_GREEN`.
- Stop if: runtime is overstated or a boundary fails.

## Inspect final local changes

- Use when: preparing handoff.
- Command: `git diff --check`, `git diff --stat`, and `git status --short --branch`.
- Expected: clean whitespace and bounded paths.
- Stop if: unexpected files, another writer's changes, or generated artifacts appear.

## Validate the Milestone 0 native proof

- Use when: changing SwiftUI, UniFFI, bindings, or native build.
- Command: `./script/check.sh --m0-native`.
- Expected: `M0_NATIVE_GREEN`, then `M0_NATIVE_CHECK_GREEN`.
- Proof: scaffold, Rust/Swift boundary, bindings, app assembly, process identity, scene logs.
- Stop if: bindings drift, Swift bypasses Rust truth, protected capability appears, or signing/release is claimed.

## Close Milestone 0

- Use when: admitting work beyond M0.
- Command: `./script/check.sh --m0`.
- Expected: `M0_COMPLETE_GREEN`.
- Stop if: any component fails or a higher proof is claimed.

## Validate deterministic state fixtures

- Use when: changing session semantics, coarse UniFFI, or fixture surfaces.
- Command: `./script/check.sh --state-fixtures`.
- Expected: `STATE_FIXTURES_GREEN`.
- Proof: Rust/UniFFI guards, WASM checks, fresh bindings, Swift state/accessibility tests, unsigned-app launch, and diff hygiene.
- Stop if: hot-path values cross UniFFI, Starting becomes durable, recording truth diverges, or fixtures are claimed as I/O.

## Validate durable preparation and media-open

- Use when: changing store/journal recovery, coarse media, or Swift writer.
- Commands: `./script/check.sh --m1-storage` for Rust preparation; `./script/check.sh --m1-media-open` for Swift/Rust media-open integration.
- Expected: the command's named green receipt.
- Proof: durable schema/journal, interruption/tamper checks, create-new CAF, fresh bindings, Xcode/M0.
- Stop if: preparation becomes Recording, invalid evidence is repaired, buffers cross UniFFI, or higher proof is claimed.

## Validate the microphone foundation

- Use when: changing first sample, CAF writer, microphone adapter, permissions, or security settings.
- Command: `./script/check.sh --m1-microphone-foundation`.
- Expected: `M1_MICROPHONE_FOUNDATION_GREEN`.
- Proof: earlier gates, durable first sample, bounded Swift buffers, synthetic conversion, coarse bindings, permissions/entitlements, unsigned build, focused tests.
- Stop if: hot media crosses UniFFI, first sample asserts Recording, callbacks block, or higher proof is claimed.

## Validate bounded segment sealing

- Use when: changing CAF close/seal, final receipts, digests, projection, or seal recovery.
- Command: `./script/check.sh --m1-segment-sealing`.
- Expected: `M1_SEGMENT_SEALING_GREEN`.
- Proof: earlier gates; close-before-receipt; Rust identity/length/header/SHA-256; journal-first, segment-local projection; interruption convergence.
- Stop if: post-seal writes occur, unrelated state closes, writer counters are overstated, Recording is asserted, or a higher plane is claimed.

## Validate explicit live microphone capture

- Command: `./script/check.sh --m1-live-microphone`.
- Expected: `M1_LIVE_MICROPHONE_GREEN` after consent, capture, seal, digest, and playability checks; proof media is deleted.
- Does not prove: multi-source Recording, recovery, signing, or release.

## Admission rule

Do not add hypothetical build, launch, test, deploy, signing, notarization, capture, or release actions. Execute and inspect them first. Canonical unimplemented scripts fail closed by design.
