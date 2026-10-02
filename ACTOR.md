# Open Scribe Verified Actions

> **Budget:** 600 words. Record only commands successfully executed in this repository.

## Inspect repository state

- Commands: `git status --short --branch`, `git worktree list --porcelain`, `git diff --check`, `git diff --stat`.
- Stop if: identity, dirty ownership, whitespace, scope, or generated residue conflicts with the lane.

## Inspect workspace packages

- Command: `cargo metadata --locked --no-deps --format-version 1`.
- Stop if: a crate duplicates, resolves outside this root, or leaks native dependencies into shared crates.

## Validate the founding scaffold

- Command: `./script/check.sh --scaffold`.
- Expected: exit 0 with `SCAFFOLD_GREEN`.
- Stop if: runtime is overstated or a boundary fails.

## Validate the M0 native proof

- Command: `./script/check.sh --m0-native`.
- Expected: `M0_NATIVE_GREEN`, then `M0_NATIVE_CHECK_GREEN`.
- Stop if: bindings drift, Swift bypasses Rust truth, protected capability appears, or signing/release is claimed.

## Close Milestone 0

- Command: `./script/check.sh --m0`.
- Expected: `M0_COMPLETE_GREEN`.
- Stop if: any component fails or a higher proof is claimed.

## Validate deterministic state fixtures

- Command: `./script/check.sh --state-fixtures`.
- Expected: `STATE_FIXTURES_GREEN`.
- Stop if: hot-path values cross UniFFI, fixture state reaches product surfaces, Starting becomes durable, or recording truth diverges.

## Validate durable preparation and media-open

- Commands: `./script/check.sh --m1-storage` (Rust preparation); `./script/check.sh --m1-media-open` (Swift/Rust media-open integration).
- Expected: the command's named green receipt.
- Stop if: preparation becomes Recording, invalid evidence is repaired, buffers cross UniFFI, or higher proof is claimed.

## Validate the microphone foundation

- Command: `./script/check.sh --m1-microphone-foundation`.
- Expected: `M1_MICROPHONE_FOUNDATION_GREEN`.
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

## Short live dual-source capture evidence

- Command: `./script/check.sh --m1-dual-source-runtime --candidate RECORD`.
- `072a3fb` passed `M1_DUAL_SOURCE_RUNTIME_GREEN`; exact record, digests, and retained media: `docs/TESTING.md`.
- Excludes: source loss, revocation, application scope, long-session synchronization, signing, release.

## Forced-termination recovery evidence

- Command: `./script/check.sh --m1-forced-termination-recovery --candidate RECORD`.
- `072a3fb` passed `M1_FORCED_TERMINATION_RECOVERY_GATE_GREEN`: rotation, external kill, playback, unchanged CAFs, idempotent recovery.
- Stop if: recovery mutates media, promotes invalid media, duplicates a receipt, or asserts `Recording`.

## Validate candidate record tooling

- Commands: `bash script/check_candidate_record.sh`; `bash script/check_native_contracts.sh`; `ruby script/check_m1_injected_contract.rb`; `bash script/check_m1_operator_snapshot.sh`.
- Expected: `CANDIDATE_RECORD_TEST_GREEN` (14 rejections); `M1_COMPLETE_RECEIPT_TEST_GREEN` (6 fixtures); `NATIVE_CONTRACT_GREEN`; `M1_HARNESS_CONTRACT_GREEN` (14 fixtures).
- Excludes: builds, runtime, capture, signing, release.

## Qualify one contributor build

- Command: `disk-guard run --budget-gb 3 --volume "$PWD" -- ./script/check.sh --candidate RECORD`.
- `10201d2` passed `CONTRIBUTOR_CANDIDATE_GREEN`. Use measured capacity and a new record path; runtime consumers never rebuild.

## Injected M1 failure cases

- Command: `disk-guard run --budget-gb 0.25 --volume "$PWD" -- ./script/check.sh --m1-injected-failures --candidate RECORD --case CASE` (2 GB for `storage-exhaustion`; `live-pause-resume` uses real devices).
- `10201d2` passed all fourteen; `--m1-complete --candidate RECORD` then held only on two-hour synchronization and the human matrix.

## Local verification

- `./script/build_and_run.sh --verify`: `NATIVE_FIXTURE_XCODE_GREEN`; `./script/build_web.sh`: `WEB_BUILD_GREEN`; then `./script/check.sh --m4-local-only`: `M4_LOCAL_ONLY_GREEN`.
- `./script/stage_proof_inputs.sh /absolute/dir`: `PROOF_INPUTS_READY`; its `env.sh` feeds `cargo test -p open-scribe-asr -p open-scribe-core`, native verify, and local-only. Unset: skip/hold.

## Admission rule

Release readiness: `./script/release.sh prepare <semver>`; a hold names exact blockers and performs no publication.

Unimplemented scripts fail closed.
