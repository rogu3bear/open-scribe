# Open Scribe

Open Scribe is a greenfield, open-source macOS conversation instrument intended to record conversations reliably, preserve local evidence, and connect derived meeting memory back to its sources.

> **Repository status: Milestone 0 development proof plus bounded early-M1 microphone and segment-sealing foundations.** A stateless Leptos Worker build produces useful SSR, and a development-only SwiftUI shell renders coarse Rust state through UniFFI. Rust durably prepares a session, records managed-media and one-shot first-sample evidence, and independently digests one closed synthetic CAF segment. Swift has a production-shaped but UI-unwired AVAudioEngine adapter, bounded writer path, close-before-seal receipt, permission-state mapping, and entitlement source. Synthetic-buffer tests do not prove live microphone/system capture, `Recording`, playable recovery, deployment, signing, distribution, or public release.

The founding product contract is `docs/product/FOUNDING_PRD.md`. Start with `NORTH_STAR.md`, `ANCHOR.md`, and `AGENTS.md` for the compact operating view.

## Intended architecture

- **SwiftUI/macOS:** native application scenes and Apple-platform adapters.
- **Rust:** durable state, evidence, recovery, persistence, transcription/diarization orchestration, provider policy, exports, and meeting memory.
- **UniFFI:** a deliberately coarse Swift/Rust control boundary.
- **Leptos/Cloudflare Workers:** a separate public website and explanatory demos.
- **WASM-safe Rust crates:** only deterministic types and semantics genuinely shared by the app and website.

## Repository map

`
apps/macos/                  Xcode-owned shell plus bounded microphone adapter foundation
crates/open-scribe-*/        shared semantics plus native preparation/media integrity evidence
web/                         stateless Leptos Worker/Assets development foundation
docs/                        product, architecture, legal, design, model, format, and release truth
script/                      fail-closed canonical entry points
.github/                     repository metadata; GitHub Actions is intentionally disabled
`

## What can be verified now

Run the founding structure gate:

```bash
./script/check.sh --scaffold
```

Run the complete bounded foundation gate:

```bash
./script/check.sh --m1-segment-sealing
```

This validates the preceding gates plus a managed CAF writer, bounded Swift buffer path, deterministic conversion, durable coarse first-sample receipt, close-before-seal behavior, exact file identity/length/header validation, Rust-computed SHA-256, segment-local projection, permission-state mapping, least-privilege entitlement source, and effective unsigned Xcode build settings. It does **not** prove a live permission prompt, live microphone or system-audio capture, signed entitlement enforcement, `Recording`, CAF packet/playability validation, real forced-termination recovery, deployment, signing, notarization, distribution, or public release.

GitHub Actions is intentionally disabled for this repository. Pull requests are admitted through exact-checkout local receipts, an independent review of the candidate tree, and explicit merge readback; no hosted status check is a proof authority.

All default product/release scripts intentionally fail until their corresponding implementation and proof exist.

## License

Repository-authored material is intended to use the MIT License. Dependency, model, asset, signing, and legal-text treatment remains subject to review. See `LICENSE` and `THIRD_PARTY_NOTICES.md`.
