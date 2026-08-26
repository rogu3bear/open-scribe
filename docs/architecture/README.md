# Architecture Decision Register

`/ARCHITECTURE.md` describes current repository fact and the intended founding shape. Decisions that materially refine or supersede that shape belong in numbered ADRs here.

ADR 0001 is accepted only for the Milestone 0 native development proof. It does
not settle distribution or later product capabilities.

ADR 0002 pins the M0 Rust proof toolchain and defines its least-privilege CI
boundary. It does not admit packaging, signing, deployment, or release work.

ADR 0003 records the selective website-template import, rejects automatic
upstream synchronization and starter state, and pins the M0 Swift/Xcode and web
toolchains. It proves local web artifacts only, never deployment.

ADR 0004 records deterministic session truth, fixture-only native presentation,
and the coarse UniFFI command/snapshot contract. It proves no capture or I/O.

ADRs 0005–0007 admit Milestone 1 implementation: Swift capture/media hot
paths with Rust policy, recoverable segmented media and serialized SQLite/journal
storage, and the macOS 13 sandboxed permission/playback/import boundary. They
remain architecture decisions until real artifact and failure-matrix proof exists.
The first ADR 0006 slices now provide native SQLite schema v2, durable session
intent, a synchronized bounded journal, deterministic restart classification,
and one Rust-authorized initial CAF path. A Swift-owned harness creates and
retains a real 48 kHz mono PCM CAF; only coarse authorization and media-open
receipts cross UniFFI. Rust independently validates the managed path, regular
file identity, byte length, and CAF header before projecting `media_files_open`.
The next bounded slice closes one synthetic Swift-written CAF before a coarse
seal receipt, then lets Rust revalidate file identity, exact byte length, and
header, compute SHA-256, and journal/project the named segment only. Writer-reported
sample totals are bound to the digest but are not independently derived. The
durable lifecycle remains `preparing`: this does not capture a microphone or
system source, authorize Recording, validate playable CAF packets, finalize
sessions, or prove recovery after real process termination.

ADRs 0008–0010 admit Milestone 2 implementation: pinned local ASR and licensed
model supply, authoritative transcript/diarization semantics, and versioned
ordinary/portable exports. They prove no inference result or redistributed model.

ADRs 0011–0012 admit Milestone 3 implementation: explicit epoch-bound context
scope, exact accessible overlay projection, and isolated local reduction into
sparse events with no pixel retention by default. They prove no context runtime.

ADRs 0013–0014 admit Milestone 4 implementation: immutable evidence lineage,
validated derived claims and durable human adjudication, plus separately scoped
local/remote providers with receipts and no tool capability. They prove no model run.

ADRs 0015–0017 admit Milestone 5 implementation after every prior runtime gate:
a capability-true static-first website, exact signed/notarized bundle and Sparkle
channel, and staged release authority through canonical readback. They prove no release.

## Required founding decisions

| Proposed ADR | Status |
|---|---|
| SwiftUI + Rust + Leptos ownership | native slice recorded by ADR 0001; website foundation recorded by ADR 0003 |
| UniFFI control boundary and binding lifecycle | ADR 0001, M0 development lifecycle only |
| capture ownership and hot-path boundary | ADR 0005; runtime proof open |
| persistence/event/recovery model | ADR 0006; implementation and forced-termination proof open |
| local ASR/model engine | ADR 0008; installed-model and offline runtime proof open |
| diarization model and calibration | ADR 0009; exact weight/calibration and runtime proof open |
| context scope, attention, and overlay semantics | ADR 0011; four-display and accessibility runtime proof open |
| local context reduction and pixel retention | ADR 0012; reducer, zero-retention, and isolation runtime proof open |
| evidence references, claims, and adjudication | ADR 0013; navigation, reprocessing, and deletion runtime proof open |
| intelligence provider, content scope, and model receipts | ADR 0014; exact local weights and provider/network/injection runtime proof open |
| capability/legal website consumers and final web behavior | ADR 0015; rendered/deployed capability-equality proof open |
| bundle identity, icon, signing, notarization, and updates | ADR 0016; exact artifact and clean-machine/update proof open |
| release automation, P0 gate, and canonical readback | ADR 0017; publication/deployment not authorized or performed |
| minimum macOS and availability fallbacks | ADR 0007; macOS 13/current runtime matrix open |
| application sandbox and entitlements | ADR 0007; signed entitlement/runtime proof open |
| Sparkle/update mechanism | ADR 0016; signed N−1 update proof open |
| remote-provider content-scope policy | ADR 0014; exact provider adapters and network proof open |
| website foundation import and upstream-sync policy | ADR 0003, M0 website only |
| toolchain and dependency pinning | Rust M0 proof pin recorded by ADR 0002; Swift/Xcode and web pins recorded by ADR 0003 |

## ADR admission requirements

Each ADR must include status, date, owner/approver, context/evidence, decision, alternatives, consequences, security/privacy impact, migration and rollback, proof, and any founding-PRD clauses it supersedes. “Proposed” is not “approved.”
