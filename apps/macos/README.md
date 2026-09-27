# macOS Application Root

**Status:** Milestone 0 native development shell plus bounded early-M1
live-microphone and forced-termination recovery slices. The Xcode-owned unsigned app renders Rust fixture state
and exposes a deliberate menu-bar microphone control. AVAudioEngine uses a
bounded Swift buffer pool and serial managed CAF writer; the controller obtains
coarse durable preparation, media-open, first-sample, close-before-seal, and
typed interruption evidence without asserting `Recording`. One explicit local
run proved a short ordinary capture, while a separate external-kill run proved
byte-preserving relaunch recovery, persistent `ready_for_review` discovery,
native playback open, and independent CAF decode. System audio, multi-source
authority, source-loss handling, long sessions, and signed entitlement
enforcement remain unproved.

This root will contain the native SwiftUI application, MenuBarExtra, Settings, accessibility, permission UX, and bounded Apple-framework adapters for AVFoundation/CoreAudio, ScreenCaptureKit, Vision, display/window overlays, Calendar, Contacts, Keychain, and optional Apple-only model integration.

Durable session policy, evidence, persistence, recovery, provider scope, and exports belong in Rust. Frame-rate media and pointer samples must not cross ordinary UniFFI callbacks.

## Local audio import

Import copies user-selected audio into the conversation library without changing
the original or starting transcription. PCM CAF remains limited to 256 MiB.
M4A AAC/Apple Lossless imports have a 1 GiB source limit and a four-hour duration
limit. Compressed preservation supports a single audio track at 48 kHz with one
or two channels; small mono M4A at other rates uses the existing bounded 48 kHz
CAF normalization path. Unsupported layouts, rates, formats, or policy excesses
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
settings, menu wiring, and short microphone proof are implemented. Production
distribution identity, signing, notarization, and release remain unimplemented.

`./script/build_and_run.sh` builds the Xcode app into the ignored local Derived
Data root. Its default mode launches the app; `--verify` runs the Xcode test
host, binds the exact process, and observes primary/menu-bar/Settings scene logs;
`--debug`, `--logs`, and `--telemetry` provide LLDB or filtered unified-log
sessions. `./script/check_m1_xcode_fixture.sh` is the pre-capture UI checkpoint;
`./script/check.sh --m1-live-microphone` is the current experiential proof: it
requires explicit consent and proves a short real-device capture through a
playable CAF, then deletes its proof media. `--m1-interruption-state` is the
supporting repository regression for first sample, sealing, typed interruption,
and restart classification; it does not replace live audio proof.
`--m1-forced-termination-recovery` performs a real microphone capture, external
kill, relaunch recovery, native playback open, and independent decode. None
proves system audio, multi-source `Recording`, source-loss behavior, long
sessions, signing, or release.
