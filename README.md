# Open Scribe

Open Scribe is a greenfield, open-source macOS conversation instrument intended to record conversations reliably, preserve local evidence, and connect derived meeting memory back to its sources.

> **Repository status: Milestone 0 development proof plus bounded M1 dual-source runtime proof.** Rust durably declares required sources, enters `Recording` only after microphone and all-authorized system audio both have open media and first-sample evidence, and recovers the two tracks atomically after forced termination. An exact unsigned arm64 app has captured, sealed, independently decoded, and recovered both real source tracks, then opened the recovered conversation in native playback. This does not prove source-loss continuation, permission revocation during capture, application-scoped selection, two-hour synchronization, transcription, signing, distribution, or public release.

The founding product contract is `docs/product/FOUNDING_PRD.md`. Start with `NORTH_STAR.md`, `ANCHOR.md`, and `AGENTS.md` for the compact operating view.

## Intended architecture

- **SwiftUI/macOS:** native application scenes and Apple-platform adapters.
- **Rust:** durable state, evidence, recovery, persistence, transcription/diarization orchestration, provider policy, exports, and meeting memory.
- **UniFFI:** a deliberately coarse Swift/Rust control boundary.
- **Leptos/Cloudflare Workers:** a separate public website and explanatory demos.
- **WASM-safe Rust crates:** only deterministic types and semantics genuinely shared by the app and website.

## Repository map

`
apps/macos/                  Xcode-owned shell plus bounded microphone/system-audio source candidate
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

Verify current real-device microphone plus all-authorized system-audio behavior
explicitly; this requests the required access, captures two temporary tracks,
checks that both CAFs are playable, and deletes the proof media:

```bash
./script/check.sh --m1-dual-source-runtime
```

Run `./script/check.sh --m1-interruption-state` separately for the internal
journal, binding, failure-path, and media-preservation regression chain. That
repository gate supports the recorder; it is not the runtime proof. Run
`./script/check.sh --m1-forced-termination-recovery` for the exact real-device
dual-source capture, external-kill, relaunch, atomic recovery, persistent playback,
and independent decode receipt. Neither proves source-loss handling, permission
revocation during capture, application-scoped selection, two-hour operation,
transcription, signed entitlement enforcement,
deployment, notarization, distribution, or public release.

GitHub Actions is intentionally disabled for this repository. Pull requests are admitted through exact-checkout local receipts, an independent review of the candidate tree, and explicit merge readback; no hosted status check is a proof authority.

All default product/release scripts intentionally fail until their corresponding implementation and proof exist.

## License

Repository-authored material is intended to use the MIT License. Dependency, model, asset, signing, and legal-text treatment remains subject to review. See `LICENSE` and `THIRD_PARTY_NOTICES.md`.
