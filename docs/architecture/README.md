# Architecture Decision Register

`/ARCHITECTURE.md` describes current repository fact and the intended founding shape. Decisions that materially refine or supersede that shape belong in numbered ADRs here.

ADR 0001 is accepted only for the Milestone 0 native development proof. It does
not settle distribution or later product capabilities.

## Required founding decisions

| Proposed ADR | Status |
|---|---|
| SwiftUI + Rust + Leptos ownership | native slice recorded by ADR 0001; website record pending |
| UniFFI control boundary and binding lifecycle | ADR 0001, M0 development lifecycle only |
| capture ownership and hot-path boundary | open |
| persistence/event/recovery model | open |
| local ASR/model engine | open |
| diarization model and calibration | open |
| minimum macOS and availability fallbacks | open |
| application sandbox and entitlements | open |
| Sparkle/update mechanism | open |
| remote-provider content-scope policy | founding invariant; implementation ADR pending |
| website foundation import and upstream-sync policy | open |
| toolchain and dependency pinning | open |

## ADR admission requirements

Each ADR must include status, date, owner/approver, context/evidence, decision, alternatives, consequences, security/privacy impact, migration and rollback, proof, and any founding-PRD clauses it supersedes. “Proposed” is not “approved.”
