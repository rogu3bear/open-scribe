# macOS Application Root

**Status:** Milestone 0 native development shell plus early-M1 recorder slices.
Current Xcode app source routes the microphone plus all authorized system
audio (or one selected application, not yet qualified) into Rust-journaled
30-second CAF segments, with pause/resume and recovered playback. Swift shows
`Recording` only after Rust confirms durable first samples from every required
source. Candidate evidence is bound to the exact source and artifact named in
its receipt; it does not qualify other builds. Dated real-device
runs proved short dual-source capture with multi-source `Recording`,
external-kill recovery with unchanged media, and native playback; they predate
pause/resume and the review repairs (see
[docs/TESTING.md](../../docs/TESTING.md)). Real source loss, permission
revocation, long sessions, and signed entitlement enforcement remain unproved.

This root will contain the native SwiftUI application, MenuBarExtra, Settings, accessibility, permission UX, and bounded Apple-framework adapters for AVFoundation/CoreAudio, ScreenCaptureKit, Vision, display/window overlays, Calendar, Contacts, Keychain, and optional Apple-only model integration.

Durable session policy, evidence, persistence, recovery, provider scope, and exports belong in Rust. Frame-rate media and pointer samples must not cross ordinary UniFFI callbacks.

## Offline policy documents

Settings → **Read Policies and Licenses…** presents the canonical privacy, terms,
security, MIT license and development notices without network access. Draft and
incomplete-review status stays visible. Missing bundled text is an error rather
than an empty document. Reading a document does not adopt it or qualify a release.

`ruby script/sync_policy_documents.rb` copies those five sources byte-for-byte
into `Sources/OpenScribeApp/Resources/Policies/` for Xcode and SwiftPM. These
copies are generated projections; edit the root/docs source, then synchronize.
The scaffold gate rejects drift, and native tests compare built resources with
canonical source text. Generated digests are compiled into the app; the reader
rejects substituted resources, so candidate executable identity also binds these
documents. See [support and recovery limits](../../SUPPORT.md).

## Local audio import

Import copies user-selected audio into the conversation library without changing
the original or starting transcription. PCM CAF may be four hours of stereo
16-bit 48 kHz audio. Files above 256 MiB play as verified chunks and are not
held in memory. M4A AAC/Apple Lossless imports have a 4 GiB source limit and
the same four-hour duration limit. Compressed preservation supports a single
audio track at 48 kHz with one or two channels; small mono M4A at other rates
uses the existing bounded 48 kHz CAF normalization path. Unsupported layouts,
rates, formats, or policy excesses
fail with a visible explanation. Capture must finish before import begins.

Swift probes the selected file and a private staged copy. Rust verifies the
staged digest, copies and synchronizes managed media, checks its exact bytes,
then journals and atomically publishes a Ready for Review session. Large M4A
playback retains an identity-bound descriptor and verifies 64 KiB chunks while
AudioToolbox decodes stereo buffers; it does not allocate a whole-file PCM or
anonymous playback snapshot. Library polling checks identity and length;
playback revalidates the full digest before opening a decoder. Original metadata
remains separate from the managed media contract. ADR 0007 owns the boundary;
this slice does not qualify its complete platform or M1 runtime matrix.

ADR 0001 owns the M0 module boundary, macOS 13 floor, development bundle
identifier, no-entitlement posture, and binding lifecycle. ADR 0004 owns the
fixture state and presentation contract. ADR 0007 supersedes SwiftPM as the app
and test-host owner: `OpenScribe.xcodeproj` now builds the same checked Swift
sources and Rust static library. SwiftPM remains for code organization only.
The checked entitlement source, effective Xcode sandbox/Hardened Runtime
settings, and menu wiring are implemented; the short microphone proof is dated
and predates segmented capture. Production distribution identity, signing,
notarization, and release remain unimplemented.

`./script/build_and_run.sh` builds the Xcode app into the ignored local Derived
Data root. Its default mode launches the app; `--verify` runs the Xcode test
host, binds the exact process, and observes primary/menu-bar/Settings scene logs;
`--debug`, `--logs`, and `--telemetry` provide LLDB or filtered unified-log
sessions. `./script/check_m1_xcode_fixture.sh` is the pre-capture UI checkpoint;
`./script/check.sh --m1-dual-source-runtime --candidate <absolute-record>` (alias `--m1-live-microphone`)
requires explicit consent and is designed to prove a short real-device
microphone plus system-audio capture through independently decoded and digested
CAF segments.
The current gate source retains its proof root, but has no receipt on this app.
`--m1-interruption-state` is the supporting repository regression for first
sample, sealing, typed interruption, and restart classification; it does not
replace live audio proof. `--m1-forced-termination-recovery` performs a real
dual-source capture, external kill, relaunch recovery, native playback open, and
independent decode. Both runtime gates last passed before segmented capture and
now accept multiple CAF segments, so they need requalification. None proves
source-loss behavior, long sessions, signing, or release.
