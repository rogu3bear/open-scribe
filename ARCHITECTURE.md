# Open Scribe Architecture

> **Budget:** 700 words. Current fact and intended design remain distinct.

## Current repository fact

Open Scribe has an M0 native/site foundation and bounded early-M1 session preparation, but no capture runtime or deployment. Rust owns fixtures, durable journal/SQLite preparation, and managed media-open validation; coarse data crosses UniFFI. One Swift store drives both fixture surfaces. A test adapter opens Rust-authorized CAF files without asserting `Recording`. The Leptos build produces useful stateless SSR. Capture, playable recovery, ML, context, providers, signing, deployment, and release remain unimplemented.

## Intended runtime shape

The Apple-Silicon app uses SwiftUI and narrow Apple adapters. Rust owns durable state and policy; coarse UniFFI connects them. A separate Leptos SSR/hydration site targets Cloudflare Workers. Only platform-neutral semantics enter WASM-safe crates, and the app never requires the site.

## Intended ownership

| Component | Status | Owns | Must not own |
|---|---|---|---|
| `apps/macos` | fixture shell + media-open adapter | SwiftUI, fixture store, create-new CAF handling | durable policy, capture claims, evidence truth |
| `crates/open-scribe-types` | implemented, WASM-safe | stable session/source/condition records | I/O or native APIs |
| `open-scribe-domain` | implemented, WASM-safe | transitions and presentation | persistence or capture |
| `open-scribe-evidence` | placeholder, WASM-safe | evidence IDs, relationships, claim-validation semantics | model execution or native storage |
| `open-scribe-store` | bounded preparation | session intent, journal, SQLite, media authorization/receipt | buffers, capture, UI state |
| other native Rust crates | placeholders | later ML and memory | Apple UI or permission UX |
| `open-scribe-uniffi` | coarse boundary | fixtures, preparation, media-open receipts | state authority or hot-path data |
| `web` | M0 foundation | stateless Leptos SSR | capture, app backend, database, deployment authority |
| `docs/legal` | present drafts | single legal-text source for future app/site consumers | duplicated edited copies |

## Intended critical flows

### Capture and recovery

1. User explicitly requests capture through Swift UI.
2. Swift platform adapters establish sources and durable media/journal prerequisites.
3. Rust validates the coarse transition and records lifecycle/source metadata.
4. Only then may UI report Recording.
5. Media remains recoverable independently of transcript or ML.

Durable preparation and the create-new CAF handshake are tested. No captured sample enters the file, and step 4 remains impossible.

### Derived meeting memory

1. Evidence events enter Rust through bounded typed interfaces.
2. A provider may propose a structured delta but cannot write storage.
3. Rust validates status, scope, provenance, and evidence references.
4. Interpretation stays distinct from evidence and supports adjudication.

This flow is unimplemented and unproven.

## Sources of truth

| Concern | Canonical owner | Derived consumers |
|---|---|---|
| Founding product/architecture | `docs/product/FOUNDING_PRD.md` | north star, anchors, architecture, ADRs |
| Session fixture schema | `open-scribe-types` + ADR 0004 | domain snapshots, UniFFI, Swift fixture views |
| Prepared session schema | `open-scribe-store` schema v2 + ADR 0006 | SQLite projection, journal, recovery classification |
| Evidence/export schema | future versioned Rust schema | exports and runtime views |
| Legal text | `docs/legal/*` | app and website rendering |
| Capability claims | future checked manifest | UI, website copy, release notes |
| Model metadata/licenses | future `docs/models` manifest | model manager, notices, website |

## Boundaries

- Media/frame hot paths stay outside ordinary UniFFI callbacks.
- Shared crates cannot depend on native crates, I/O, SQLite, Apple APIs, network clients, or model runtimes.
- SQLite/filesystem state is local authority; UI caches and summaries are derived.
- Remote providers receive only per-category authorization and never execute tools.
- Website and Cloudflare state prove nothing about native app behavior.

## Open architecture decisions

ADRs 0001–0004 settle M0. ADRs 0005–0007 admit M1; only preparation/media-open prerequisites exist. ADRs 0008–0010 cover M2, 0011–0012 M3, 0013–0014 M4, and 0015–0017 M5. Capture and later proof remain open; Cloudflare deployment is unauthorized. See `docs/architecture/README.md`.

## Current validation

`--scaffold` checks structure/WASM; `--m0-native` checks the app plane; `build_web.sh` checks SSR/Worker artifacts and content hashes. `--state-fixtures` checks transitions, UniFFI, Swift surfaces, accessibility truth, and launch. `--m1-storage` adds durable preparation/recovery classification; `--m1-media-open` adds a create-new CAF and validated receipt. None proves capture, `Recording`, forced-process/playable recovery, deployment, signing, distribution, or release.
