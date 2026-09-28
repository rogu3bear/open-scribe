# Open Scribe Testing

## Test Strategy

Open Scribe tests the evidence chain in order: source/configuration, deterministic unit and integration behavior, build, installed/runtime behavior, recovery, signed artifact, and release. A lower plane never proves a higher one. `./script/check.sh --m1-live-microphone` proves ordinary real-device capture/seal/playability; `--m1-forced-termination-recovery` separately proves external-kill relaunch recovery and native playback. `--m1-interruption-state` is a supporting repository-plane regression and cannot substitute for either runtime outcome. Each receipt proves only the inclusions and exclusions it names.

Characterization tests pin observed behavior before correction. Safety-critical invariants—durable media before capture claims, audio survival independent of transcription, required-source truth, and recovery—need tests at the layer that owns the claim plus runtime evidence on an exact artifact.

Repository and source tests currently cover managed local CAF import, deterministic deduplication and rejection, imported-conversation projection, validated-byte playback leasing, and shared recovered/imported playback failures. Those tests do not prove behavior with real user-selected files, broader media formats, large files, long-running sessions, source-loss recovery, an installed or signed artifact, or public delivery.

### Recorder component check

`./script/build_and_run.sh --verify-recording` rebuilds Rust, verifies generated
bindings, builds the unsigned Xcode app, and runs the microphone, system-audio,
recording-controller, media-open, and timeline workflow suites. It uses synthetic buffers and
injected capture backends; it never starts a live capture stream or a playback
engine. A successful run emits `RECORDING_COMPONENTS_GREEN`.

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
| UniFFI boundary | Fresh bindings, coarse clock/segment receipts, bounded playback leases, and short live dual-source proof | Long-session and failure-matrix qualification remains open | P1 | Integration owner |
| CAF writer and microphone adapter | Deterministic buffer, failure, race, stop barrier, receipt tests, and one short real-device proof | No route-change, disk-pressure, or long-run proof | P0 | Native runtime owner |
| Live recording controller | Required-source coordination, typed interruption, callback/drain races, and short live shared-timeline recovery/playback | Route-loss recovery and long-run proof remain open | P0 | Native runtime owner |
| Single-instance guard | Exact lock ownership unit test | AppDelegate conflates an existing instance with lock-file I/O failure | P1 | Native shell owner |
| Menu-bar UI | Build and scene-launch fixture | No UI automation for source selection, durable state transitions, or error recovery | P1 | UX/QA owner |
| System/application audio | All-authorized system audio participates in the short live segmented recovery proof | Application-scoped selection and delivered channel-layout fidelity remain unimplemented | P0 | Platform capture owner |
| Playback/import/transcription/diarization | Managed local CAF import, deterministic deduplication/rejection, imported-conversation projection, validated-byte playback leasing, and shared recovered/imported playback failure tests | No real-user-file or broader-format runtime proof; large-file, long-session, transcription, diarization, installed/signed-artifact, source-loss, and public-delivery behavior remain unproved | P1 after recorder | Conversation-loop owner |
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
