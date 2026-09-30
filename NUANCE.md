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

### APFS emergency space must be releasable at actual ENOSPC

On September 29, a 128 MiB volume passed reserve truncation, but the native
1.5 GiB full-volume harness failed: even truncating the owned reserve to zero
returned `ENOSPC`. Unlinking and closing that same validated allocation allowed
a subsequent write and fsync. The expanded ignored store regression reproduced
the truncation failure and passed with unlink-before-journal; exact commands
and logs are in `docs/TESTING.md`. A small passing volume does not qualify the
native exhaustion gate, and recovery after freeing filler cannot prove that
the original failure was journaled while full.
After unlink/close/fsync, replacement-file creation also intermittently returned
ENOSPC. Only that create-new operation has a bounded 250 ms retry; journal writes,
renames, projections, persistent exhaustion, and unrelated errors are not replayed.

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

### Unprivileged macOS logs no sandbox network denials

On September 29, `sandbox-exec` with `(deny network-outbound (remote ip))` made
`curl https://1.1.1.1` fail, yet `log show` found no denial. Allow rules
`(with report)` logged nothing either, and deny rules reject the modifier. A
first local-only run went RED because `log show --style compact` echoes its
filter predicate as a header line, which matched the search text. Bound
attempted connections with in-process socket samples and symbol and source
checks (`script/check_m4_local_only.sh`), never with a log search for denials.
