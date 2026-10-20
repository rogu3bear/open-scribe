# Recording Workflow Technical Debt Pass

## Context

Started October 19, 2026, on the existing recording-workflow PR #21. The entry
checkout was clean at `6f16330613a996f7936d324c0450bf6f3831ae79`, based on
`main` at `657cf3e61bf6383e81ef48b0dee658ef86bab7dd`. This pass preserves that
implementation and its pending integration gates. It does not reopen capture,
model, journal-format, signing or release decisions.

Open Scribe is a local SwiftUI/Apple-adapter application with a Rust durable
core, SQLite and coarse UniFFI. Recorded repository history begins August 20,
2026; age alone is not the reason to change it. Loss of accepted audio,
displacement of reviewed text, private-content disclosure and false operational
state are the consequential failure modes. There is no rewrite proposal.

The selected entry is `ImportedMediaAuthorityAdapter.chooseAndImport`: it is
being changed in this PR, has eight source-history commits, and mediates the
preservation-critical cancellation boundary. `TranscriptLibraryModel` has
twelve commits; it is a consumer to preserve, not a second refactoring target.
The [Safety Net Map](TESTING.md#recording-workflow-change-points--october-19-2026)
records the effect sketch, existing seams, pinned paths and excluded gaps.

The last exact source candidate passed Rust workspace tests and a native
build-only check. Actions is disabled by ADR 0018, rather than for flaky tests.
The contributor native runtime gate remains unperformed under the human's
no-screen instruction. Supported signed distribution and broader production
use are not established by this pass. No outbound service or model is needed
for the injected checks; existing provider/model policy is unchanged.

## Phase Status

| Phase | Skill | Status | Artifact | Date |
|---|---|---|---|---|
| 1 | working-with-legacy-code | done | Existing `TESTING.md` and `TECH-DEBT.md`; checked-in offscreen characterization runner, limited to the mapped pinned paths | 2026-10-19 |
| 2 | refactoring-patterns | pending | Existing `TECH-DEBT.md` | |
| 3 | clean-code | pending | Existing `TECH-DEBT.md` | |
| 4 | software-design-philosophy | pending | Existing `TECH-DEBT.md` | |
| 5 | clean-architecture | pending | Existing root `ARCHITECTURE.md` | |
| 6 | pragmatic-programmer | pending | Existing `TECH-DEBT.md` | |
| 7 | release-it | pending | Existing reliability/release owners; resolve only when this phase starts | |
| 8 | domain-driven-design | pending | Existing root `ARCHITECTURE.md` | |

Phase 1 completes one focused test-and-documentation slice. Later
transformations require a named need and the mapped green safety net. Unpinned
paths and map gaps are off-limits. The journey remains open; pending phases are
not a claim that all eight are required for this small slice or already done.

## Key Decisions

| Date | Phase | Decision | Source and rationale |
|---|---|---|---|
| 2026-10-19 | 1 | Start at the current import change point, retain audio and all gates, run only safe offscreen checks | Existing human recording-workflow scope plus explicit invocation of `remove-technical-debt`; current source/churn inspection |
| 2026-10-19 | 1 | Use the supplied Phase 1 Brief | The constituent `working-with-legacy-code` skill is unavailable in the installed skill inventory; no installation needed |
| 2026-10-19 | 1 | Promote the actual-production-component helper into a checked-in test entry | Replaces ad hoc wiring (TD-014), reuses constructor seams, and requires no product behavior change or new framework |
| 2026-10-19 | 1 | Pin and ledger any newly discovered quirks; do not fix behavior during characterization | Explicitly invoked skill rule 8; existing debt policy already requires characterization before correction |
| 2026-10-19 | 1 | Keep tests and documentation in separate single-purpose commits in PR #21 | Invoked skill's commit rule and existing one-PR scope; any successor head makes the earlier exact review stale |

## Next Actions

- [ ] Refresh PR #21 and its exact contextless review after the separate test and documentation commits.
- [ ] Select a concrete structural or legibility paydown only from green pinned paths; retain native-host/renderer gaps and the complete contributor merge gate.

## Phase 1 Result

The normal 16 GB Disk Guard run completed successfully on October 19
(2026-10-20T02:08:18Z): `IMPORT_COMPONENT_CHECK_GREEN`, with six named cases:
clock, overlap, partial batch, cancelled batch, paused batch and capture hold.
No product behavior changed and no new runtime bug was discovered. The existing
partial-failure and cancel-after-commit outcomes are characterized as-is.

The input manifest SHA-256 is
`4522b5fd22a09d9f0bdd1d4f8940c606489270d52bcfce22aae0c1aec19cf87c`;
the executable SHA-256 is
`8052f9034fa2b47d5d9f4cc01f406f83b3bb26b16d42914c46750f5ddefa1e7e`.
The before/after manifests match. The fresh archive and regenerated bindings
were used with the pinned Apple tools; Swift compilation denies warnings.
Local run outputs are retained in
`apps/macos/.build/import-components-debt-r1/`, with the existing task evidence
under `.agent/ledger/integration-repair-20261015/release-qualification/`.
These ignored outputs are evidence custody, not required repository inputs.

The receipt's source HEAD is the pre-commit `6f16330`; the new test and script
inputs are bound by their manifest hashes. Commit publication does not promote
that result to a contributor-candidate receipt. Any changed input needs fresh
affected proof. The suite never constructs an application, opens a library,
touches recordings or uses a model. Native UI/renderer, real-audio ASR, macOS 13
runtime, the complete contributor gate and all release qualification remain
unperformed. TD-014 retires only the ad hoc wiring/provenance debt.
