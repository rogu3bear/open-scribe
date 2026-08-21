# Open Scribe Verified Actions

> **Budget:** 600 words. Record only commands successfully executed in this repository.

Before mutation, inspect the checkout, dirty state, anchors, and rollback.

## Inspect repository identity

- Use when: beginning or resuming work.
- Command: `git status --short --branch` and `git worktree list --porcelain`.
- Expected: exact branch, worktree, and dirty paths.
- Stop if: the checkout, owner, or dirty state conflicts with the assigned lane.

## Inspect workspace packages

- Use when: changing Rust crate membership or dependencies.
- Command: `cargo metadata --locked --no-deps --format-version 1`.
- Expected: every intended crate appears once in this repository.
- Stop if: a shared crate gains a native dependency or metadata resolves outside this root.

## Validate the founding scaffold

- Use when: changing doctrine, manifests, placeholder crates, scripts, or scaffold layout.
- Command: `./script/check.sh --scaffold`.
- Expected: exit 0 with `SCAFFOLD_GREEN`.
- Stop if: the default product check is bypassed, a missing runtime is represented as implemented, or the command reports a boundary violation.

## Inspect final local changes

- Use when: preparing a handoff.
- Command: `git diff --check`, `git diff --stat`, and `git status --short --branch`.
- Expected: no whitespace error and a bounded path list.
- Stop if: unexpected files, another writer's changes, or generated artifacts appear.

## Validate the Milestone 0 native proof

- Use when: changing the SwiftUI shell, UniFFI boundary, generated bindings, or native build path.
- Command: `./script/check.sh --m0-native`.
- Expected: `M0_NATIVE_GREEN`, then `M0_NATIVE_CHECK_GREEN`.
- Proof: scaffold, Rust boundary, generated bindings, Swift binding, development app assembly, staged process identity, and scene logs.
- Stop if: generated bindings drift, Swift bypasses Rust state, a protected capability appears, or the receipt is represented as signing/release proof.

## Close Milestone 0

- Use when: admitting work beyond M0.
- Command: `./script/check.sh --m0`.
- Expected: `M0_COMPLETE_GREEN` on the exact checkout.
- Stop if: any component fails or the receipt is represented as deployment, capture, distribution, release, or Milestone 1 authority.

## Validate deterministic state fixtures

- Use when: changing session records/transitions, coarse UniFFI commands/snapshots, or fixture-driven native surfaces.
- Command: `./script/check.sh --state-fixtures`.
- Expected: `STATE_FIXTURES_GREEN` on this checkout.
- Proof: Rust/UniFFI guards, WASM checks, fresh bindings, Swift state/accessibility tests, unsigned-app launch, and diff hygiene.
- Stop if: hot-path values cross UniFFI, Starting becomes durable, Recording lacks journal/media-open evidence, menu and window diverge, or fixture proof is claimed as capture/I/O.

## Validate durable preparation and media-open

- Use when: changing the native store, journal, recovery projection, coarse media protocol, or Swift writer harness.
- Commands: `./script/check.sh --m1-storage` for Rust preparation; `./script/check.sh --m1-media-open` for Swift/Rust media-open integration.
- Expected: the command's named green receipt.
- Proof: WAL/full-sync schema, chained journal, interruption/tamper checks, create-new CAF, fresh bindings, Xcode tests, and M0 regressions.
- Stop if: preparation enters Recording, invalid evidence is repaired, media buffers cross UniFFI, or either receipt is claimed as capture or process-termination proof.

## Validate the microphone foundation

- Use when: changing first-sample evidence, the managed CAF writer, microphone adapter, permission mapping, or app security settings.
- Command: `./script/check.sh --m1-microphone-foundation`.
- Expected: `M1_MICROPHONE_FOUNDATION_GREEN` on this checkout.
- Proof: earlier gates; durable one-shot first-sample recovery; bounded Swift buffer path; synthetic conversion; coarse bindings; permission, entitlement, and unsigned build metadata; focused tests; diff hygiene.
- Stop if: a buffer or frame-rate stream crosses UniFFI, first-sample evidence asserts Recording, the adapter blocks its callback, or the receipt is claimed as live-device, signed-runtime, recovery, or release proof.

## Admission rule

Do not add hypothetical build, launch, test, deploy, signing, notarization, capture, or release actions. Execute and inspect them first. Canonical unimplemented scripts fail closed by design.
