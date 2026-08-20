# Open Scribe Architecture

> **Budget:** 700 words. Current repository fact and intended-but-unbuilt design are separated explicitly.

## Current repository fact

Open Scribe has a Milestone 0 native development shell and no product capability runtime. The repository contains founding doctrine, documentation, a Cargo workspace, a SwiftPM macOS app with primary window, MenuBarExtra, and Settings, and a coarse UniFFI query returning truthful non-media capability state. Capture, persistence, transcription, context, providers, ML, website runtime, signing, and release remain unimplemented.

## Intended runtime shape

A native Apple-Silicon macOS application will use SwiftUI and narrow Apple-framework adapters. Rust will own durable product state and deterministic policy. A coarse UniFFI control bridge will connect them. A separate Leptos SSR/hydration site will run on Cloudflare Workers. Only genuinely platform-neutral semantics will be shared through WASM-safe Rust crates; the website will never be required for app operation.

## Intended ownership

| Component | Status | Owns | Must not own |
|---|---|---|---|
| `apps/macos` | M0 shell | SwiftUI scenes, MenuBarExtra, Settings; later Apple adapters | durable product policy or evidence truth |
| `crates/open-scribe-types` | placeholder, WASM-safe | stable cross-boundary value types | I/O or native APIs |
| `open-scribe-domain` | placeholder, WASM-safe | deterministic session states and transitions | persistence or platform capture |
| `open-scribe-evidence` | placeholder, WASM-safe | evidence IDs, relationships, claim-validation semantics | model execution or native storage |
| native Rust crates | placeholders | store, ASR, diarization, memory, models, orchestration | Apple UI or direct permission UX |
| `open-scribe-uniffi` | M0 proof | adapt one Rust-core status snapshot into a coarse non-media query; later control/query boundary | product-state authority or frame-rate audio, video, or pointer serialization |
| `web` | reserved | public Leptos site and explanatory demo | native capture or app backend |
| `docs/legal` | present drafts | single legal-text source for future app/site consumers | duplicated edited copies |

## Intended critical flows

### Capture and recovery

1. User explicitly requests capture through Swift UI.
2. Swift platform adapters establish sources and durable media/journal prerequisites.
3. Rust validates the coarse transition and records lifecycle/source metadata.
4. Only then may UI report Recording.
5. Media remains recoverable independently of transcript or ML.

This flow is unimplemented and unproven.

### Derived meeting memory

1. Evidence events enter Rust through bounded typed interfaces.
2. A provider may propose a structured delta but cannot write storage.
3. Rust validates status, scope, provenance, and evidence references.
4. Accepted interpretation remains distinct from evidence and supports adjudication.

This flow is unimplemented and unproven.

## Sources of truth

| Concern | Canonical owner | Derived consumers |
|---|---|---|
| Founding product/architecture | `docs/product/FOUNDING_PRD.md` | north star, anchors, architecture, ADRs |
| Session/evidence schema | future versioned Rust schema | SQLite, Swift views, exports, web demo fixtures |
| Legal text | `docs/legal/*` | app and website rendering |
| Capability claims | future checked manifest | UI, website copy, release notes |
| Model metadata/licenses | future `docs/models` manifest | model manager, notices, website |

## Boundaries

- Media/frame hot paths stay outside ordinary UniFFI callbacks.
- Shared crates cannot depend on native crates, filesystem, SQLite, Apple frameworks, network clients, or model runtimes.
- SQLite/filesystem state is local authority; UI caches and summaries are derived.
- Remote providers receive only per-category authorization and never execute tools.
- Website and Cloudflare state prove nothing about native app behavior.

## Open architecture decisions

ADR 0001 settles the M0 development topology and binding proof only. Exact Rust toolchain pin, template import revision, distribution packaging and bundle identity, sandbox/entitlement strategy, minimum-macOS fallback policy beyond the M0 floor, SQLite/event schema, capture containers/segmentation, ASR and diarization engines, Sparkle integration, and signing identity remain unresolved. Required ADRs are tracked in `docs/architecture/README.md`.

## Current validation

`./script/check.sh --scaffold` validates founding structure only. `./script/check.sh --m0-native` validates the focused Rust record, generated UniFFI consistency, Swift binding call, development app assembly, exact process launch, and primary/menu-bar/Settings scene logs. Neither proves capture, persistence, recovery, signing, distribution, or release.
