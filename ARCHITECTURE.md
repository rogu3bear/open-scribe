# Open Scribe Architecture

> **Budget:** 700 words. Current fact and intended design remain distinct.

## Current repository fact

Open Scribe has an M0 native/site foundation and bounded early-M1 microphone foundation, but no live capture proof or deployment. Rust owns durable preparation, managed-media validation, and one-shot first-sample evidence; only coarse data crosses UniFFI. Swift has a UI-unwired AVAudioEngine adapter, bounded buffer pool, serial CAF writer, permission mapping, and entitlement source. Synthetic-buffer tests never assert `Recording`. Playable recovery, ML, context, providers, signing, deployment, and release remain unimplemented.

## Intended runtime shape

The Apple-Silicon app uses SwiftUI and narrow Apple adapters. Rust owns durable state and policy; coarse UniFFI connects them. A separate Leptos site targets Cloudflare Workers. Only platform-neutral semantics enter WASM-safe crates; the app never requires the site.

## Intended ownership

| Component | Status | Owns | Must not own |
|---|---|---|---|
| `apps/macos` | fixture shell + microphone foundation | SwiftUI, Apple adapters, bounded buffers, CAF writer, permission UX | durable policy, capture claims, evidence truth |
| `crates/open-scribe-types` | implemented, WASM-safe | stable session/source/condition records | I/O or native APIs |
| `open-scribe-domain` | implemented, WASM-safe | transitions and presentation | persistence or capture |
| `open-scribe-evidence` | placeholder, WASM-safe | evidence IDs and validation semantics | model execution or native storage |
| `open-scribe-store` | bounded preparation | session intent, journal, SQLite, media/first-sample receipts | buffers, capture, UI state |
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

Durable preparation and the create-new CAF handshake are tested. A synthetic PCM buffer can traverse the bounded Swift writer and produce durable first-sample evidence. The adapter is not UI-wired or live-device-proven, and step 4 remains impossible.

### Derived meeting memory

1. Evidence enters Rust through bounded typed interfaces.
2. A provider may propose a structured delta but cannot write storage.
3. Rust validates status, scope, provenance, and references.
4. Interpretation stays distinct from evidence and supports adjudication.

This is unimplemented.

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

- Media/frame hot paths stay outside ordinary UniFFI callbacks.
- Shared crates cannot depend on native crates, I/O, SQLite, Apple APIs, network clients, or model runtimes.
- SQLite/filesystem state is authority; UI caches are derived.
- Remote providers receive only per-category authorization and never execute tools.
- Website and Cloudflare state prove nothing about native app behavior.

## Architecture decisions

ADRs 0001–0004 settle M0. ADRs 0005–0007 admit only M1 preparation, media-open, and bounded first-sample prerequisites. ADRs 0008–0017 cover later milestones. Live capture remains open; Cloudflare deployment is unauthorized. See `docs/architecture/README.md`.

## Current validation

`--scaffold` checks structure/WASM; `--m0-native` checks the app; `build_web.sh` checks SSR/Worker artifacts and hashes. `--state-fixtures` checks transitions/surfaces. `--m1-storage` adds durable preparation; `--m1-media-open` adds a CAF receipt; `--m1-microphone-foundation` adds the bounded Swift adapter, synthetic first-sample path, permissions metadata, and unsigned build settings. None proves live capture, `Recording`, forced-process/playable recovery, signed entitlements, deployment, signing, distribution, or release.
