# Open Scribe Architecture

> **Budget:** 700 words. Fact and intent remain distinct.

## Current repository fact

Open Scribe has M0 and early-M1 microphone recovery proof. Rust owns one-track evidence, interruption, CAF validation, journal-first recovery, and persistent `ready_for_review`; UniFFI stays coarse. Swift owns capture, permissions, recovered-session UI, and playback. A local gate externally killed capture and proved byte-preserving relaunch recovery plus independent decode. System audio, `Recording`, long sessions, ML, signing, deployment, and release remain unimplemented.

## Intended runtime shape

The SwiftUI app uses narrow Apple adapters. Rust owns durable state; coarse UniFFI connects them. A separate Leptos site targets Workers. Only platform-neutral semantics enter WASM-safe crates.

## Intended ownership

| Component | Status | Owns | Must not own |
|---|---|---|---|
| `apps/macos` | fixture shell + live microphone slice | SwiftUI, Apple adapters, bounded buffers, CAF writer, permission UX | durable policy, capture claims, evidence truth |
| `crates/open-scribe-types` | implemented, WASM-safe | stable session/source/condition records | I/O or native APIs |
| `open-scribe-domain` | implemented, WASM-safe | transitions and presentation | persistence or capture |
| `open-scribe-evidence` | placeholder, WASM-safe | evidence IDs and validation semantics | model execution or native storage |
| `open-scribe-store` | bounded microphone recovery | session intent, journal, SQLite, media/first-sample/seal/interruption/recovery receipts | buffers, capture, UI state |
| other native Rust crates | placeholders | later ML and memory | Apple UI or permission UX |
| `open-scribe-uniffi` | coarse boundary | fixtures, preparation, one-shot media receipts | state authority or hot-path data |
| `web` | M0 foundation | stateless Leptos SSR | capture, app backend, database, deployment authority |
| `docs/legal` | present drafts | single legal-text source for future app/site consumers | duplicated edited copies |

## Intended critical flows

### Capture and recovery

1. User explicitly requests capture through Swift UI.
2. Swift platform adapters establish sources and durable media/journal prerequisites.
3. Rust validates the coarse transition and records lifecycle/source metadata.
4. Only then may UI report Recording.
5. Media remains recoverable independently of transcript or ML.

Tests cover preparation, CAF creation, first sample, sealing, journal-first interruption, strict recovery parsing, and projection repair. The runtime gate externally kills the app after durable microphone media, relaunches it, preserves the unclosed CAF, projects `ready_for_review`, opens native playback, independently decodes it, and proves idempotent discovery. Required-source planning, system audio, `Recording`, rotation, source loss, and long-session synchronization remain unproved.

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

`--scaffold` checks structure/WASM; `--m0-native` checks the app; `build_web.sh` checks web artifacts. M1 gates cover preparation through sealing; `--m1-interruption-state` adds durable interruption classification, `--m1-live-microphone` proves ordinary real-device capture/seal, and `--m1-forced-termination-recovery` proves external-kill recovery and native playback. None proves `Recording`, system audio, source-loss handling, two-hour operation, signing, distribution, deployment, or public release.
