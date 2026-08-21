# Open Scribe Verified Actions

> **Budget:** 600 words. Record only commands successfully executed in this repository.

Before mutation, inspect the exact checkout, branch, worktree, dirty state, applicable anchors, and rollback.

## Inspect repository identity

- Use when: beginning or resuming work.
- Authority: read-only repository inspection.
- Command: `git status --short --branch` and `git worktree list --porcelain`.
- Expected result: exact branch/worktree and dirty paths are visible.
- Proof: inspect both outputs before assigning ownership or editing.
- Rollback: none.
- Stop if: the checkout, owner, or dirty state conflicts with the assigned lane.

## Inspect workspace packages

- Use when: changing Rust crate membership or dependencies.
- Command: `cargo metadata --locked --no-deps --format-version 1`.
- Expected result: every intended crate appears once under this repository.
- Stop if: a shared crate gains a native dependency or metadata resolves outside this root.

## Validate the founding scaffold

- Use when: changing doctrine, manifests, placeholder crates, scripts, or scaffold layout.
- Authority: local structure verification requested by the operator.
- Command: `./script/check.sh --scaffold`.
- Expected result: an explicit `SCAFFOLD_GREEN` receipt.
- Proof: command exit code 0 plus the named receipt.
- Stop if: the default product check is bypassed, a missing runtime is represented as implemented, or the command reports a boundary violation.

## Inspect final local changes

- Use when: preparing a handoff.
- Authority: read-only diff inspection.
- Command: `git diff --check`, `git diff --stat`, and `git status --short --branch`.
- Expected result: no whitespace error and a complete, bounded path list.
- Stop if: unexpected files, another writer's changes, or generated artifacts appear.

## Validate the Milestone 0 native proof

- Use when: changing the SwiftUI shell, UniFFI boundary, generated bindings, or native build path.
- Authority: local M0 implementation and verification requested by the operator.
- Command: `./script/check.sh --m0-native`.
- Expected result: `M0_NATIVE_GREEN` followed by `M0_NATIVE_CHECK_GREEN`.
- Proof: scaffold checks, one Rust boundary test, byte-consistent generated bindings, one Swift binding test, development app assembly, exact staged process identity, and primary/menu-bar/Settings scene logs from that process.
- Stop if: generated bindings drift, Swift bypasses Rust state, a protected capability appears, or the receipt is represented as signing/release proof.

## Close Milestone 0

- Use when: admitting work beyond M0.
- Command: `./script/check.sh --m0`.
- Expected result: `M0_COMPLETE_GREEN` on the exact checkout.
- Stop if: any component fails or the receipt is represented as deployment, capture, distribution, release, or Milestone 1 authority.

## Validate deterministic state fixtures

- Use when: changing session records/transitions, coarse UniFFI commands/snapshots, or fixture-driven native surfaces.
- Command: `./script/check.sh --state-fixtures`.
- Expected result: `STATE_FIXTURES_GREEN` on this checkout.
- Proof: Rust/UniFFI round-trips and guards, shared-crate WASM checks, fresh bindings, Swift shared-store/symbol/accessibility tests, exact unsigned-app launch, and diff hygiene.
- Stop if: hot-path values cross UniFFI, Starting becomes durable, Recording lacks journal/media-open evidence, menu and window diverge, or fixture proof is claimed as capture/I/O.

## Validate durable preparation and media-open

- Use when: changing the native store, journal, recovery projection, coarse media protocol, or Swift writer harness.
- Commands: `./script/check.sh --m1-storage` for Rust preparation; `./script/check.sh --m1-media-open` for Swift/Rust media-open integration.
- Expected result: the command’s named green receipt on this checkout.
- Proof: WAL/full-sync schema, chained journal, deterministic interruptions, tamper rejection, create-new real CAF, fresh bindings, Xcode tests, and M0 regressions.
- Stop if: preparation enters Recording, invalid evidence is repaired, media buffers cross UniFFI, or either receipt is claimed as capture or process-termination proof.

## Admission rule

Do not add hypothetical build, launch, test, deploy, signing, notarization, capture, or release actions. Execute and inspect them first. Canonical unimplemented scripts fail closed by design.
