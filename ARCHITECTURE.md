# Open Scribe Architecture

> **Budget:** 700 words. Fact and intent remain distinct.

## Current source and recorded proof

Rust owns lifecycle, journal, shared timing, recovery, and the coarse live/library snapshot. Swift owns segmented CAF capture and native playback. [Dated evidence](docs/TESTING.md#foundational-recording-workflow) binds short synthetic/live dual-source rotation, forced termination, unchanged recovery, and shared playback to an unsigned artifact. Those receipts do not qualify a new candidate. M1 remains incomplete; source loss, active revocation, application selection, long sessions, ML, signing, deployment, and release remain unproved.

## Intended runtime shape

SwiftUI uses Apple adapters; UniFFI connects to Rust. Leptos targets Workers. Shared semantics enter WASM-safe crates.

## Intended ownership

| Component | Status | Owns | Must not own |
|---|---|---|---|
| `apps/macos` | recorder/library/context shell + fixtures | SwiftUI, Apple adapters, bounded buffers, CAF writer, OCR, permission UX | durable policy, capture claims, evidence truth |
| `crates/open-scribe-types` | implemented, WASM-safe | stable session/source/condition records | I/O or native APIs |
| `open-scribe-domain` | implemented, WASM-safe | transitions and presentation | persistence or capture |
| `open-scribe-evidence` | evidence-ref/v1, WASM-safe | evidence IDs and validation semantics | model execution or native storage |
| `open-scribe-store` | recorder/timeline foundation | session intent, journal, SQLite, clock/segment receipts, recovery, transcripts/review/search/deletion/context, runtime/library projection | buffers, capture, UI-local authority |
| other native Rust crates | core/asr/models: whisper.cpp; rest placeholders | transcription, later ML/memory | Apple UI or permission UX |
| `open-scribe-uniffi` | coarse boundary | fixtures, preparation, segment receipts, recorder controls, timelines, imports, leases, snapshots, transcript library, speech models, context | state authority or hot-path data |
| `web` | M0 foundation | stateless Leptos SSR | capture, app backend, database, deployment authority |
| `docs/legal` | present drafts | single legal-text source for future app/site consumers | duplicated edited copies |

## Intended critical flows

### Capture and recovery

1. User explicitly requests capture through Swift UI.
2. Swift platform adapters establish sources and durable media/journal prerequisites.
3. Rust validates the coarse transition and records lifecycle/source metadata.
4. Rust projects one coarse snapshot to the main window and menu; only that snapshot may let UI report Recording.
5. Media remains recoverable independently of transcript or ML.

Tests cover required-source planning, all-source `Recording`, CAF writing/sealing, interruption, timeline mapping, and segmented recovery. Runtime gates exercised capture, decode, external kill, unchanged recovery, playback, and idempotence before segmented capture. Short rotation evidence does not prove source-loss continuation, permission revocation, application selection, or long-session synchronization.

### Derived meeting memory

1. Evidence enters Rust through bounded typed interfaces.
2. A provider may propose a structured delta but cannot write storage.
3. Rust validates status, scope, provenance, and references.
4. Interpretation stays distinct from evidence and supports adjudication.

## Sources of truth

| Concern | Canonical owner | Derived consumers |
|---|---|---|
| Founding product | `docs/product/FOUNDING_PRD.md` | north star, anchors, architecture, ADRs |
| Session fixture schema | `open-scribe-types` + ADR 0004 | domain snapshots, UniFFI, Swift fixture views |
| Session/storage schema | [Rust store](crates/open-scribe-store/src/lib.rs) + ADR 0006 | SQLite projection, journal, recovery classification |
| Live and library presentation state | `open-scribe-store` SQLite projection | coarse UniFFI snapshot, main window, menu bar |
| Evidence/export schema | `open-scribe-evidence` + [transcript/v1](docs/data-format/transcript.v1.schema.json) | exports, package import, runtime views |
| Legal text | `docs/legal/*` | app and website rendering |
| Capability claims | [checked manifest](docs/capabilities/manifest.v1.json) | runtime registry, UI, website, release claims |
| Model metadata | [checked manifest](docs/models/manifest.v1.json), review-pending entries | intended model manager, notices, website |

## Boundaries

- Media hot paths stay outside UniFFI callbacks.
- Shared crates cannot depend on native crates, I/O, SQLite, Apple APIs, network clients, or model runtimes.
- SQLite/filesystem state is authority.
- Remote providers receive only per-category authorization and never execute tools.

## Architecture decisions

ADRs 0001–0004 settle M0; 0005–0007 admit M1 implementation; 0008–0017 cover later milestones. Decisions do not prove runtime completion. [ADR 0018](docs/architecture/0018-local-proof-and-disabled-repository-actions.md) owns disabled Actions and exact local candidate admission. See the [decision register](docs/architecture/README.md).

## Current validation

`script/check.sh --scaffold` checks structure/WASM; `--state-fixtures` checks snapshots, bindings, native tests, and idle launch. Its `--m1-dual-source-runtime` and `--m1-forced-termination-recovery` gates predate segmented capture and need requalification. `--m1-complete` remains fail-closed. Commands and exclusions belong in `ACTOR.md` and `docs/TESTING.md`; no lower gate proves release.
