# Open Scribe

Open Scribe is a greenfield, open-source macOS conversation instrument intended to record conversations reliably, preserve local evidence, and connect derived meeting memory back to its sources.

> **Repository status: Milestone 0 development proof plus a bounded early-M1 live-microphone slice.** A stateless Leptos Worker build produces useful SSR, and a development-only SwiftUI app renders coarse Rust state through UniFFI. Rust durably prepares a session, validates one managed track and first-sample evidence, and independently digests a closed CAF segment. Swift wires a menu-bar control to AVAudioEngine, bounded buffers, a managed writer, and permission UX. One explicit local gate captured, sealed, and validated a short playable microphone CAF. This does not prove system audio, multi-source `Recording`, playable forced-termination recovery, transcription, signing, distribution, or public release.

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

This validates the deterministic foundations plus a managed CAF writer, bounded Swift buffer path, durable coarse first-sample receipt, close-before-seal behavior, exact file identity/length/header validation, Rust-computed SHA-256, permission-state mapping, least-privilege entitlement source, and unsigned Xcode build settings. Run `./script/check.sh --m1-live-microphone` explicitly for the separate real-device microphone and playable-CAF proof. Neither gate proves system audio, multi-source `Recording`, forced-termination recovery, transcription, signed entitlement enforcement, deployment, notarization, distribution, or public release.

GitHub Actions is intentionally disabled for this repository. Pull requests are admitted through exact-checkout local receipts, an independent review of the candidate tree, and explicit merge readback; no hosted status check is a proof authority.

All default product/release scripts intentionally fail until their corresponding implementation and proof exist.

## License

Repository-authored material is intended to use the MIT License. Dependency, model, asset, signing, and legal-text treatment remains subject to review. See `LICENSE` and `THIRD_PARTY_NOTICES.md`.
