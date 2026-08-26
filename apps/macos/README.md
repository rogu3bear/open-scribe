# macOS Application Root

**Status:** Milestone 0 native development shell plus bounded early-M1
microphone and segment-sealing foundations. The Xcode-owned unsigned app renders one Rust fixture in
its menu and compact window. A UI-unwired AVAudioEngine adapter uses a bounded
Swift buffer pool and serial managed CAF writer; synthetic-buffer tests produce
durable coarse first-sample evidence and closes one synthetic CAF into a coarse
seal receipt without asserting `Recording`. No live
permission prompt, device capture, or signed entitlement enforcement is proven.

This root will contain the native SwiftUI application, MenuBarExtra, Settings, accessibility, permission UX, and bounded Apple-framework adapters for AVFoundation/CoreAudio, ScreenCaptureKit, Vision, display/window overlays, Calendar, Contacts, Keychain, and optional Apple-only model integration.

Durable session policy, evidence, persistence, recovery, provider scope, and exports belong in Rust. Frame-rate media and pointer samples must not cross ordinary UniFFI callbacks.

ADR 0001 owns the M0 module boundary, macOS 13 floor, development bundle
identifier, no-entitlement posture, and binding lifecycle. ADR 0004 owns the
fixture state and presentation contract. ADR 0007 supersedes SwiftPM as the app
and test-host owner: `OpenScribe.xcodeproj` now builds the same checked Swift
sources and Rust static library. SwiftPM remains for code organization only.
The checked entitlement source and effective Xcode sandbox/Hardened Runtime
settings are implemented. UI wiring, live capture proof, distribution identity,
signing, notarization, and release remain unimplemented.

`./script/build_and_run.sh` builds the Xcode app into the ignored local Derived
Data root. Its default mode launches the app; `--verify` runs the Xcode test
host, binds the exact process, and observes primary/menu-bar/Settings scene logs;
`--debug`, `--logs`, and `--telemetry` provide LLDB or filtered unified-log
sessions. `./script/check_m1_xcode_fixture.sh` is the pre-capture UI checkpoint;
`./script/check.sh --m1-segment-sealing` includes all earlier gates plus the
synthetic first-sample path, close-before-seal round trip, Rust-computed digest,
and permissions/build metadata. It does not prove live capture, a permission
prompt, `Recording`, packet/playability validation, playable recovery, signed
entitlement enforcement, distribution, or public release.
