# Open Scribe

Open Scribe is a greenfield, open-source macOS conversation instrument intended to record conversations reliably, preserve local evidence, and connect derived meeting memory back to its sources.

> **Repository status: Milestone 0 development proof plus bounded early-M1 preparation.** A stateless Leptos Worker build produces useful SSR, and a development-only SwiftUI shell renders coarse Rust state through UniFFI. Rust can durably prepare a session journal and SQLite projection, authorize one managed CAF path, and validate Swift's create-new media-open receipt. There is no microphone/system capture, `Recording` assertion, playable recovery, transcription, OCR, context observation, provider, deployment, signing, distribution, or release capability.

The founding product contract is `docs/product/FOUNDING_PRD.md`. Start with `NORTH_STAR.md`, `ANCHOR.md`, and `AGENTS.md` for the compact operating view.

## Intended architecture

- **SwiftUI/macOS:** native application scenes and Apple-platform adapters.
- **Rust:** durable state, evidence, recovery, persistence, transcription/diarization orchestration, provider policy, exports, and meeting memory.
- **UniFFI:** a deliberately coarse Swift/Rust control boundary.
- **Leptos/Cloudflare Workers:** a separate public website and explanatory demos.
- **WASM-safe Rust crates:** only deterministic types and semantics genuinely shared by the app and website.

## Repository map

`
apps/macos/                  Xcode-owned M0 fixture shell and test-only CAF media-open adapter
crates/open-scribe-*/        shared semantics plus bounded native session preparation
web/                         stateless Leptos Worker/Assets development foundation
docs/                        product, architecture, legal, design, model, format, and release truth
script/                      fail-closed canonical entry points
.github/workflows/           bounded P1 foundation proof CI
`

## What can be verified now

Run the founding structure gate:

```bash
./script/check.sh --scaffold
```

Run the complete bounded foundation gate:

```bash
./script/check.sh --m1-media-open
```

This validates the founding scaffold, useful SSR and Worker artifacts, WASM-safe shared crates, generated UniFFI consistency, Xcode-owned fixture surfaces, durable session preparation, and the bounded create-new CAF media-open handshake. It does **not** prove microphone or system-audio capture, `Recording`, real forced-termination recovery, playable media, transcription, providers, ML, deployment, signing, notarization, distribution, or release.

All default product/release scripts intentionally fail until their corresponding implementation and proof exist.

## License

Repository-authored material is intended to use the MIT License. Dependency, model, asset, signing, and legal-text treatment remains subject to review. See `LICENSE` and `THIRD_PARTY_NOTICES.md`.
