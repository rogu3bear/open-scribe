# Open Scribe

Open Scribe is a greenfield, open-source macOS conversation instrument intended to record conversations reliably, preserve local evidence, and connect derived meeting memory back to its sources.

> **Repository status: Milestone 0 development proof; M1 remains incomplete.** Current source gives Rust ownership of required-source decisions, lifecycle, shared capture timing, recovery, and the coarse live-and-library snapshot consumed by the native window and menu bar. [Dated runtime evidence](docs/TESTING.md#foundational-recording-workflow) records synthetic and short live dual-source capture, segment rotation, forced termination, unchanged recovered media, and shared native playback on an exact unsigned artifact. Those historical receipts do not qualify a new candidate or prove source-loss continuation, permission revocation, application-scoped selection, two-hour synchronization, transcription, signing, distribution, or public release. Transcript review, search, export, and two-phase deletion exist in source with Rust and Swift tests; no speech engine is integrated, so no transcript is produced.

The [founding product contract](docs/product/FOUNDING_PRD.md) owns intent. Start with [AGENTS.md](AGENTS.md) for task routing, [ANCHOR.md](ANCHOR.md) for invariants, and [NORTH_STAR.md](NORTH_STAR.md) for purpose.

## Intended architecture

- **SwiftUI/macOS:** native application scenes and Apple-platform adapters.
- **Rust:** durable state, evidence, recovery, persistence, transcription/diarization orchestration, provider policy, exports, and meeting memory.
- **UniFFI:** a deliberately coarse Swift/Rust control boundary.
- **Leptos/Cloudflare Workers:** a separate public website and explanatory demos.
- **WASM-safe Rust crates:** only deterministic types and semantics genuinely shared by the app and website.

## Repository map

```text
apps/macos/                  Native recorder/library shell plus bounded Apple capture adapters
crates/open-scribe-*/        shared semantics plus native preparation/media integrity evidence
web/                         stateless Leptos Worker/Assets development foundation
docs/                        product, architecture, legal, design, model, format, and release truth
script/                      fail-closed canonical entry points
```

## What can be verified now

Run the founding structure gate:

```bash
./script/check.sh --scaffold
```

Build and qualify one clean, committed contributor candidate (choose a measured
Disk Guard allowance as described in [Contributing](CONTRIBUTING.md)):

```bash
candidate="$PWD/apps/macos/.build/candidates/$(git rev-parse HEAD)/candidate.json"
disk-guard run --budget-gb <measured> --volume "$PWD" -- ./script/check.sh --candidate "$candidate"
./script/check.sh --verify-recording --candidate "$candidate"
```

The first command builds one unsigned app and test bundle, runs source and web
checks, all native tests, and synthetic recovery. The second reruns recorder
components with `test-without-building` against the recorded artifact. All
consumers reject source or artifact drift. The foundational workflow
has [dated proof](docs/TESTING.md#foundational-recording-workflow): a device-free
synthetic process proof (two sources, a Rust-owned shared timeline, 30-second
segments, forced termination, unchanged recovered media) whose receipt names
its exact tip, and one short live run with shared native playback on the
September 25 artifact, which predates pause/resume and the review repairs. It
does not close M1.
`./script/check.sh --m1-complete` names remaining implementation and runtime
gates, including pause/resume, markers, mixdown, storage-pressure policy,
application selection, channel-layout fidelity, and the two-hour device run.

Verify the Rust-owned live/library snapshot, fresh bindings, complete unsigned
native test suite, and exact idle app launch without requesting capture access:

```bash
./script/check.sh --state-fixtures
```

Verify real-device microphone plus all-authorized system-audio behavior
explicitly; this requests the required access, captures two temporary tracks,
checks each saved CAF segment against Rust's media evidence, and retains the
proof root for review. This gate and the forced-termination gate below last
passed on an older artifact. Their current segmented-capture source has not
passed on this candidate:

```bash
./script/check.sh --m1-dual-source-runtime --candidate "$candidate"
```

Run `./script/check.sh --m1-interruption-state` separately for the internal
journal, binding, failure-path, and media-preservation regression chain. That
repository gate supports the recorder; it is not the runtime proof. Run
`./script/check.sh --m1-forced-termination-recovery --candidate "$candidate"` for the exact real-device
dual-source capture, external-kill, relaunch, atomic recovery, persistent playback,
and independent decode receipt. Neither proves source-loss handling, permission
revocation during capture, application-scoped selection, two-hour operation,
transcription, signed entitlement enforcement,
deployment, notarization, distribution, or public release.

GitHub Actions is intentionally disabled for this repository. Pull requests are admitted through exact-checkout local receipts, an independent review of the candidate tree, and explicit merge readback; no hosted status check is a proof authority.

All default product/release scripts intentionally fail until their corresponding implementation and proof exist.

## License

Repository-authored material is intended to use the MIT License. Dependency, model, asset, signing, and legal-text treatment remains subject to review. See `LICENSE` and `THIRD_PARTY_NOTICES.md`.
