# Open Scribe Nuance

> **Budget:** 500 words plus compact proven entries.

Add an entry only when a likely recurring contradiction is proved by an exact command or inspection and does not belong in an anchor, architecture decision, or code comment.

### Cold web failure can mean an unloadable host proc macro

On September 29, an empty-target `cargo leptos build --release` failed with
`E0463: can't find crate for rustversion`. The dylib existed; direct `dlopen`
rejected it with `mis-aligned LINKEDIT string pool`. Rust 1.93.1 debuginfo
stripping and macOS 27's loader reproduce
[rust-lang/rust#157750](https://github.com/rust-lang/rust/issues/157750).
The workspace release build-override disables stripping for host build
dependencies; dependency versions and shipped-code optimization stay pinned.
Do not solve this by warming an unrelated cache or editing Cargo's registry.

### Writer generation advances on every rotation

The segmented CAF writer opens a new segment every 30 seconds, on a forward
host-time gap over 2 ms, and on an input-format change (a backward overlap over
2 ms is rejected instead), and each successor's `writerGeneration` increments. A
capture identity bound once at start (`MicrophoneCaptureIdentity(authorization:)`)
goes stale after the first rotation: a health observation or failure reported
with the start-time generation no longer matches the writer's current
authorization. Reproduced by
`RecorderPauseResumeTests.testRouteInterruptionAfterRotationDegradesMicrophoneCapture`
(route loss after one rotation must still degrade the microphone). The controller
matches observations against the full identity bound at capture start (its
generation included) plus a monotonic sequence, never against the current
segment's generation.
