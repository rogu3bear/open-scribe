# Open Scribe Architecture

> **Budget:** 700 words. Fact and intent remain distinct.

## Current repository fact

Open Scribe has M0 and bounded dual-source runtime proof. Rust owns `Recording`, interruption, atomic recovery, and the coarse live/library snapshot used by both native surfaces. Exact unsigned runs prove simultaneous capture, decode, forced termination, unchanged two-track recovery, and idempotent relaunch. Source loss, application selection, long sessions, ML, signing, deployment, and release remain unproved.

## Intended runtime shape

SwiftUI uses Apple adapters; UniFFI connects to Rust. Leptos targets Workers. Shared semantics enter WASM-safe crates.

## Intended ownership

| Component | Status | Owns | Must not own |
|---|---|---|---|
| `apps/macos` | native recorder/library shell + test fixtures | SwiftUI, Apple adapters, bounded buffers, CAF writer, permission UX | durable policy, capture claims, evidence truth |
| `crates/open-scribe-types` | implemented, WASM-safe | stable session/source/condition records | I/O or native APIs |
| `open-scribe-domain` | implemented, WASM-safe | transitions and presentation | persistence or capture |
| `open-scribe-evidence` | placeholder, WASM-safe | evidence IDs and validation semantics | model execution or native storage |
| `open-scribe-store` | bounded dual-source recording and recovery | session intent, journal, SQLite, media/first-sample/seal/interruption/recovery receipts, coarse runtime/library projection | buffers, capture, UI-local authority |
| other native Rust crates | placeholders | later ML and memory | Apple UI or permission UX |
| `open-scribe-uniffi` | coarse boundary | fixtures, preparation, one-shot media receipts, runtime/library snapshots | state authority or hot-path data |
| `web` | M0 foundation | stateless Leptos SSR | capture, app backend, database, deployment authority |
| `docs/legal` | present drafts | single legal-text source for future app/site consumers | duplicated edited copies |

## Intended critical flows

### Capture and recovery

1. User explicitly requests capture through Swift UI.
2. Swift platform adapters establish sources and durable media/journal prerequisites.
3. Rust validates the coarse transition and records lifecycle/source metadata.
4. Rust projects one coarse snapshot to the main window and menu; only that snapshot may let UI report Recording.
5. Media remains recoverable independently of transcript or ML.

Tests cover required-source planning, all-source `Recording`, CAF writing/sealing, interruption, and atomic recovery. Runtime gates capture and decode both tracks, kill and relaunch the process, preserve both byte-for-byte, open playback, and prove idempotence. Rotation, source loss, permission revocation, application selection, and long-session synchronization remain unproved.

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
| Prepared session schema | `open-scribe-store` schema v2 + ADR 0006 | SQLite projection, journal, recovery classification |
| Live and library presentation state | `open-scribe-store` SQLite projection | coarse UniFFI snapshot, main window, menu bar |
| Evidence/export schema | future versioned Rust schema | exports and runtime views |
| Legal text | `docs/legal/*` | app and website rendering |
| Capability claims | future checked manifest | UI, website copy, release notes |
| Model metadata | future `docs/models` manifest | model manager, notices, website |

## Boundaries

- Media hot paths stay outside UniFFI callbacks.
- Shared crates cannot depend on native crates, I/O, SQLite, Apple APIs, network clients, or model runtimes.
- SQLite/filesystem state is authority.
- Remote providers receive only per-category authorization and never execute tools.

## Architecture decisions

ADRs 0001–0004 settle M0. ADRs 0005–0007 admit M1 implementation; preparation, one-track microphone evidence, ordinary segment sealing, typed interruption state, forced-process recovery, persistent recovered playback, and short real-device runs are proven. ADRs 0008–0017 cover later milestones. Reliable required-source recording remains open; Cloudflare deployment is unauthorized. See `docs/architecture/README.md`.

## Current validation

`--scaffold` checks structure/WASM; `--state-fixtures` checks the Rust-owned snapshot, fresh bindings, native tests, and idle launch. M1 gates cover preparation through sealing; `--m1-dual-source-runtime` proves real dual-source `Recording`, while `--m1-forced-termination-recovery-proof` proves external-kill recovery and playback. None proves source loss, active revocation, two-hour operation, signing, distribution, deployment, or release.
