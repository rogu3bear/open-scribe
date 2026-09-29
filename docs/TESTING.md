# Open Scribe Testing

## Test Strategy

Open Scribe tests the evidence chain in order: source/configuration, deterministic unit and integration behavior, build, installed/runtime behavior, recovery, signed artifact, and release. A lower plane never proves a higher one. `./script/check.sh --m1-live-microphone` proves ordinary real-device capture/seal/playability; `--m1-forced-termination-recovery` separately proves external-kill relaunch recovery and native playback. Both last passed before segmented capture and need requalification (see [CI Gates](#ci-gates)). `--m1-interruption-state` is a supporting repository-plane regression and cannot substitute for either runtime outcome. Each receipt proves only the inclusions and exclusions it names.

Characterization tests pin observed behavior before correction. Safety-critical invariants—durable media before capture claims, audio survival independent of transcription, required-source truth, and recovery—need tests at the layer that owns the claim plus runtime evidence on an exact artifact.

Repository and source tests currently cover managed local CAF and M4A (AAC/Apple Lossless) import, deterministic deduplication and rejection, imported-conversation projection, validated-byte playback leasing, and shared recovered/imported playback failures. One dated real-file receipt (September 27, commit `3e51b72`, `~/Documents/Codex/2026-09-27/open-scribe-large-import/RETURN.md`) imported an operator-selected 865 MB stereo 48 kHz Apple Lossless M4A through the normal workflow and passed a 41-test run covering reopen, first- and last-frame decode, silent player startup, and bounded memory. Those tests do not prove other real files or formats, audible or full-duration playback, long-running sessions, source-loss recovery, an installed or signed artifact, or public delivery.

### Recorder component check

`./script/build_and_run.sh --verify-recording` rebuilds Rust, verifies generated
bindings, builds the unsigned Xcode app, and runs the microphone, system-audio,
recording-controller, pause/resume, media-open, and timeline workflow suites. It uses synthetic buffers and
injected capture backends; it never starts a live capture stream or a playback
engine. A successful run emits `RECORDING_COMPONENTS_GREEN`.
It also prints the executable, debug-dylib, and Info.plist SHA-256 digests used for the
same-artifact comparison below.

The September 25, 2026 run passed 58 tests, including accepted-buffer draining
before seal, callbacks after detachment, an already-stopped system stream,
stop during pending startup, stale-session failures, explicit user cancellation,
and timestamp rejection before writing. These are component results. Real
source loss, permission revocation, route changes, storage pressure, and
two-hour synchronization remain unproved. The full M1 completion gate also
names missing implementation; it remains fail-closed.

### Foundational recording workflow

The current implementation uses a Rust-journaled native host-clock anchor,
signed segment offsets, 30-second CAF rotation, segment-local recovery, and
shared-timeline playback. Native conversion state survives rotation. Swift
keeps audio buffers; Rust accepts only clock and segment boundary receipts.
Playback keeps two output buffers and acquires file leases as segments are read.
Unstarted successor segments become explicit recovery gaps; their bytes remain
untouched. Older captures without a calibrated clock retain individual playback.
New clock anchors journal playback alignment policy version 1: a negative
boundary offset may move playback by at most 50 ms to preserve every PCM sample
exactly once. Original host timestamps and mapped starts remain unchanged;
the plan exposes the correction and the playback UI displays it. Positive gaps
remain silence. Correction beyond 50 ms fails closed; this is not long-session
drift qualification.

After building, run the device-free process proof:

```sh
bash script/check_foundational_workflow.sh "$PWD/apps/macos/.build/xcode/Build/Products/Debug/OpenScribeApp.app/Contents/MacOS/OpenScribeApp"
```

A green run prints `proof=`/`excludes=` sets, the SHA-256 of the executable,
debug dylib, and Info.plist, the recovery receipt and every media digest, then removes its
own temporary root unless `--retain` is given. A failed run keeps its root for
diagnosis. Roots left by earlier runs, including the evidence roots named below,
are reported and never deleted.

On September 25 this emitted `FOUNDATION_SYNTHETIC_GREEN`: two 31-second source
tracks, each split into 30-second and 1-second files; external SIGKILL while both
tails were open; four unchanged SHA-256 digests after reopening; and 1,548,000
rendered frames with four amplitude checks proving source offset and overlap.
Separate native coverage verifies a source gap renders as silence. Rust's 91
tests passed, including immutable rational-clock mapping, all three pre-sample
rotation crash boundaries, repeated recovery, timing-tamper rejection, and
bounded clock correction preserving all samples and original timestamps.
The reopened conversation and its shared playback control were visually checked.

Exact tested unsigned app, HEAD `415b221ed266efc263d18659d3c4e110be476df8`
plus the uncommitted candidate:

- executable SHA-256: `104c2aee43dd1f4de6ec7a721de2ae48e0cd4b8703dc54eeaa5bb27648c79194`
- debug dylib SHA-256: `52136671440025a77094781c39d12dcc316933ac0e54b62fe053a712ea5385a8`
- native result: `apps/macos/.build/xcode/Logs/Test/Test-OpenScribeApp-2026.09.25_18-21-27--0400.xcresult`

The same script's explicit `--live` mode passed on that artifact after the user's
live-audio authorization. Both real sources remained Recording for 35 seconds
before external SIGKILL. Recovery retained five unchanged CAF digests: microphone
85 ms, 30 s, and 5.007 s segments; system-audio 30 s and 5.260 s segments. A
14.667 ms microphone gap remains on the timeline; the next microphone boundary
has an explicit 6.1945 ms playback clock correction. All 1,697,100 timeline
frames decoded, then shared native output ran for 1.25 seconds. The reopened
conversation displayed `Recovered and ready`, both sources `Saved`, and
`Play all sources together`.

Retained local evidence (audio remains local, outside Git):

- live root: `/var/folders/dw/m_jqw9f925q5y7g0bplhlp000000gn/T/open-scribe-foundation.Z3jCZq`
- live session: `01a0daa9-57ee-7150-8848-836b86064117`
- live receipt: `recovery-verified.json`; media digests: `media-before.sha256`, within that root
- synthetic root: `/var/folders/dw/m_jqw9f925q5y7g0bplhlp000000gn/T/open-scribe-foundation.Mn0IoU`
- process logs: `/tmp/open-scribe-foundation-verified-{synthetic,live}.log`

`./script/check.sh --scaffold` also passed after these changes, using the existing
Rust cache under Disk Guard: workspace checks/tests, shared-crate WASM checks,
doctrine consistency, shell lint, and tracked/untracked diff hygiene. Its log is
`/tmp/open-scribe-foundation-scaffold.log`. Native component results remain a
separate 58-test proof; scaffold success does not expand the live acceptance.

The earlier live attempt preserved its media but rejected a 6.1975 ms overlap
under the previous strict policy. Its evidence remains in the sibling
`open-scribe-foundation.vET4bA` directory; it is not a passing playback receipt.

This short proof does not establish perceptual audio quality, permission/source/
route failure handling, two-hour drift, pause/resume, native channel-layout
fidelity, mixdown, signing, release, or M1 completion. A new live run still
requires explicit capture and audible-playback authority.

## Safety Net Map

| Surface | Existing Safety Net | Important Gap | Priority | Owner |
|---|---|---|---:|---|
| Rust domain/types | Unit tests and fixture compatibility checks | Migration/backward-compatibility corpus remains small | P1 | Durable-state owner |
| Rust store/journal | Preparation, media-open, first-sample, sealing, digest, typed interruption, segmented dual-source recovery, calibrated timeline, and projection-repair tests | Long-session and source-loss continuation remain unqualified | P0 | Durable-state owner |
| UniFFI boundary | Fresh bindings, coarse clock/segment receipts, bounded playback leases, and a dated short live dual-source proof (September 25 artifact) | Long-session and failure-matrix qualification remains open | P1 | Integration owner |
| CAF writer and microphone adapter | Deterministic buffer, failure, race, stop barrier, receipt tests, and dated short real-device runs (the latest segmented run on the September 25 artifact) | No route-change, disk-pressure, or long-run proof | P0 | Native runtime owner |
| Live recording controller | Required-source coordination, typed interruption, callback/drain races, pause/resume, degraded continuation, and a dated short live shared-timeline recovery/playback run (September 25 artifact, before pause/resume and the review repairs) | Real route-loss recovery, current-source live requalification, and long-run proof remain open | P0 | Native runtime owner |
| Single-instance guard | Exact lock ownership unit test | AppDelegate conflates an existing instance with lock-file I/O failure | P1 | Native shell owner |
| Menu-bar UI | Build and scene-launch fixture | No UI automation for source selection, durable state transitions, or error recovery | P1 | UX/QA owner |
| System/application audio | All-authorized system audio participated in the dated short live segmented recovery proof (September 25 artifact) | A single-application picker exists in source but is unqualified, and `--m1-complete` still lists application-scoped selection as missing implementation; channel-layout fidelity (stereo system-audio CAF, Rust channel validation) passes synthetic component tests only and has no live receipt | P0 | Platform capture owner |
| Playback/import/transcription/diarization | Managed local CAF and M4A import, deterministic deduplication/rejection, imported-conversation projection, validated-byte playback leasing, shared recovered/imported playback failure tests, and one dated real 865 MB M4A import receipt | Other real files and formats, audible or full-duration playback, long-session, transcription, diarization, installed/signed-artifact, source-loss, and public-delivery behavior remain unproved | P1 after recorder | Conversation-loop owner |
| Release | Scaffold/build checks | No signed, notarized, installed, upgrade, rollback, or public-source binding | P1 before release | Release owner |

## Characterization Backlog

- [x] **P0 — Native runtime owner:** pin that capture is not shown until durable first-sample evidence exists.
- [x] **P0 — Native runtime owner:** pin current permission-denial, start-failure, capture-failure, and stop-before-first-sample behavior.
- [x] **P0 — Native runtime owner:** prove cleanup and durable typed interruption after preparation succeeds but capture start, first sample, callback, premature stop, or sealing fails.
- [x] **P0 — Durable-state owner:** characterize deterministic restart discovery of deliberately interrupted preparation, media, first-sample, and sealed phases without touching media.
- [x] **P0 — Durable-state owner:** prove forced-process termination, relaunch discovery, playable recovery, persistent playback, and idempotent completion on an exact artifact.
- [ ] **P0 — Platform capture owner:** characterize required-source loss independently for microphone and the selected system-audio mode.
- [ ] **P1 — Conversation-loop owner:** characterize transcription retry/replacement while the sealed audio remains unchanged.
- [x] **P1 — Library owner:** characterize managed local CAF import deduplication and unsupported or malformed media rejection.
- [ ] **P1 — Library owner:** characterize large files and partial metadata with real user-selected sources and broader formats.

## CI Gates

| Gate | Command / Receipt | What It Proves | Explicitly Does Not Prove |
|---|---|---|---|
| Scaffold | `./script/check.sh --scaffold` | Doctrine and founding scaffold consistency | Product runtime |
| Early-M1 candidate | `./script/check.sh --m1-segment-sealing` | Deterministic early-M1 source/build/test chain named by the receipt | Real capture, playable recovery, transcription, signing, or release |
| Interruption integrity | `./script/check.sh --m1-interruption-state` | Typed content-free post-preparation failure state, journal-before-projection ordering, restart classification/repair, media preservation, fresh bindings, and focused controller behavior | Live audio, forced termination, playable recovery, system audio, `Recording`, transcription, signing, or release |
| Short live dual-source capture | `./script/check.sh --m1-dual-source-runtime` (`--m1-live-microphone` is an alias) | Explicit microphone and system-audio access, required-source `Recording`, capture, sealing, digests, and playable CAFs on the exact built app | Recovery, source-loss continuation, active revocation, application selection, long sessions, signing, or release |
| Forced-termination recovery | `./script/check.sh --m1-forced-termination-recovery` | Real dual-source `Recording`, external process kill, atomic two-track recovery, persistent `ready_for_review`, native playback, independent decode, unchanged digests, and idempotent relaunch | Source-loss continuation, active revocation, application selection, long sessions, transcription, signing, or release |
| Release preparation contract | `./script/check.sh --release-prepare` | Semantic input validation, stable unresolved holds, artifact-verifier rejection paths, and read-only exact-source binding | Closed P0s, signed-artifact success, notarization, publication, or release |
| Diff hygiene | `git diff --check` | Patch whitespace validity | Functional correctness |
| Working-tree inventory | `git status --short --branch` | Exact local residue | Candidate admission or commit cleanliness |

The short live dual-source and forced-termination gates last passed before
segmented capture. The current gate source accepts multiple sealed CAF segments
per track, checks their Rust digests against the saved files, and binds output to
the built app hashes. The forced-termination path now waits through a segmented
capture span and checks both recovered tails plus unchanged earlier segments.
These are source changes, not new runtime receipts. Both gates stay RUNTIME HOLD
until they pass on the same exact app under explicit device authority.
Compare the executable, debug-dylib, and Info.plist digests printed by the recorder component,
short live, forced-termination, and foundational workflow runs. A combined
qualification requires identical digests; a changed build requires fresh runs.

On September 28, after Disk Guard capacity was restored, the recorder candidate
committed with this entry passed, on one app identity:
`cargo test --locked -p open-scribe-store` (135 tests),
`cargo test --locked -p open-scribe-uniffi` (8 tests),
`bash script/build_and_run.sh --verify-recording` (`RECORDING_COMPONENTS_GREEN`,
79 tests, fresh bindings, no project Swift warnings), and
`bash script/check_foundational_workflow.sh <app binary>`
(`FOUNDATION_SYNTHETIC_GREEN`, recovery receipt `cbd5fc28…2a5e`). App digests:
executable `104c2aee43dd1f4de6ec7a721de2ae48e0cd4b8703dc54eeaa5bb27648c79194`,
debug dylib `db1b6ccd74fb9b8652c004b5ae49ac9b0a8669ade231ba85e88760f2b6cd0e8d`,
Info.plist `c103e34b917098d3964f5992f343fd5f8fd17306642ecafb0e4c23fbaa97acab`.

These runs found and repaired: an import constructor missing its channel field;
the CAF inspector requiring two bytes per packet, which rejected every stereo
CAF that AVAudioFile writes (four bytes per packet); Rust and Swift test fixtures
that wrote non-CAF or mono media into stereo authorizations; and store opens that
failed with SQLite `database is locked` while an append held the write lock,
because deferred transactions upgrade without the busy timeout. Store write
transactions now begin `IMMEDIATE`; the runtime snapshot stays deferred. The
bindings checked in before this run were stale against the mixdown API.
These are synthetic and component receipts. They exclude real capture,
permissions, audible output, source loss, long sessions, and M1 acceptance.

### September 28 — M1 failure and duration matrix request

The requested source-loss, permission-revocation, route/device-change,
selected-app-exit, sleep/wake, disk-pressure, pause/resume, and two-hour
dual-source cases remain **RUNTIME HOLD** on this candidate. With about 55 GiB
free, the host remains below Disk Guard's 100 GB reserve; no current app was
built or launched for these cases. There are no candidate-bound visible-state, retained
media, recovery, playback, or drift results to admit. The M1 completion gate
still returns `M1_COMPLETE_HOLD`.

The acceptance contract remains the founding PRD's event visibility, activity
log, media preservation, and explicit fallback or stop for device changes; the
two-hour cross-track drift target is at most 100 ms. Three source gaps found
before the run are repaired in source and component tests only: system sleep
journals `system_sleep_observed` and pauses through the sealed-pause path, wake
journals `system_wake_observed` and never resumes; `source_failed` appears in
recorder events at the failed source's last sealed sample; and
`RecorderEventList` is mounted in the live view and saved conversations. None of
these is a live sleep/wake, source-loss, or accessibility receipt.

### September 28 — Consumer admission request

The deliberate-start-to-library session, interrupted-session readback, and
local-import readback have not run on this dirty candidate. The September 25
capture/recovery receipts and September 27 real M4A import receipt remain bound
to their earlier artifacts. Source connects the main-window Record, Stop and
Save, and Import Audio actions to the saved-conversation sidebar and playback
controls, but that path has no current runtime result. No candidate-bound
keyboard or VoiceOver behavior has been observed. Source declares shortcuts
for Record, Stop, Pause/Resume, Marker, and Refresh Library, plus an explicit
live-status accessibility label and combined source-row accessibility
elements. These declarations are not interaction proof. The macOS 13
application picker uses `SCShareableContent` and `SCContentFilter` in source;
the deployment target is 13.0 and the current SDK declares the filter
initializer from macOS 12.3.
This host is macOS 27, so no macOS 13 runtime result exists. App digests,
session and import IDs, saved media digests, interrupted recovery, and library
playback results are unavailable for this request. The M1 completion gate
returned exit 1 with `M1_COMPLETE_HOLD`; admission stays HOLD.

New gates must fail closed, clean up processes and temporary state they own, print proof and exclusion sets, and bind runtime claims to the exact built artifact.

## September 27, 2026 — Product pause/resume component proof

The foundational recorder's Pause/Resume controls are included in the native
target and fresh UniFFI bindings. Rust owns the durable boundaries; Pause drains
both sources (including rotation during drain), seals their CAF segments and
freezes captured time. Resume opens successor segments in the same session and
requires a single host-clock boundary plus fresh durable samples from every
required source before showing Recording. Stop while paused finalizes sealed
audio without starting either source.

`RecorderPauseResumeTests` uses injected sources and a controlled host clock with
the real controller, journal/SQLite authority, CAF writers and PCM reader. Five
tests cover repeated cycles, stale callbacks, 30-second rotation during drain,
denied resume and explicit retry, paused finalization, interruption on drain or
resume startup failure, preserved source bytes and captured-time playback.
The recording component command passed all 63 selected tests:

```bash
disk-guard run --budget-gb 10 --volume "$PWD" -- bash script/build_and_run.sh --verify-recording
```

The store's focused timeline tests and `./script/check.sh --scaffold` also passed.
For a single Cargo cache, use
`CARGO_TARGET_DIR="$PWD/apps/macos/.build/rust-macos13"` for scaffold/store checks.
The exact tip, commands, exit codes and logs are retained in
`~/Documents/Codex/2026-09-27/open-scribe-pause-resume/`.

This moves only the `pause_resume` implementation hold. `M1_COMPLETE` remains
HOLD, including real dual-source pause/resume qualification. No real capture,
TCC change, speaker output, long-session synchronization, marker qualification,
validated mixdown, disk-pressure policy, application-scoped selection or native
channel-layout fidelity is proved by this component receipt. The September 25
foundational narrative and its narrower proof boundaries remain unchanged.
