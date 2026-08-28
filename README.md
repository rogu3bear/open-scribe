# Open Scribe

Open Scribe is a greenfield, open-source macOS conversation instrument intended to record conversations reliably, preserve local evidence, and connect derived meeting memory back to its sources.

> **Repository status: Milestone 0 development proof plus bounded early-M1 microphone recovery and required-source authority.** Rust durably declares the sources required for a session and enters `Recording` only after each has open managed media and first-sample evidence. The Swift microphone path uses that authority; forced-exit recovery remains byte preserving and playable. This does not prove ScreenCaptureKit system audio, real simultaneous multi-source capture, source-loss handling, two-hour operation, transcription, signing, distribution, or public release.

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

Verify the current real-device microphone behavior explicitly; this requests
microphone access, captures temporary audio, checks that the CAF is playable,
and deletes the proof media:

```bash
./script/check.sh --m1-live-microphone
```

Run `./script/check.sh --m1-interruption-state` separately for the internal
journal, binding, failure-path, and media-preservation regression chain. That
repository gate supports the recorder; it is not the runtime proof. Run
`./script/check.sh --m1-forced-termination-recovery` for the exact real-device
capture, external-kill, relaunch, recovery, persistent playback, and independent
decode receipt. None proves system audio, multi-source `Recording`, source-loss
handling, two-hour operation, transcription, signed entitlement enforcement,
deployment, notarization, distribution, or public release.

GitHub Actions is intentionally disabled for this repository. Pull requests are admitted through exact-checkout local receipts, an independent review of the candidate tree, and explicit merge readback; no hosted status check is a proof authority.

All default product/release scripts intentionally fail until their corresponding implementation and proof exist.

## License

Repository-authored material is intended to use the MIT License. Dependency, model, asset, signing, and legal-text treatment remains subject to review. See `LICENSE` and `THIRD_PARTY_NOTICES.md`.
