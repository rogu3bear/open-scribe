# Open Scribe

Open Scribe is a greenfield, open-source macOS conversation instrument intended to record conversations reliably, preserve local evidence, and connect derived meeting memory back to its sources.

> **Repository status: Milestone 0 development proof plus bounded early-M1 microphone recovery.** A stateless Leptos Worker build produces useful SSR, and a development-only SwiftUI app renders coarse Rust state through UniFFI. Rust durably prepares one managed microphone track, validates first-sample evidence, seals ordinary stops, and recovers strictly validated unclosed PCM CAF media after process death. Swift wires a menu-bar control to AVAudioEngine, bounded buffers, a managed writer, native recovered-audio playback, permission UX, and interruption reporting. The exact local recovery gate captured real microphone audio, externally killed the app, relaunched, preserved identical media bytes, recovered `ready_for_review`, opened native playback, independently decoded the CAF, and converged without duplicating its receipt. This does not prove system audio, multi-source `Recording`, source-loss handling, two-hour operation, transcription, signing, distribution, or public release.

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
