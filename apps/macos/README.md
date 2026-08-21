# macOS Application Root

**Status:** Milestone 0 native development shell plus deterministic post-M0
state fixtures implemented. An Xcode-owned unsigned development app now renders
one Rust-owned fixture snapshot through generated UniFFI bindings in both its
menu and compact window. A bounded test adapter creates a Rust-authorized CAF
file and returns coarse media-open evidence after durable session preparation;
it ingests no microphone or system sample and never asserts `Recording`.

This root will contain the native SwiftUI application, MenuBarExtra, Settings, accessibility, permission UX, and bounded Apple-framework adapters for AVFoundation/CoreAudio, ScreenCaptureKit, Vision, display/window overlays, Calendar, Contacts, Keychain, and optional Apple-only model integration.

Durable session policy, evidence, persistence, recovery, provider scope, and exports belong in Rust. Frame-rate media and pointer samples must not cross ordinary UniFFI callbacks.

ADR 0001 owns the M0 module boundary, macOS 13 floor, development bundle
identifier, no-entitlement posture, and binding lifecycle. ADR 0004 owns the
fixture state and presentation contract. ADR 0007 supersedes SwiftPM as the app
and test-host owner: `OpenScribe.xcodeproj` now builds the same checked Swift
sources and Rust static library. SwiftPM remains for code organization only.
Production entitlements, capture adapters, distribution identity, signing,
notarization, and release remain unimplemented.

`./script/build_and_run.sh` builds the Xcode app into the ignored local Derived
Data root. Its default mode launches the app; `--verify` runs the Xcode test
host, binds the exact process, and observes primary/menu-bar/Settings scene logs;
`--debug`, `--logs`, and `--telemetry` provide LLDB or filtered unified-log
sessions. `./script/check_m1_xcode_fixture.sh` is the pre-capture UI checkpoint;
`./script/check.sh --m1-media-open` adds durable preparation plus the test-only
CAF handshake. Neither proves capture, permission flows, `Recording`, playable
recovery, signing, distribution, or release.
