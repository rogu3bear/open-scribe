# Open Scribe Architecture

> **Budget:** 700 words. Fact and intent remain distinct.

## Current source and recorded proof

Rust owns durable lifecycle, journal, timing, evidence, recovery, policy, and exports. Swift owns Apple UI, permissions, capture/playback adapters, measurements, and bounded native buffers. UniFFI carries coarse controls, receipts, and projections.

Current source implements capture/import, local transcription, correction/search, and playback/export. Media-safety recovery completes before optional retained-transcript maintenance. Rust persists minimal per-session work intent and admits one runner; Swift supplies preferences and pressure observations and executes admitted work. Retry resumes incomplete tracks. Explicit reprocess creates replacement history under transactional selection/edit guards. Selected document availability and latest processing attempt are independent typed dimensions.

Rebuild from Saved Parts does no recognition. An empty or partial rebuild ends
its explicit request as `Incomplete` while missing tracks remain eligible for
later automatic or explicit transcription. It reports `Completed` only when its
plan covers every required incomplete track. The additional durable outcome is
read fail-closed by older builds; it does not change the SQLite schema version,
session v4, journal v1, or transcript reconciliation v3.

Local model-file copies use private per-attempt staging tokens and retain their
open inode through verification and installation. Retry creates a fresh attempt;
abandoned attempts and legacy download partials remain untouched. Normal failure
cleanup removes only the current attempt's unchanged single-link inode. Download
resume validators, manifest validation and pre-load verification retain their
existing contracts. This is no automatic model download or staging purge.

Development proof dispatch that uses the app's capture controller first awaits
the same isolated capture-safety recovery as the UI. A failed barrier refuses
the proof before it can request capture. Synthetic timeline recovery retains its
own evidence-preserving recovery entry point.

[Dated evidence](docs/TESTING.md#foundational-recording-workflow) binds short synthetic/live dual-source rotation, forced termination, unchanged recovery, and playback to unsigned artifacts. Those receipts do not qualify current source. M1 remains incomplete. Source loss, active revocation, application selection, long-session synchronization, signing, deployment, and release require their corresponding proof. Public capability statuses and model-review holds remain unchanged.

## Owners

| Component | Current responsibility |
|---|---|
| `apps/macos` | SwiftUI, Apple adapters, bounded buffers, CAF writer, OCR, permissions; no durable policy authority |
| `open-scribe-types` | WASM-safe state, intent, outcome, and observation vocabulary |
| `open-scribe-domain` | WASM-safe production admission/evidence predicates shared with fixture inputs; historical M0 fixture transitions |
| `open-scribe-evidence` | WASM-safe evidence IDs and validation; no model execution |
| `open-scribe-store` | SQLite/journal, session/source intent, clock/segment receipts, recovery, review/search, deletion, context, coherent projections |
| `open-scribe-core` | Production orchestration, transcription plans, retained reconciliation, import/export |
| `open-scribe-asr`, `open-scribe-models` | Pinned whisper.cpp execution and manifest verification/repair; other ML/memory crates remain placeholders |
| `open-scribe-uniffi` | Coarse native API; no independent lifecycle authority or frame-rate data |
| `web` | Stateless Leptos SSR foundation; no capture, app server, database, or deployment authority |
| `docs/legal` | Single legal-text source for app/site consumers |

## Native composition and critical flow

`LaunchConfiguration` validates modes, owned storage, and isolated preferences before native handles. Development proof dispatch lives in `ProofLaunchRunner`. Every test host supplies an isolated root. `RuntimeLibraryStore` owns projection/import presentation; `StructuredNativeIO` distinguishes cancellable reads from durable mutations. Fixture adapters remain separate.

Deliberate capture → all required sources and durable media/journal evidence → Rust-accepted Recording → preserved independent audio → capture-safety recovery → local derived transcription → corrected selected document/search → evidence-backed playback/export. Preparation or a single-source sample cannot establish all-source Recording. Derived maintenance never gates healthy capture after recovery.

Optional Meeting/context/intelligence remain intended lanes with existing bounded implementations preserved. Providers may propose structured deltas; Rust validates scope, status, provenance, and evidence. Interpretation remains adjudicable and distinct from source evidence. Provider selection alone authorizes no content scope.

## Compatibility and truth

| Concern | Canonical owner |
|---|---|
| Product and decisions | founding PRD; approved ADRs supersede only named clauses |
| Storage | Rust store, ADR 0006; session schema v4 and journal v1 retain their meanings |
| Review/scheduling/metadata additions | SQLite migrations 10–13; immutable runs/chunks/revisions, replacement scopes, append-only corrections |
| Evidence/export | evidence-ref/v1 and checked data-format schemas |
| Capability/model metadata | checked manifests; no parallel definitions |
| Commands and proof | `ACTOR.md`, `docs/TESTING.md`, named exact-artifact receipts |

Timed duration uses accepted frames and calibrated capture intervals; untimed legacy fallback remains limited. Metadata time and creation-based library ordering are independent. Cooperating handles serialize durable writes through an owned advisory lock; ASR and native decoding run outside durable transactions. Journal v1 append still validates and replaces history; counters characterize its growing cost without enabling a new format.

Portable packages omit context; failed transcript status restores as pending. Compressed import support does not imply portable round-trip support. Export warnings and existing capability rejection expose these limits.

Shared crates cannot depend on native I/O, SQLite, Apple APIs, network clients, or model runtimes. ADR 0018 owns disabled Actions and exact local candidate admission. Scaffold, component, native, installed, supported-platform, and release proof remain separate.
