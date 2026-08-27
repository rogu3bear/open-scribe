# macOS Application Root

**Status:** Milestone 0 native development shell plus a bounded early-M1
live-microphone slice. The Xcode-owned unsigned app renders Rust fixture state
and exposes a deliberate menu-bar microphone control. AVAudioEngine uses a
bounded Swift buffer pool and serial managed CAF writer; the controller obtains
coarse durable preparation, media-open, first-sample, and close-before-seal
evidence without asserting `Recording`. One explicit local run proved a short
real-device capture and playable CAF. System audio, multi-source authority,
forced-termination recovery, and signed entitlement enforcement remain unproved.

This root will contain the native SwiftUI application, MenuBarExtra, Settings, accessibility, permission UX, and bounded Apple-framework adapters for AVFoundation/CoreAudio, ScreenCaptureKit, Vision, display/window overlays, Calendar, Contacts, Keychain, and optional Apple-only model integration.

Durable session policy, evidence, persistence, recovery, provider scope, and exports belong in Rust. Frame-rate media and pointer samples must not cross ordinary UniFFI callbacks.

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
`./script/check.sh --m1-segment-sealing` covers the deterministic first-sample
and sealing chain. `./script/check.sh --m1-live-microphone` separately requires
explicit consent and proves a short real-device capture through playable CAF.
It deletes its proof media and does not prove system audio, multi-source
`Recording`, forced-termination recovery, long sessions, signing, or release.
