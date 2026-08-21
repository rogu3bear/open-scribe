# ADR 0005 — Capture Ownership, Media Segments, and Session Timeline

- Status: Accepted for Milestone 1 implementation
- Date: 2026-08-20
- Owner/approver: repository operator, through the explicit Milestone 1 reliable-recorder instruction
- Founding clauses refined: PRD 2.1–2.6, 7, 9.2, 11, 21.2–21.4, 31 Milestone 1, 33.1, and 39
- Supersedes: ADR 0004 only where fixtures stand in for capture evidence; fixture semantics remain the reference state matrix

## Context and evidence

Milestone 1 requires simultaneous microphone and selected application/system audio, source separation, two-hour synchronization, pause/resume, source changes, and forced-termination recovery. Swift owns Apple capture adapters; Rust owns durable lifecycle and recovery policy. Ordinary UniFFI cannot carry real-time media or 15 Hz meter samples.

ScreenCaptureKit delivers selected application/system audio as `CMSampleBuffer` values and supports live filter/configuration updates. Its macOS 15 sample can also deliver microphone output, but Open Scribe retains macOS 13 support. AVAudioEngine supplies microphone buffers on that floor. Apple documents that unavailable input can throw or fail if the input format has zero sample rate/channels, so readiness must validate the hardware format.

## Decision

### Ownership and hot path

- Swift owns `MicrophoneCaptureAdapter` using AVAudioEngine and `SystemAudioCaptureAdapter` using ScreenCaptureKit.
- Each adapter writes directly to a dedicated serial media-writer queue. Audio buffers never cross UniFFI.
- Rust owns session/source IDs, requested scope, lifecycle, health, segment ledger, markers, recovery requirements, and the decision that Recording evidence is sufficient.
- Swift sends only coarse events: adapter prepared, file opened, first valid sample, segment sealed, source changed/failed/restored, meter summary, pause/resume boundary, and stop/finalize result.
- Swift owns ephemeral meters: RMS/peak are calculated on capture queues, reduced to 15 Hz UI values, exposed to accessibility at 2 Hz, and discarded. They never enter Rust, SQLite, recovery journals, or ordinary UniFFI.

### Tracks and containers

- Capture one source track per selected source: microphone mono when hardware provides mono, and application/system audio in its delivered channel layout. Never route captured system audio to output.
- Normalize the session processing timebase to 48 kHz. Preserve the adapter’s original format in segment metadata and perform bounded conversion on the writer queue before file write; capture callbacks never wait on Rust, SQLite, mixdown, UI, or ML.
- Write lossless linear PCM CAF source segments. CAF is the authoritative recoverable source; final mixdown is derived.
- Seal segments every 30 seconds and at pause, route/source change, permission loss, stop, sleep, or format change. The active segment is independently recoverable and never overwrites a sealed segment.
- A segment is accepted only after close, file synchronization, nonzero sane duration, readable header, and digest calculation. Retain all source segments until a mixdown is playable, duration-valid, and checksummed; user retention preferences apply only afterward.
- Create a stereo M4A/AAC mix for ordinary playback after source sealing. WAV is the initial lossless export. Mixdown failure never damages or hides source tracks.

### Timeline and synchronization

- Session time zero is a captured `mach_continuous_time`/host-time anchor recorded with its timebase conversion. Wall-clock time is metadata, never synchronization authority.
- Map ScreenCaptureKit presentation timestamps and AVAudioTime host times into signed session nanoseconds. Persist original timestamp, mapped start, sample count, rate, discontinuity flag, and measured drift for every segment.
- Pause creates a timeline boundary and stops captured-duration advancement. Resume opens new segments. The document timeline is contiguous captured time; source events retain both host time and captured-time position.
- Markers are Rust journal events containing session nanoseconds and creation wall time. UI acknowledges a marker only after the journal append is durable.
- Never silently stretch, drop, or duplicate audio to conceal drift. Measure drift at every segment boundary. A source exceeding 50 ms drift becomes degraded; 100 ms over two hours fails Milestone 1 acceptance.

### Source and failure behavior

- Stable source identity combines adapter kind with platform-stable identifiers where available; display names are mutable metadata, not identity.
- A format/device/source change seals the old segment and opens a new segment under the same logical source only when identity is continuous. Otherwise record source-ended/source-added events.
- If one source fails and another remains durable, lifecycle stays Recording with degraded health. If no source remains, Rust enters Interrupted and requires recovery/finalization.
- ScreenCaptureKit `userStopped` is an explicit user cancellation; other stream-stop errors are failures. Permission revocation never triggers silent retry or a claim that missing content continued.

## Alternatives

A single mixed recording loses topology and makes source failure unverifiable. Sending buffers through UniFFI creates frame-rate serialization and Rust/UI backpressure. One long file increases forced-termination exposure. Microphone-through-ScreenCaptureKit alone would raise the minimum OS. Recording compressed mixdown as sole authority weakens recovery and future export quality.

## Security and privacy

Capture begins only from an explicit command after permission/scope disclosure. Adapters receive only selected sources. No media enters logs, telemetry, SQLite, network, or providers. Meter values are process-memory-only and bounded.

## Migration and rollback

Container/timeline schema versions are persisted per session. A future container change creates new sessions with a new version; it never rewrites sealed source media in place. Rollback disables real capture and restores fixture-only controllers without deleting sessions. Existing sessions remain importable/read-only.

## Proof

Acceptance requires real two-hour microphone plus application/system recording with measured drift at most 100 ms; separate playable tracks and mix; pause/resume and marker inspection; microphone/system-source failure; permission revocation/restoration; device, route, format, app-exit, sleep/wake, and source-change runs; disk-pressure runs; and queue/backpressure telemetry showing media writers remain independent of Rust, UI, meters, playback, and ML. Unit tests alone cannot accept this ADR.

## Primary references

- Apple, “Capturing screen content in macOS”: https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos
- Apple, `AVAudioEngine.inputNode`: https://developer.apple.com/documentation/avfaudio/avaudioengine/inputnode
- Apple, `SCStreamDelegate`: https://developer.apple.com/documentation/screencapturekit/scstreamdelegate
- Apple, `AVAudioFile`: https://developer.apple.com/documentation/avfaudio/avaudiofile
