# Open Scribe

Open Scribe is a greenfield, open-source macOS conversation instrument intended to record conversations reliably, preserve local evidence, and connect derived meeting memory back to its sources.

> **Repository status: founding scaffold plus Milestone 0 native proof.** A development-only SwiftUI shell renders coarse non-media Rust state through UniFFI. No website runtime, capture, persistence, transcription, OCR, context observation, provider, meeting-intelligence, deployment, signing, or release capability exists yet.

The founding product contract is `docs/product/FOUNDING_PRD.md`. Start with `NORTH_STAR.md`, `ANCHOR.md`, and `AGENTS.md` for the compact operating view.

## Intended architecture

- **SwiftUI/macOS:** native application scenes and Apple-platform adapters.
- **Rust:** durable state, evidence, recovery, persistence, transcription/diarization orchestration, provider policy, exports, and meeting memory.
- **UniFFI:** a deliberately coarse Swift/Rust control boundary.
- **Leptos/Cloudflare Workers:** a separate public website and explanatory demos.
- **WASM-safe Rust crates:** only deterministic types and semantics genuinely shared by the app and website.

## Repository map

`
apps/macos/                  M0 native SwiftUI/UniFFI development shell
crates/open-scribe-*/        Rust package boundaries and placeholders
web/                         reserved Leptos/Cloudflare website root
docs/                        product, architecture, legal, design, model, format, and release truth
script/                      fail-closed canonical entry points
.github/workflows/           scaffold-only CI
`

## What can be verified now

Run the founding structure gate:

```bash
./script/check.sh --scaffold
```

Run the bounded M0 native gate:

```bash
./script/check.sh --m0-native
```

This validates the founding scaffold, Rust status query, generated UniFFI consistency, Swift binding call, development app assembly, and local launch. It does **not** prove the website, capture, persistence, recovery, transcription, providers, ML, deployment, signing, notarization, or release.

All default product/release scripts intentionally fail until their corresponding implementation and proof exist.

## License

Repository-authored material is intended to use the MIT License. Dependency, model, asset, signing, and legal-text treatment remains subject to review. See `LICENSE` and `THIRD_PARTY_NOTICES.md`.
