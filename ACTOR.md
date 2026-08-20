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
- Authority: read-only Cargo metadata.
- Preconditions: a parseable root `Cargo.toml`.
- Command: `cargo metadata --locked --no-deps --format-version 1`.
- Expected result: every intended placeholder crate appears once under this repository.
- Proof: `cargo metadata --locked --no-deps --format-version 1 | jq -r '.packages[].name'`.
- Rollback: none.
- Stop if: a shared crate gains a native dependency or metadata resolves outside this root.

## Validate the founding scaffold

- Use when: changing doctrine, manifests, placeholder crates, scripts, or scaffold layout.
- Authority: local structure verification requested by the operator.
- Preconditions: no expectation that product behavior exists.
- Command: `./script/check.sh --scaffold`.
- Expected result: an explicit `SCAFFOLD_GREEN` receipt.
- Proof: command exit code 0 plus the named receipt.
- Rollback: revert only the in-scope authored edit; preserve unrelated work.
- Stop if: the default product check is bypassed, a missing runtime is represented as implemented, or the command reports a boundary violation.

## Inspect final local changes

- Use when: preparing a handoff.
- Authority: read-only diff inspection.
- Command: `git diff --check`, `git diff --stat`, and `git status --short --branch`.
- Expected result: no whitespace error and a complete, bounded path list.
- Proof: command outputs tied to this checkout.
- Rollback: none.
- Stop if: unexpected files, another writer's changes, or generated artifacts appear.

## Confirm an execution lane is still closed

- Use when: checking whether a product lane has actually been implemented.
- Authority: local fail-closed inspection.
- Command: `./script/check.sh`, `./script/build_web.sh`, `./script/test_capture.sh`, `./script/verify_bundle.sh`, or `./script/release.sh`.
- Expected result now: exit 64 with an explicit `NOT_IMPLEMENTED` message.
- Proof: inspect the exit code and named excluded capability.
- Rollback: none.
- Stop if: an unimplemented lane returns success or a placeholder is used as capability proof.

## Validate the Milestone 0 native proof

- Use when: changing the SwiftUI shell, UniFFI boundary, generated bindings, or native build path.
- Authority: local M0 implementation and verification requested by the operator.
- Command: `./script/check.sh --m0-native`.
- Expected result: `M0_NATIVE_GREEN` followed by `M0_NATIVE_CHECK_GREEN`.
- Proof: scaffold checks, one Rust boundary test, byte-consistent generated bindings, one Swift binding test, development app assembly, exact staged process identity, and primary/menu-bar/Settings scene logs from that process.
- Rollback: remove only the M0-native implementation and ADR 0001; no durable or external state exists.
- Stop if: generated bindings drift, Swift bypasses Rust state, a protected capability appears, or the receipt is represented as signing/release proof.

## Admission rule

Do not add hypothetical build, launch, test, deploy, signing, notarization, capture, or release actions. Execute and inspect them first. Canonical unimplemented scripts fail closed by design.
