# macOS Application Root

**Status:** Milestone 0 native development shell implemented. It contains a
SwiftPM SwiftUI executable, an assembled unsigned development app, and generated
UniFFI bindings for one truthful non-media Rust status query.

This root will contain the native SwiftUI application, MenuBarExtra, Settings, accessibility, permission UX, and bounded Apple-framework adapters for AVFoundation/CoreAudio, ScreenCaptureKit, Vision, display/window overlays, Calendar, Contacts, Keychain, and optional Apple-only model integration.

Durable session policy, evidence, persistence, recovery, provider scope, and exports belong in Rust. Frame-rate media and pointer samples must not cross ordinary UniFFI callbacks.

ADR 0001 owns the M0-only project topology, module boundary, macOS 13 floor,
development bundle identifier, no-entitlement posture, binding lifecycle, and
focused test harness. Distribution identity, sandbox/entitlements, signing team,
universal packaging, and later capability boundaries remain unresolved.

`./script/build_and_run.sh` assembles the unsigned development bundle under
`dist/Open Scribe.app`. Its default mode launches the app; `--verify` binds the
exact process and primary/menu-bar scene logs; `--debug`, `--logs`, and
`--telemetry` provide LLDB or filtered unified-log sessions.
