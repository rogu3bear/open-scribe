# Open Scribe Testing

## Test Strategy

Open Scribe tests the evidence chain in order: source/configuration, deterministic unit and integration behavior, build, installed/runtime behavior, recovery, signed artifact, and release. A lower plane never proves a higher one. `./script/check.sh --m1-live-microphone` proves ordinary real-device capture/seal/playability; `--m1-forced-termination-recovery` separately proves external-kill relaunch recovery and native playback. Both last passed before segmented capture and need requalification (see [CI Gates](#ci-gates)). `--m1-interruption-state` is a supporting repository-plane regression and cannot substitute for either runtime outcome. Each receipt proves only the inclusions and exclusions it names.

Characterization tests pin observed behavior before correction. Safety-critical invariants—durable media before capture claims, audio survival independent of transcription, required-source truth, and recovery—need tests at the layer that owns the claim plus runtime evidence on an exact artifact.

Repository and source tests currently cover managed local CAF and M4A (AAC/Apple Lossless) import, deterministic deduplication and rejection, imported-conversation projection, validated-byte playback leasing, and shared recovered/imported playback failures. One dated real-file receipt (September 27, commit `3e51b72`, `~/Documents/Codex/2026-09-27/open-scribe-large-import/RETURN.md`) imported an operator-selected 865 MB stereo 48 kHz Apple Lossless M4A through the normal workflow and passed a 41-test run covering reopen, first- and last-frame decode, silent player startup, and bounded memory. Those tests do not prove other real files or formats, audible or full-duration playback, long-running sessions, source-loss recovery, an installed or signed artifact, or public delivery.

### September 29 — M2 final-transcription pipeline without an engine

Store schema migration 5 adds `transcription_runs`, `transcript_chunks`,
`transcript_revisions`, `transcript_segments`, and `transcript_selections`
(row schema 1, cascading from `sessions`). Triggers make complete chunks,
finished runs, revisions, and segments immutable. Transcription input is read
only from sealed PCM segments through playback leases, with every segment's
full bytes rehashed against its sealed digest; `open-scribe-asr` supplies the
`SpeechRecognizer` trait, 48 kHz to 16 kHz conversion, the `fixed-window-v1`
planner, and `overlap-midpoint-v1` reconciliation; `open-scribe-core`
orchestrates per-chunk commits.

One guarded run of `cargo test -p open-scribe-store -p open-scribe-core
-p open-scribe-asr -p open-scribe-models` passed (store 147 with one ignored,
core 9, models 8, asr 6). New proof: exact sealed-sample reads and rejection
of altered media; crash resume from committed chunks; failed and cancelled
runs keeping their chunks while retries reuse only identity-matched chunks;
replacement never displacing the selected revision before completion;
revision and plan validation; decimator passband and anti-aliasing; and, with
a test-only tone-burst recognizer on real imported media, segments within
200 ms of true session time, one copy of an overlap-straddling burst, and
unchanged sealed audio hashes. `crates/open-scribe-store/fixtures/schema-v4/`
(a real schema-v4 database dump from `7122903`) migrates twice with every
evidence row unchanged. Warnings-denied clippy, `NATIVE_CONTRACT_GREEN`, and
`SCAFFOLD_GREEN` (0.9 GB reservation, 279 MB measured growth) passed.
No speech engine, VAD, provisional transcript, UI, or runtime is proven;
`local-transcription` stays Unavailable.

### September 29 — M2 model catalog and verification policy

`docs/models/manifest.v1.json` now records the ADR 0008 `balanced-en` and
`balanced-multilingual` whisper.cpp q5_1 weights at upstream revision
`5359861c739e955e79d9a303bcbc70fb988958b1`, with byte length, SHA-256, GGML
header fields (read from the pinned files by range request), MIT license, and
pinned download origin. Both remain `review_state: Pending` and unbundled.
`cargo test -p open-scribe-models` passed 8 tests: canonical catalog shape;
rejection of unsafe path identifiers, malformed digests, bundled or non-HTTPS
records, duplicates, and unknown schemas; distinct truncated, oversized,
digest-mismatch, not-GGML, wrong-model, incompatible-engine, non-regular, and
symlinked staging failures; atomic idempotent installation that refuses a
replaced staging file, a foreign path, a record mismatch, or a conflicting
existing file; and the resume rule. Warnings-denied clippy and
`./script/check.sh --scaffold` (inside a 2 GB `disk-guard run`) passed.
No engine, known-answer inference, download, receipt persistence, or runtime
behavior is proven; `local-transcription` stays Unavailable.

### September 29 — Attended M1 session preparation

`docs/M1_OPERATOR_SESSION.md` is the ordered operator procedure for physical
routes, permissions, display/sleep, consumer workflows, accessibility, the
two-hour measurement, and macOS 13. It is a plan, not runtime evidence.
`script/m1_operator_snapshot.rb` requires an exact qualified candidate before
writing, rechecks it afterward, retains canonical `recovery.jsonl` bytes and
SQLite projection/event snapshots, and compares sealed-media hashes against
Rust receipts. It distinguishes operator-reported from native-and-operator
observations and never issues an M1 acceptance marker.

`bash script/check_m1_operator_snapshot.sh` passed
`M1_OPERATOR_SNAPSHOT_TEST_GREEN cases=6`: an inert successful snapshot with
the canonical journal, preservation of existing evidence, rejection of dirty
source and changed app bytes before output creation, and retention of sealed
media drift or missing sealed media as a failure. Ruby syntax, `shellcheck -x`, `shfmt -d`, and
`git diff --check` passed. The canonical contributor source checks now include
these fixtures. They do not launch or build an app or prove human behavior.

The operator confirmed sole-writer custody of the checkout at `abbb5ba`; the
four pre-existing APFS repair changes are preserved. Candidate selection
(historical `072a3fb` diagnostic versus a freshly qualified repaired tip),
physical devices and attendance, and the external VM volume remain pending.
The native Computer Use inventory returned `-10005` (app-server exited), so no
visible state, keyboard, or VoiceOver result was observed. Host readback was
macOS 27.0 build 26A428, Apple Silicon `Mac16,5`; no external data volume was
mounted. No recording or VM creation started. The coded stimulus/detector,
bounded overnight runner, and human/long-run completion receipt consumer still
require implementation and qualification. `M1_COMPLETE` remains HOLD.

### Recorder component check

`./script/check.sh --candidate <absolute-new-record>` is the canonical contributor
source/build/test entry. It requires committed, clean source, preserves the
scaffold and web gates, runs clippy with warnings denied, checks the native
contracts, generates and compares bindings, and builds one unsigned app and test
bundle with `build-for-testing`. It retains source/native logs and their digests.
It then runs the complete Swift suite, scene launch, recorder components, and
synthetic foundational recovery. Device-dependent proofs remain separate.

`./script/build_and_run.sh --verify-recording --candidate <absolute-record>`
consumes that record with `test-without-building` and runs the microphone, system-audio,
recording-controller, pause/resume, media-open, and timeline workflow suites. It uses synthetic buffers and
injected capture backends; it never starts a live capture stream or a playback
engine. A successful run emits `RECORDING_COMPONENTS_GREEN`.
All four consumers validate the record's commit/tree against clean source and
compare the executable, debug dylib, Info.plist, Rust library, test executable,
test-run description, and build log against their SHA-256 digests before and
after execution. They require the matching contributor-check receipt. They
never repair a mismatch by rebuilding. The receipt prints the record digest,
commit/tree, and artifact digests for same-candidate comparison.

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
bash script/check_foundational_workflow.sh --candidate "$candidate"
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
| Contributor candidate | `./script/check.sh --candidate <absolute-new-record>` | One committed source/build/test entry, one app/test build, warning and clippy checks, native and web regressions, synthetic recovery | Live capture, permission matrix, M1 completion, signing, release |
| Early-M1 candidate | `./script/check.sh --m1-segment-sealing` | Deterministic early-M1 source/build/test chain named by the receipt | Real capture, playable recovery, transcription, signing, or release |
| Interruption integrity | `./script/check.sh --m1-interruption-state` | Typed content-free post-preparation failure state, journal-before-projection ordering, restart classification/repair, media preservation, fresh bindings, and focused controller behavior | Live audio, forced termination, playable recovery, system audio, `Recording`, transcription, signing, or release |
| Short live dual-source capture | `./script/check.sh --m1-dual-source-runtime --candidate <absolute-record>` (`--m1-live-microphone` is an alias) | Explicit microphone and system-audio access, required-source `Recording`, capture, sealing, digests, and playable CAFs on the recorded app, without rebuilding | Recovery, source-loss continuation, active revocation, application selection, long sessions, signing, or release |
| Forced-termination recovery | `./script/check.sh --m1-forced-termination-recovery --candidate <absolute-record>` | Real dual-source `Recording`, external process kill, atomic two-track recovery, persistent `ready_for_review`, native playback, independent decode, unchanged digests, and idempotent relaunch on the recorded app, without rebuilding | Source-loss continuation, active revocation, application selection, long sessions, transcription, signing, or release |
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

The same app then passed `./script/check.sh --m1-dual-source-runtime`
(`M1_DUAL_SOURCE_RUNTIME_GREEN`) from commit `467ed2e`, with identical digests.
Session `01a0eb34-61b3-71e2-b0aa-8552331d4372` sealed one segment per track: the
microphone as mono (106,496 samples, SHA-256 `8769bc25…5dd5a3`) and system audio
as stereo (130,560 samples, SHA-256 `b4dc650a…651c17`). Both Rust digests
matched the saved files and both CAFs decoded independently. This is the first
live receipt for delivered channel-layout fidelity. The gate retains its proof
root under `apps/macos/.build/`. It excludes forced-termination recovery, native
playback, rotation, source loss, permission revocation, application selection,
disk pressure, and two-hour capture. The forced-termination gate did not run:
Disk Guard held at 95.7 GB free against its 100 GB reserve.

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

## September 29, 2026 — M1 injected failure harness candidate

Prompt 2 began on clean `2dc46a70a6d92b1894f229eabe3a14234c67a144`.
No Prompt 1 candidate JSON existed. The requested
`./script/check.sh --m1-forced-termination-recovery --candidate "$PWD/apps/macos/.build/candidates/m1-closeout/candidate.json"`
therefore returned `CANDIDATE_RED: supply an absolute path to a regular candidate JSON record`.
The receipt is `artifacts/m1-automated/forced-recovery-before.log`; this is a
fail-closed admission result, not recovery proof. No old app was substituted.

The new entry point is
`./script/check.sh --m1-injected-failures --candidate /absolute/candidate.json`
with optional `--case CASE`. It consumes the canonical qualified candidate and
never compiles. Run the complete matrix under
`disk-guard run --budget-gb 2 --volume "$PWD" -- ...` because its dedicated
1.5 GiB sparse APFS image may actually fill. The filler rejects the host device
before writing, stops at ENOSPC or its 2 GiB bound, and removes only its own
filler after capture stops. The image and source-media evidence are retained;
the owned mount and child app are cleaned up, including on failure.

The intended cases and markers (all **runtime unqualified** at this source
checkpoint) are:

| Case | Intended pass marker | Injection boundary |
| --- | --- | --- |
| `storage-warning` | `M1_INJECTED_STORAGE_WARNING_GREEN` | Controller storage probe; warning journal and continued capture |
| `storage-critical` | `M1_INJECTED_STORAGE_CRITICAL_GREEN` | Same probe; reserve policy seals and stops |
| `storage-exhaustion` | `M1_INJECTED_STORAGE_EXHAUSTION_GREEN` | Actual CAF write on dedicated ENOSPC volume; failure must be journaled before recovery |
| `microphone-loss` | `M1_INJECTED_MICROPHONE_LOSS_GREEN` | Microphone failure callback; remaining source continues |
| `system-loss` | `M1_INJECTED_SYSTEM_LOSS_GREEN` | System-audio failure callback |
| `application-loss` | `M1_INJECTED_APPLICATION_LOSS_GREEN` | Application-audio failure callback |
| `selected-app-exit` | `M1_INJECTED_SELECTED_APP_EXIT_GREEN` | Production exit handler, with unrelated-PID rejection |
| `sleep-wake` | `M1_INJECTED_SLEEP_WAKE_GREEN` | Production power-observer entry points; sealed pause, no automatic resume |
| `kill-preparation` | `M1_INJECTED_KILL_PREPARATION_GREEN` | Durable preparation before media authorization |
| `kill-recording` | `M1_INJECTED_KILL_RECORDING_GREEN` | Rust-confirmed first samples for both sources |
| `kill-stop` | `M1_INJECTED_KILL_STOP_GREEN` | Stop entered, before adapter drain |
| `kill-seal` | `M1_INJECTED_KILL_SEAL_GREEN` | CAF closed, before Rust accepts its seal |
| `kill-processing` | `M1_INJECTED_KILL_PROCESSING_GREEN` | Derived AAC writer opened, before encoding; sources already sealed |

Each forced checkpoint stops its own process with SIGSTOP; the parent verifies
the stopped PID and delivers SIGKILL. Relaunch uses production launch recovery
twice, with source-digest and journal-idempotence checks. Preparation must show
an interrupted session without claiming audio. Other phases require both
tracks, preserved pre-event frames, and complete timeline decoding.
The independent Ruby verifier cross-checks SQLite events with JSONL, checks
Rust's source digests/lengths, independently decodes CAFs with `afconvert`, and
checks every PCM sample and stereo channel identity. Case receipts bind the
candidate-record hash and harness-log hash, and each log includes all candidate
artifact digests. Native state projections are checked; physical device events,
rendered accessibility, TCC, audible quality, long sessions, and full ADR 0006
commit/journal-internal crash coverage are excluded.

Executed source-only checks: `ruby script/check_m1_injected_contract.rb` printed
`M1_HARNESS_CONTRACT_GREEN cases=10`; candidate-record and native-contract
checks passed; shellcheck, shfmt, new Swift-file formatting, project plist
validation, and diff hygiene passed. The contract fixtures reject false
checkpoints, foreign sessions, false Recording, divergent recovery, missing
journal evidence, app errors, changed second-recovery journals, redirected
reports, and host-volume filling. They are verifier tests, not injected app
receipts. Source also refreshes the recorder event projection after a durable
source failure; the affected native regression and runtime cases remain due.

Reconciliation of `--m1-complete` remains conservative:

| Existing gate item | Source owner found | Evidence still required before changing its gate entry |
| --- | --- | --- |
| `durable_markers` | Rust recorder action and Swift Add Marker | Candidate-bound journal/native marker proof |
| `validated_mixdown` | Rust mixdown authorization/receipt; `ValidatedMixdownBuilder` | Candidate-bound validated AAC decode and source retention |
| `disk_pressure_policy` | Rust reserve/warning policy; storage probe/watch/segment boundary | Both probe cases plus actual-volume exhaustion/recovery |
| `application_scoped_selection` | Platform picker and `SCContentFilter` selection | Actual scope isolation and supported-OS permission/picker matrix; injected exit is insufficient |
| `native_channel_layout_fidelity` | Mono/stereo CAF writer and stereo timeline | Candidate-bound channel proof plus device-format matrix |
| source loss / degraded continuation | Production failure callbacks and Rust source retirement | All injected source cases, then physical-source runs |
| permission revocation / route change | Adapter and permission paths | Actual TCC/device matrix; synthetic callbacks cannot close it |
| pause/resume / two-hour synchronization | Recorder boundaries and persisted host timeline | Fresh live pause/resume and real two-hour drift at most 100 ms |

No M1 completion item was removed on source inspection. The gate must continue
to list automated gaps until actual receipts qualify them; two-hour capture
must not be relabeled a human-only check to make the list shorter. Initial disk
measurement is `artifacts/m1-automated/before.txt`: target 2,426,940 KiB,
native `.build` 3,935,704 KiB, task artifacts 2,346,896 KiB. Candidate admission
and the final disk delta are recorded separately after execution.

### First committed harness qualification attempt

On `e0609d2b02c490b6f0f8e56ede5956188a4e260e`, the canonical command
`disk-guard run --budget-gb 10 --volume "$PWD" -- ./script/check.sh --candidate "$PWD/apps/macos/.build/candidates/m1-closeout-e0609d2/candidate.json"`
was admitted. It passed `SCAFFOLD_GREEN` (including 135 store and 8 UniFFI
tests), clippy with warnings denied, `NATIVE_CONTRACT_GREEN`, and
`WEB_BUILD_GREEN`; generated bindings matched. The Xcode test build then
failed (exit 65) at `OpenScribeApp.swift`'s extended launch-root `??` chain:
the compiler could not type-check it in reasonable time. The successor uses
a typed optional-URL list with identical precedence. No candidate JSON or
native runtime receipt was issued. Logs are
`artifacts/m1-automated/candidate-e0609d2.log` and the candidate directory's
`build.log`/`source-checks.log`; earlier source receipts remain bound to that
commit. Measured target growth was 2,991,332 KiB and the partial native
candidate occupied 980,340 KiB (4.067 GB together). With shared targets now
warm, the successor requests a 6 GB budget, covering that measured growth
plus headroom for native linking/tests; Disk Guard still owns admission.

### Built candidate rejected by the full native test gate

The guarded 6 GB canonical attempt at
`f4dca800ff702f108c84a0b34b8ee9ea08a5ccf1` again passed scaffold, clippy,
web, and fresh bindings. Its unsigned Xcode test build and artifact-floor
checks passed, producing
`apps/macos/.build/candidates/m1-closeout-f4dca80/candidate.json`:

| Artifact | SHA-256 |
| --- | --- |
| Executable | `104c2aee43dd1f4de6ec7a721de2ae48e0cd4b8703dc54eeaa5bb27648c79194` |
| Debug dylib | `427ce7da7b1c11c7b6474a5286b124d301b30b63132e0135e4528af2f8a9e45b` |
| Info.plist | `c103e34b917098d3964f5992f343fd5f8fd17306642ecafb0e4c23fbaa97acab` |
| Rust library | `ab22c70790f658454b755f5d1bcaf69abb3deb3fdc5ad695e5a858040207392b` |

Full `test-without-building` then failed with crashes in four legacy
`LiveMicrophoneRecordingControllerTests` source-failure cases. The crash
stack enters `NativeRecordingPreparation.recorderDetail` through an inert
test-double Rust handle. The new event refresh must apply only to segmented
recording, which owns the recorder timeline; production and injected capture
both use that path. The existing nonsegmented component cases remain in the
full gate, and `RecorderPauseResumeTests` asserts the real event projection.
This candidate has **no contributor-check qualification** and cannot be used
for the runtime consumers. Its logs and failed `.xcresult` are retained;
one surviving owned test-host process was terminated after the gate exited.
Measured warm-target growth was 11,740 KiB; the completed native candidate
occupied 999,364 KiB, totaling 1.035 GB. Subsequent qualification requests
3 GB for these measured inputs plus headroom; no guard reserve is changed.

### Single-build acceptance at 072a3fb, followed by injected failures

Committed source `072a3fb38b77356fe9bf47032610c100c8d0315a`, tree
`35a8fc54d65eb963a8d3b19799edaf5cbace1f88`, passed the guarded 3 GB canonical
candidate command. Record:
`apps/macos/.build/candidates/m1-closeout-072a3fb/candidate.json`, SHA-256
`e53ff285b17c078cda4296c9355a59973b9f4ea9d9abe51854389afb28d4837f`.

| Artifact | SHA-256 |
| --- | --- |
| Executable | `104c2aee43dd1f4de6ec7a721de2ae48e0cd4b8703dc54eeaa5bb27648c79194` |
| Debug dylib | `a7750683402c056567e5962861d7a2dd87ad6854100d9c8fe0184f5a2d3c84bc` |
| Info.plist | `c103e34b917098d3964f5992f343fd5f8fd17306642ecafb0e4c23fbaa97acab` |
| Rust library | `d6cbfd3325184cbc87d83a564bba430022741fad92c9b4493f771d21ffcacbe1` |

`disk-guard run --budget-gb 3 --volume "$PWD" -- ./script/check.sh --candidate "$PWD/apps/macos/.build/candidates/m1-closeout-072a3fb/candidate.json"`
passed scaffold, clippy with warnings denied, locked web build, fresh bindings,
one unsigned build-for-testing, macOS 13 artifact floor and warning checks,
166 Swift tests (one optional large-import sample skipped), and native scenes.
Its two consumers printed `RECORDING_COMPONENTS_GREEN` (79 tests) and
`FOUNDATION_SYNTHETIC_GREEN`, then `CONTRIBUTOR_CANDIDATE_GREEN`.
Log: `artifacts/m1-automated/candidate-072a3fb.log`.

`disk-guard run --budget-gb 0.25 --volume "$PWD" -- ./script/check.sh --m1-forced-termination-recovery --candidate "$PWD/apps/macos/.build/candidates/m1-closeout-072a3fb/candidate.json"`
passed `M1_FORCED_TERMINATION_RECOVERY_GATE_GREEN`: real microphone and system
audio, over 30 seconds of rotation, external SIGKILL, five independently
decoded CAF segments with unchanged hashes, native playback open, and two
idempotent relaunches. Log: `artifacts/m1-automated/forced-recovery-072a3fb.log`;
retained root `apps/macos/.build/m1-forced-recovery.3eez7n`, session
`01a0ee74-ba2e-7fe1-a6a4-8d1226d82671`.

`disk-guard run --budget-gb 0.1 --volume "$PWD" -- ./script/check.sh --m1-dual-source-runtime --candidate "$PWD/apps/macos/.build/candidates/m1-closeout-072a3fb/candidate.json"`
passed `M1_DUAL_SOURCE_RUNTIME_GREEN`. Log:
`artifacts/m1-automated/dual-source-072a3fb.log`; retained root
`apps/macos/.build/m1-live-microphone.bl66Dg`, session
`01a0ee75-b2a5-7513-900f-f86ebbb43fe8`. All four consumers reported the same
artifact digests above and performed no rebuild. These are bounded 072a3fb
receipts; subsequent code repairs require fresh qualification.

All thirteen injected cases were attempted on that candidate. None qualified:
ten app outcomes reached their intended state but the independent verifier
wrongly expected the two initial SQLite preparation events to share journal
IDs. The actual protocol creates SQLite intent before the journal, then a
separate directory-ready journal record; later IDs do match. The repaired
verifier checks that exact mapping, including a new missing-preparation
rejection fixture (`M1_HARNESS_CONTRACT_GREEN cases=11`).

Two product defects were reproduced. `kill-preparation` left the durable
session in `preparing` after launch. The dedicated APFS volume reached zero
available bytes (`ENOSPC_OBSERVED bytes_written=1578106880`); capture failed
visibly and preserved its media, but journal/SQLite had no failure event and
SQLite still said `recording`. Evidence is retained under the candidate's
`m1-kill-preparation.IcfdCF` and `m1-storage-exhaustion.QpzHQU` roots. The latter
contains `journal-before-free.jsonl` and
`events-before-recovery-inspection.json`, collected before any production
recovery. Only the owned filler was removed; the volume image was detached
and retained. A readonly SQLite attempt at completely full capacity also
failed with disk I/O error; the harness now snapshots the journal first,
frees its filler after app exit, and reads SQLite before recovery.

On the 072a3fb source plus the repair diff, the guarded 1 GB command
`cargo test --locked -p open-scribe-store m1_` failed both new regressions for
those intended behaviors, then passed after repair. The full guarded
`cargo test --locked -p open-scribe-store` passed 138 tests. Logs:
`artifacts/m1-automated/rust-m1-red-072a3fb.log`, `rust-m1-green.log`, and
`rust-m1-repair-suite.log`. Rust now interrupts trusted, abandoned pre-media
capture preparation and physically allocates 16 MiB of emergency journal
space before a new capture. A critical observation releases that allocation
before journal/SQLite writes; reopening a library does not refill it. Foreign
files, symlinks, and hardlinks are refused unchanged. Swift rechecks actual
capacity on source failure. These component proofs do not qualify the repaired
full-volume runtime until a fresh committed candidate passes it.

### 327a894 qualification and remaining full-volume diagnosis

`327a8948bd66ea8fc4e483378b96b356257c9181` (tree
`c3e53420cbba628d27fe2cd4efe0d84c255a06c1`) passed the guarded 3 GB canonical
gate, including 138 Rust store tests, 166 Swift tests (one optional sample
skipped), 79 recorder tests, and foundational recovery. Record:
`apps/macos/.build/candidates/m1-closeout-327a894/candidate.json`, SHA-256
`c6799135c2c6f2cb91e19b3cb3350c9a57e0befe7c8c95520ebd99a71494aaf0`.

| Artifact | SHA-256 |
| --- | --- |
| Executable | `104c2aee43dd1f4de6ec7a721de2ae48e0cd4b8703dc54eeaa5bb27648c79194` |
| Debug dylib | `3e23032fff9b54c5bd110ba071a31698a6a0b3d5f86bcbd1a91807efbe051a41` |
| Info.plist | `c103e34b917098d3964f5992f343fd5f8fd17306642ecafb0e4c23fbaa97acab` |
| Rust library | `9bcd4e2c298a7cbc3b8cae6412e5b065038b3563a5c4742c21185293adc21db8` |

The guarded 0.1 GB `--m1-injected-failures --candidate RECORD --case kill-preparation`
passed `M1_INJECTED_KILL_PREPARATION_GREEN` and issued a candidate-bound case
receipt. It now shows Interrupted with no invented audio and unchanged journal
bytes across two relaunches. Log: `artifacts/m1-automated/preparation-327a894.log`.

The default matrix stopped on a second verifier mismatch: Rust intentionally
keeps `mixdown_intent`/`mixdown_validated` only in JSONL. The verifier now admits
only those exact journal-only kinds for reviewable sessions while requiring
every recorder event to match SQLite, with contiguous sequences in both logs.
Three added fixtures cover that mapping and reject unknown unprojected events
and derived media before reviewability (`M1_HARNESS_CONTRACT_GREEN cases=14`).

The guarded 2 GB full-volume retry remained RED: source media recovered, but
there was still no failure event before the filler was removed. Root:
`apps/macos/.build/candidates/m1-closeout-327a894/m1-storage-exhaustion.ktXOzL`;
log: `artifacts/m1-automated/exhaustion-327a894.log`. Its 16 MiB reserve remained
allocated. Foundation capacity probes returned zero correctly. A separate
128 MiB APFS Rust test reached actual ENOSPC, failed a real source-file write,
then released reserve space and journaled critical storage successfully:
`artifacts/m1-automated/reserve-capture.B7RGmo/test.log`. This narrows the
failure but does not qualify the native app. LLDB stopped at macOS's
`task_for_pid` authorization boundary; only the owned diagnostic processes
were terminated and their volume detached, with no permission change.

The next repair moves known-critical reserve release before any SQLite read,
since WAL/SHM handling itself can need space. Explicit Debug harness launches
also retain content-free Rust error classes and storage-probe results. The
native full-volume result remains due; the ordering change is not yet claimed
as its proven root-cause repair. The dedicated-volume Rust regression is
explicitly ignored in ordinary suites and must be run with
`OPEN_SCRIBE_RESERVE_TEST_VOLUME` on an isolated disposable volume; it refuses
the host device and bounds filling.

`--m1-complete --candidate RECORD` now validates each case record's candidate
hash, scenario, marker, and harness-log hash before removing its automated
gap. Six inert fixtures reject absent, foreign-build, changed-log,
missing-marker, and redirected receipts. Source inspection found the
application picker/filter and mono/stereo adapters implemented; their actual
scope/device matrices remain explicitly unqualified human checks. Markers,
mixdown, and storage-policy proof remain conditional on their runtime cases.
The separate `--m1-live-controls --candidate RECORD` entry point is intended
to check real pause/resume/stop and both continued sources. It is excluded
from the default permission-free thirteen-case matrix and has no runtime
receipt yet. Two-hour synchronization remains an automated runtime gap, not
a relabeled human-only item.

## September 29, 2026 — APFS exhaustion and scene-launch repair

Candidate `ccf542bf0b42a3758e61293d4d0144572a30f677`, record
`apps/macos/.build/candidates/m1-closeout-ccf542b/candidate.json` (SHA-256
`c428515adb419ee63f9c38fc36339cca2267f4bb1ed41a4deec06381052999c5`), built once
and passed 166 native tests with the optional large-import test skipped.
Qualification remained RED: the standalone launch emitted only the menu-bar
scene, so its primary-scene Settings trigger never ran. A second qualification
attempt reused the same build and repeated all source/tests; live log streaming
confirmed the missing primary event. Logs: `artifacts/m1-automated/candidate-ccf542b{,-retry}.log`
and `scenes-ccf542b-retry.log`; first-attempt source/native logs are preserved
under the candidate's `qualification-attempt-1/`. No checks receipt was issued.
The explicit Debug scene-proof launch now opens the primary window from the
menu-bar scene, retaining all three existing required scene checks. Its native
reproof remains due on the next committed candidate.

A diagnostic-only launch of that unqualified app reached actual ENOSPC and
returned Rust I/O error 28 before any failure event. This did not issue a
qualifying runtime receipt. Its executable/debug-dylib/Info.plist/Rust-library
SHA-256 values were respectively
`104c2aee43dd1f4de6ec7a721de2ae48e0cd4b8703dc54eeaa5bb27648c79194`,
`1c05d469075b72d18aac6a02b2c74d2fc542c23f473957a07ed525695c618693`,
`c103e34b917098d3964f5992f343fd5f8fd17306642ecafb0e4c23fbaa97acab`, and
`a4c91c0bf68094ce9955b666c0f999bafa0ccb947e14198c13d90dbd03b2a88d`.
The guarded 2 GB diagnostic log is `artifacts/m1-automated/ccf-enospc-diagnostic.log`;
its retained 1.5 GiB APFS image is under `ccf-enospc-diagnostic.nthvRa/`.

Direct operations on that owned reserve isolated the cause: truncation to 41,
4096, and zero bytes all returned ENOSPC without changing its 16 MiB allocation.
Validated unlink followed by close allowed a new file write and fsync. These
two probes reused the already allocated diagnostic image under a 0.1 GB guard;
logs are `reserve-{truncate,unlink}-ccf.log`. Only their own filler was removed;
all source CAFs and original journal bytes remain retained.

The ignored Rust regression was expanded to bound filling at 2 GiB and run
on that same 1.5 GiB volume with
`OPEN_SCRIBE_RESERVE_TEST_VOLUME=VOLUME cargo test --locked -p open-scribe-store m1_real_full_volume_can_release_reserve_and_journal_critical_storage -- --ignored --nocapture`.
Under `disk-guard run --budget-gb 1 --volume "$PWD" -- …`, it failed with error 28
before the fix (`reserve-large-red.log`), then passed after Rust switched to
validated unlink, descriptor close, and directory fsync before journaling
(`reserve-large-green.log`). Both ordinary reserve tests and store clippy
with `-D warnings` also passed. Foreign files, symlinks, and hardlinks remain
rejected unchanged; library reopen does not replenish released space. These
are component results. The full native exhaustion gate and all affected
candidate-bound runtime receipts remain due.

### Delayed journal allocation after reserve release

`abbb5baf3d3991887c6615950944fd1c1b0289a2` passed the complete 3 GB guarded
contributor candidate gate: scaffold, clippy, web, macOS floor, 166 native tests
(one optional skip), all three scenes, 79 recording-component tests, and the
foundational workflow. Log: `artifacts/m1-automated/candidate-abbb5ba.log`.
Record: `apps/macos/.build/candidates/m1-closeout-abbb5ba/candidate.json`, SHA-256
`f5a4e39686eaa8d05060a844f5127530546ecde0c4ef2a9f43cb667111ecb866`;
tree `4d5e04963079e63439a88bf2032073622095fa4a`. Its executable, debug-dylib,
Info.plist, and Rust-library digests are respectively
`104c2aee43dd1f4de6ec7a721de2ae48e0cd4b8703dc54eeaa5bb27648c79194`,
`f8b5bfd335a3d1a462a05c47a90bbf4ad8962960fa55451400ea8b8376aa9c5c`,
`c103e34b917098d3964f5992f343fd5f8fd17306642ecafb0e4c23fbaa97acab`, and
`feea2c1c1457232ff1933b18fbc109483391f03773008624bcfb6f82c8b26189`.

The native full-volume gate remained RED on that build: both tracks sealed
before filler removal, but no critical-storage/failure event was journaled.
The reserve was absent and one Rust ENOSPC was reported. Evidence is retained
in `m1-storage-exhaustion.qEJ3ur/` under that candidate and in
`artifacts/m1-automated/exhaustion-abbb5ba.log`. No case receipt was issued.
Repeated component testing reproduced the same failure. Temporary stage
diagnostics isolated it to replacement-file **creation**, after successful
reserve unlink/close/directory sync (`reserve-journal-stage.log`, attempt 3).
Those temporary source diagnostics were removed after diagnosis.

The journal now retries only ENOSPC during create-new, with at most 25 waits
of 10 ms. A successful creation ends the retry; permanent exhaustion, existing
files, and unrelated errors still fail. Later append/sync/rename/projection
operations are not retried. Three deterministic tests cover transient success,
the strict retry bound, and preservation/error propagation. The real-volume
regression then passed ten consecutive runs under a 1 GB guard while reusing
the already allocated component-test volume. Logs:
`artifacts/m1-automated/reserve-create-retry-green.log` and
`reserve-create-retry-clippy.log` (clippy passed after making the now test-only
OpenOptions import conditional). Native qualification remains due on the new
committed candidate; these repetitions do not turn the earlier app failure green.

## September 29, 2026 — Candidate build infrastructure

The cold web failure was reproduced from base `71fa611` in a new
`artifacts/build-once/cold-web-before` target. The guarded command was
`CARGO_TARGET_DIR="$PWD/artifacts/build-once/cold-web-before" disk-guard run --budget-gb 6 --volume "$PWD" -- cargo leptos build --release --project open-scribe-web -vv`.
It failed at wasm-bindgen's build script with `E0463` for `rustversion`.
Direct `dlopen` of its existing proc-macro dylib exposed a misaligned LINKEDIT
string pool. With the workspace release build-dependency strip override, the
same locked graph built from an empty `cold-web-after` target through
`disk-guard run --budget-gb 6 --volume "$PWD" -- bash script/build_web.sh`:
`WEB_BUILD_GREEN`, useful SSR, hydration, hashed assets, Worker bundle, and SSR
regression test passed. The rebuilt host dylib loaded successfully. Logs are
`artifacts/build-once/cold-web-{before,after}.log`.

`bash script/check_candidate_record.sh` passed 14 rejection cases, including all
seven artifact digests, missing/foreign contributor receipts, changed check
logs, dirty/staged source, another commit, and malformed JSON.
`bash script/check_native_contracts.sh`, shellcheck, shfmt, and diff hygiene also
passed. These are build-tool component proofs; candidate-bound app/runtime
acceptance is recorded separately after a committed-source run. No earlier app
receipt qualifies the new gate.

Implementation commit: `8cd176d1d3fc61b834e84898f6aaba0ba1425b4a`, tree
`608e35adb2b184cc341f0357201865a0edc5b34f`. All four public consumers also
rejected a missing record before executing a build or app. The extended floor
reader passed against existing artifacts (778 arm64 archive members plus both
app Mach-O files); that is a reader regression check, not new runtime evidence.

**Acceptance HOLD:** the 10 GB guarded scaffold attempt returned exit 75 before
execution. The scaffold hold reported 144.6 GB free, with a
separate Cloudflare build holding a 40 GB reservation and a 100 GB host reserve.
No hold was bypassed. The contributor candidate build and all four positive
candidate-bound proofs have not run; no new app or Rust-library digests exist
to report. `SCAFFOLD_GREEN` for this change is also still required. The final
Worker build's added `--locked` argument awaits the contributor web rerun.

After checkpoint commit `b44ba22d5046d6e0472855b9aa29ce8d08808768`, the canonical
entry was attempted under the same 10 GB guard and again returned exit 75 before
building, reporting 142.1 GB free. Its log is
`artifacts/build-once/contributor-candidate.log`; no candidate record was issued.
The retained successful cold-web log has SHA-256
`ba9ff654151b7acf186d0314632ae6ddfbd5014b01fef90fd26143e123a87960`;
the 14-case rejection-test log has SHA-256
`ce8d99f1946f6c90297e2f5e13ac3ac99a698251af860a6271b878b757fcbc5e`.

Measured allocation, in KiB (September 29, 17:28 UTC before and 17:51 UTC after):

| Path / measure | Before | After |
|---|---:|---:|
| `target/` | 2,426,440 | 2,426,940 |
| `apps/macos/.build/` | 3,935,704 | 3,935,704 |
| Task-owned `artifacts/build-once/` | 0 | 2,346,868 |
| Volume free (`df -k`) | 152,518,688 | 139,707,100 |

The task's measured build/evidence footprint grew about 2.40 GB; free-space
changes include concurrent work and are not attributed solely to this task.
The failed and passing cold targets and logs remain retained. Measurements are
in `artifacts/build-once/disk-{before,after}.txt`; scaffold holds are in
`scaffold-precommit.log` and `scaffold-precommit-admitted.log` in that directory.

Resume after Disk Guard can admit the allowance: run the scaffold, then
`disk-guard run --budget-gb 10 --volume "$PWD" -- ./script/check.sh --candidate "$PWD/apps/macos/.build/candidates/$(git rev-parse HEAD)/candidate.json"`
on the clean committed tip. Run the live dual-source and forced-termination
consumers against that same record, compare all four receipts' app/library
digests, and record the positive results here before closing the checklist.

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

## September 29, 2026 — Transcript review, export, deletion, and permission truth

Commit `c4fae7fa5f76d9d30efc1cb7e0889398559c73e8` (tree
`c75a50ffdefbc62aa049fad74ff1490ec83e0453`; feature commit `c66f460`). Every
command below ran against that exact tree before it was committed, each under
`disk-guard run --budget-gb <2–5> --volume "$PWD" -- …`:

- `cargo fmt --all -- --check`.
- `cargo test --locked -p open-scribe-evidence -p open-scribe-store`: evidence 2
  passed; store 156 passed (1 ignored) plus 1 separately. New: three deletion
  paths, five review/search tests, and permission revocation through interruption.
- `cargo test --locked -p open-scribe-core -p open-scribe-uniffi`: core 14 passed
  (five export tests over a real import and transcription run); UniFFI 8 passed.
- `cargo clippy --locked -p open-scribe-store -p open-scribe-core -p open-scribe-uniffi -p open-scribe-evidence -p open-scribe-asr -p open-scribe-models --all-targets -- -D warnings`:
  clean once `bec01a0` named the placement tuple.
- `./script/check.sh --scaffold`: `SCAFFOLD_GREEN` (200 workspace tests, WASM
  check of shared crates, shell lint, diff hygiene).
- Bindings regenerated with `script/build_rust_macos.sh`, `uniffi-bindgen generate --library …`,
  `swift-format`, and `clang-format`; `./script/build_and_run.sh --verify` then
  byte-compared them and printed `NATIVE_FIXTURE_XCODE_GREEN`: 170 Swift tests,
  one optional skip, zero project compile warnings, including timeline seek and
  three transcript-model tests against the real Rust library.
- `./script/check_native_contracts.sh --all`: `NATIVE_CONTRACT_GREEN`, with the
  user-selected read-write entitlement.
- `cargo test --locked -p open-scribe-web --features ssr ssr_is_useful_without_hydration`
  and `./script/build_web.sh`: `WEB_BUILD_GREEN`.

Local Debug app, not a candidate record: executable, debug-dylib, and Info.plist
SHA-256 `104c2aee43dd1f4de6ec7a721de2ae48e0cd4b8703dc54eeaa5bb27648c79194`,
`2c20b0a062f03c7e5b852ed6b5bb3d49bb24feb37345e0563f25c97d88d3b6cc`, and
`c103e34b917098d3964f5992f343fd5f8fd17306642ecafb0e4c23fbaa97acab`.

Plane: source, unit, integration, and native test-host proof. Deletion used
temporary libraries; the Swift test injects its trash mover instead of the user's
Trash. Excluded: a qualified candidate, live capture, Finder Trash, real TCC
revocation, rendered inspection of the new transcript surface, transcription (no
engine is integrated), signing, and release.

### Transcript review screen audit and rendered inspection

`8107406` fixed the screen-design findings on the saved-conversation
transcript surface. On that tree, `disk-guard run --budget-gb 1 --volume "$PWD" -- ./script/build_and_run.sh --verify`
printed `NATIVE_FIXTURE_XCODE_GREEN` (171 Swift tests, one optional skip, zero
project compile warnings) and `./script/check_native_contracts.sh --all`
printed `NATIVE_CONTRACT_GREEN`. With `TEST_RUNNER_OPEN_SCRIBE_RENDER_DIR`,
`TranscriptLibraryModelTests/testTranscriptSectionRendersInsideTheDocumentMeasure`
rendered fixed values through `ImageRenderer` at 760 and 480 points: aligned
timestamp and text columns, first line wrapping at about 80 characters,
correction provenance under corrected text, and the empty state. AppKit-hosted
buttons and menus draw as placeholders in that renderer; a live window
capture of the full workspace, dark mode, VoiceOver, and keyboard focus
remain uninspected. Named, not fixed: two co-equal playback buttons in the
audio section, Export in the transcript header rather than the intended
inspector, a per-row `Correct…` action, disabled seek for imported audio, and
a search empty state that does not distinguish "nothing transcribed".

## September 29, 2026 — Website conformance to ADR 0015 routes, CSP, and headers

The site now follows ADR 0015's route and header decisions instead of the
M0 drift the completeness audit found. `/documentation` replaces `/docs`;
GitHub is an external footer link, not a `/github` route; primary navigation is
Product, How It Works, Privacy, Documentation, and Download; Product links
Record and Meeting; Download says `No public release is available` with no
button. Release SSR sends the exact ADR policy (no `unsafe-inline`),
`Referrer-Policy: strict-origin`, COOP and CORP `same-origin`, a Permissions
Policy denying camera, microphone, display capture, geolocation, and other
sensors, and `X-Robots-Tag: noindex` on `workers.dev` hosts. Hydration starts
from a hashed same-origin boot module that `hash_assets.mjs` emits, so the
inline hydration hash and the `base64`/`sha2` web dependencies were removed;
`Cargo.lock` and `docs/supply-chain/components.v1.json` were regenerated.

- `disk-guard run --budget-gb 3 --volume "$PWD" -- cargo test -p open-scribe-web --features ssr --lib`:
  5 passed, including the exact policy, the header set with preview
  `noindex`, the route and navigation matrix, and the no-inline boot.
- `disk-guard run --budget-gb 4 --volume "$PWD" -- ./script/build_web.sh`:
  `WEB_BUILD_GREEN`. The same five tests ran with the build's asset hashes, and
  `verify_build.mjs` checked the boot module's hash and its references to the
  hashed JS and Wasm, plus the Worker Wasm carrying the boot hash, the exact
  script policy, COOP, and Permissions Policy. Boot asset:
  `/pkg/open-scribe-web.0380b69d15de5de0.boot.js`.
- `disk-guard run --budget-gb 3 --volume "$PWD" -- ./script/check.sh --scaffold`:
  `SCAFFOLD_GREEN` (200 workspace tests).

Plane: source, unit, and local build proof. Excluded: a browser load under the
policy, deployed response headers, reflow, accessibility, performance budgets,
and every other ADR 0015 release acceptance. Capability-true equality with a
release manifest remains missing, and deployment requires separate authority.

## September 29, 2026 — d106565 candidate and the fourteen automated M1 cases

Committed source `d106565db4724541fdd3d34387f7e3c5d9285277`, tree
`936f62c109fe1929aef3a7a5964b6bf5ebeae849`, passed
`disk-guard run --budget-gb 5 --volume "$PWD" -- ./script/check.sh --candidate "$PWD/apps/macos/.build/candidates/m1-closeout-d106565/candidate.json"`:
`CONTRIBUTOR_CANDIDATE_GREEN` (scaffold, clippy, web, macOS 13 floor, 171 Swift
tests with one optional skip, three scenes, recording components, and the
synthetic SIGKILL recovery workflow). Record SHA-256
`5cb164026021a452878dacae098649c705e04781bb9c99b5a79ce2a1a71299fb`.

| Artifact | SHA-256 |
| --- | --- |
| Executable | `104c2aee43dd1f4de6ec7a721de2ae48e0cd4b8703dc54eeaa5bb27648c79194` |
| Debug dylib | `cc5062da1d3fd0a096ff6b8973ca51b700db3b5b241a72175908d3975e117372` |
| Info.plist | `c103e34b917098d3964f5992f343fd5f8fd17306642ecafb0e4c23fbaa97acab` |
| Rust library | `a07cb46d0aa4ff3f23ebf918d0e2a7512c3e4fca9707b2a50f46cd764508b600` |

Against that record, `--m1-injected-failures` issued candidate-bound GREEN
receipts for 12 of the 13 default cases: storage-warning, storage-critical,
microphone-loss, system-loss, application-loss, selected-app-exit, sleep-wake,
and kill-preparation, -recording, -stop, -seal, and -processing. Logs:
`/tmp/os-verify/injected-d106565.log` and `injected-rest-d106565.log`.

Two cases were RED, both from proof-harness defects rather than recorder
behavior:

- **storage-exhaustion:** `real media write did not fail on the dedicated full
  volume`. The filler stops at the first refused 1 MiB write, which can leave
  most of a MiB free; the app's 96 KB write then succeeded, and capture stopped
  cleanly at the reserve with `storage_observed` critical journaled. On a
  scratch 64 MB APFS image, 404 KiB more fit in 4 KiB writes after the first
  1 MiB refusal. `m1_fill_volume.rb` now steps down through 64 KiB and 4 KiB
  chunks; on a fresh scratch image a following 96 KiB write then failed with
  ENOSPC. The verifier is unchanged.
- **live-pause-resume** (real microphone and ScreenCaptureKit, one explicit
  run): capture, marker, pause, and both seals were journaled, then the proof
  asked Rust for a playback plan while paused. `playback_timeline` admits only
  `ready_for_review` sessions (since `702ae68`), so it returned
  `no sealed timeline media`. The proof now reads the pause boundary from the
  journaled `capture_paused` event and splits the final Rust-validated plan at
  it, keeping the same two-source and one-second continuation thresholds.

Evidence stays under the candidate directory (`m1-storage-exhaustion.Nx6eEF`,
`m1-live-pause-resume.mh0nX9`). These fixes change committed source, so all
fourteen cases must run again on a new candidate.

### 429ec94: all fourteen automated M1 cases on one candidate

Committed source `429ec94c734d981b1efe2ecef88452c109b45add`, tree
`06af79b3f0ac038546313bc7e9a036147fd4ee15`, passed
`disk-guard run --budget-gb 2 --volume "$PWD" -- ./script/check.sh --candidate "$PWD/apps/macos/.build/candidates/m1-closeout-429ec94/candidate.json"`:
`CONTRIBUTOR_CANDIDATE_GREEN`, 171 Swift tests (one optional skip) and 80
recording-component tests. A first 5 GB request was held by Disk Guard (111.5 GB
free); it was not bypassed, and the retry used the measured footprint (the
d106565 build occupied about 1.1 GB). Record SHA-256
`c3d20aacd1c2e397237ab373504a38af2ccccc847bae751d1d235c80e38c9415`.

| Artifact | SHA-256 |
| --- | --- |
| Executable | `104c2aee43dd1f4de6ec7a721de2ae48e0cd4b8703dc54eeaa5bb27648c79194` |
| Debug dylib | `7fb1a184eb5641daa25e9ceb304eb402f23c46e147e4f828fc999031c2916f3c` |
| Info.plist | `c103e34b917098d3964f5992f343fd5f8fd17306642ecafb0e4c23fbaa97acab` |
| Rust library | `3c311fa01fabf002d9ee5d5f5943805818893794f3d952d99a4da014014ecb49` |

Each case ran as
`disk-guard run --budget-gb 0.25 --volume "$PWD" -- ./script/check.sh --m1-injected-failures --candidate RECORD --case CASE`
(2 GB for storage-exhaustion). All fourteen issued candidate-bound GREEN
receipts: the thirteen default cases and live-pause-resume. storage-exhaustion
filled its image to the 4 KiB block (`bytes_written=1569718272`), the media
write failed (`write_failed: true`), capture stopped, the failure was journaled
before space was freed, and recovery was idempotent. live-pause-resume used
real `AVAudioEngine+ScreenCaptureKit` capture on this Mac's already-granted
permissions: marker, pause, resume, two tracks, 534,760 rendered frames.
Logs: `artifacts/m1-automated/candidate-429ec94.log` (SHA-256
`4136411a1ba3d47d115e13bad1585c9884e83ce394d545c36f654991a1b0b0d3`) and
`injected-429ec94.log` (SHA-256
`430834dc87ac852018af5757c372dc619b83344477dd59cc89ab060552ec25e0`).

`./script/check.sh --m1-complete --candidate RECORD` still prints
`M1_COMPLETE_HOLD`, now with `qualified_cases` listing all fourteen,
`missing_implementation_proof` empty, and `missing_automated=two_hour_synchronization`.
The human matrix (permission grant/deny/revoke/restore on macOS 13 and current,
physical routes and devices, application-scope isolation, channel layouts,
rendered accessibility, perceptual playback) remains unqualified. One live run
on one Mac is not that matrix.

## September 29, 2026 — In-process whisper.cpp transcription from a verified local model

`open-scribe-asr` now links whisper.cpp 1.8.3 through `whisper-rs-sys` 0.15.0
(Accelerate and Metal, static). All 778 vendored whisper.cpp files were
byte-compared with upstream commit `2eeeba56e9edd762b4b38467bab96c2517163158`
(archive SHA-256 `089b898aa83b24a8321e0fd554eeb0967fb03dd687e27f6374c72d3363b5b429`)
and none differed; that is the commit the model manifest pins. The pinned
`ggml-small.en-q5_1.bin` was fetched from its manifest origin into `/tmp`
(outside the repository) and matched the manifest's 190,098,681 bytes and
SHA-256 `bfdff4894dcb76bbf647d56263ea2a96645423f1669176f4844a1bf8e478ad30`.
The app itself makes no network request: the user chooses a downloaded file;
Rust stages it, verifies length, header, engine compatibility, and SHA-256,
decodes one second of silence as a self-test, installs atomically, and
reverifies before every load. Reconciliation v2 counts whole-segment
annotations such as `[BLANK_AUDIO]` as non-speech instead of transcript text.

Speech samples came from `say -v Samantha` (16 kHz float WAV SHA-256
`61b0f752b772b1e9ecf55bff47d0eded93bb82fdb7bb356cc85edd7250ca7015`; 48 kHz
16-bit CAF SHA-256
`a6f3263e87835a63b269b4ffd35125b79424dd8dda94e09629bdb275e2de97b1`).

- `disk-guard run --budget-gb 3 --volume "$PWD" -- cargo test --offline -p open-scribe-asr -p open-scribe-models -p open-scribe-core`
  with the three `OPEN_SCRIBE_WHISPER_*` paths set: all passed. The known-answer
  test returned "openscribe keeps the recording safe before it writes a
  transcript." (mean token probability 0.95), refused a 31-second window, and
  honored cancellation. The core end-to-end test installed the model from the
  chosen file, transcribed an imported conversation (two segments), read it
  back through the review library, and found it by search.
- Clippy with warnings denied on store, core, uniffi, asr, and models: clean.
- Bindings regenerated; all 20 whisper/ggml archive members report `minos 13.0`.
- `disk-guard run --budget-gb 0.4 --volume "$PWD" -- ./script/build_and_run.sh --verify`
  with `TEST_RUNNER_`-prefixed paths: `NATIVE_FIXTURE_XCODE_GREEN`, 174 Swift
  tests with the one optional large-import skip. In the app test host,
  `SpeechTranscriptionModelTests` refused a wrong file without changing it, then
  installed the real model, transcribed an imported conversation (11.8 s),
  loaded a Final transcript containing the spoken sentence, and found it by
  search. Its render test drew the no-model, ready, and progress states and the
  model sheet; AppKit progress bars and links draw as placeholders in that
  renderer.
- `disk-guard run --budget-gb 0.5 --volume "$PWD" -- ./script/check.sh --scaffold`:
  `SCAFFOLD_GREEN` (210 workspace tests; the real-model cases skip without
  their paths). `./script/check_native_contracts.sh --all`: `NATIVE_CONTRACT_GREEN`.

Plane: source, unit, integration, and native test-host proof on this Mac.
Excluded: a candidate-bound receipt, a person clicking through the sheet and
open panel, Metal versus CPU performance, memory or thermal pressure while
recording, the multilingual model, compressed (48 kHz) M4A imports, in-app
download, removal, persisted installation receipts, a speech known-answer at
install time, signing, and release. The capability manifest keeps
`local-transcription` Unavailable.

### Imported audio seeks from the transcript; playback file split

`RecoveredSessionController.swift` (1,902 lines) was split by responsibility,
with every line preserved (sorted-line comparison), into
`PlaybackByteSources.swift` (verified byte sources and the callback decoder),
`RecoveredAudioPlayer.swift` (the bounded player), and the controller. Imported
audio now plays from a transcript timestamp: the callback session seeks its
decoder to the frame at the file's own rate before priming. A stereo 48 kHz
ALAC import kept compressed decoded -0.5 after seeking into its second half
(the first half is 0.25), and the controller passed a 12.5-second start
position to the player. The first run of the new decoder test used a mono
file, which the importer normalizes to PCM rather than keeping compressed; the
fixture is now stereo.

- Full `./script/build_and_run.sh --verify` on this tree: every other test
  passed; only that first fixture failed.
- `xcodebuild … -only-testing:OpenScribeAppTests/ImportedMediaAuthorityAdapterTests -only-testing:OpenScribeAppTests/SavedAudioPlaybackTests test`
  after the fix: 36 tests, one optional skip, 0 failures.

Excluded: audible seek accuracy by ear, and a candidate-bound receipt.

### Compressed M4A imports transcribe through a validated PCM companion

A 48 kHz M4A import stays compressed, so Rust cannot read its samples.
`transcription_tracks` now lists it, and its input is marked compressed. The
app decodes the Rust-verified lease bytes into a temporary 48 kHz 16-bit PCM
CAF. Rust rehashes the managed original against its sealed digest, then
admits the companion only if its format, channel count, and exact frame count
match the import (the channel count comes from the journaled import metadata,
because a compressed segment row carries none). The companion is read, never
recorded as evidence, and is deleted afterwards; transcript times stay on
the original's timeline. The first store run exposed that query reading the
journal kind `media_import_staged` where the SQLite projection uses
`media_imported`; that was fixed before this receipt.

- `cargo test --offline -p open-scribe-store -p open-scribe-core -p open-scribe-uniffi`
  (real-model paths set): store 157 passed, one ignored, and every core and
  uniffi test passed. The new store test refused the PCM reader for a
  compressed input, read a matching companion's last frame exactly, refused a
  one-frame-short companion and a symlinked one, and refused the companion
  once the managed original had one byte changed.
- Clippy with warnings denied on store, core, and uniffi: clean. Bindings regenerated.
- `./script/build_and_run.sh --verify` with `TEST_RUNNER_` paths including a
  stereo AAC `afconvert` of the speech sample (SHA-256
  `cd9cce5c438c82b89e1d48e134296606b435fb2f3f823597d834f60aa6fc6a47`):
  `NATIVE_FIXTURE_XCODE_GREEN`, 178 tests, one optional skip. A stereo ALAC
  import decoded to a 96,000-frame, 16-bit, two-channel PCM companion, and
  cancellation stopped the decode. With the real model, the compressed AAC
  import was kept as M4A, transcribed (12.9 s), and read back as Final text
  containing the spoken sentence.

Excluded: HE-AAC and other codecs beyond what AudioToolbox decodes on this
Mac, decode determinism across macOS versions, long imports, and a
candidate-bound receipt.

### Audio exports, session manifest, and portable package (ADR 0010)

The transcript section's Export menu now offers, per conversation:

- the validated AAC mix;
- a lossless 16-bit WAV mix rendered from the Rust-validated timeline;
- a timeline-aligned WAV for each PCM track;
- an import's managed original;
- an `open-scribe.session-manifest/v1` JSON;
- a `<name>.openscribe` package (`portable.v1.schema.json`).

Media leaves only through a lease whose full bytes match the sealed digest.
The package is staged in a hidden sibling directory and synced. The Rust
verifier checks it before rename, and the rename replaces any existing
package only after that check passes. Export never journals or changes
session state.

- `cargo clippy` with warnings denied on store, core, and uniffi: clean.
  Bindings were regenerated.
- `cargo test --offline -p open-scribe-store -p open-scribe-core -p open-scribe-uniffi`:
  - store: 157 passed, one ignored.
  - core: 22 passed.
  - uniffi: 8 passed.
- The three new core tests:
  - validate a rendered manifest against the checked-in schema;
  - export an import's original byte for byte and a track WAV whose samples
    equal the sealed CAF's, then refuse a mix for an import and a hidden
    destination name;
  - write and verify a package. Verification refused each tampered variant:
    a changed media byte, an undeclared file, a symlink, a traversal path,
    a duplicate path, and an unsupported version.
- `./script/build_and_run.sh --verify`: `NATIVE_FIXTURE_XCODE_GREEN`, 180
  tests, three optional real-model skips.
- `ConversationExportTests`, on a synthetic two-track capture:
  - exported the stereo mix M4A;
  - exported a 16-bit stereo WAV mix of at least 31 s;
  - exported both padded track WAVs;
  - exported a two-track manifest;
  - exported a seven-file package that `verifyPortablePackage` accepted.
- On an imported M4A, the same tests exported a byte-identical original and
  refused a mix.
- `docs/supply-chain/components.v1.json` was regenerated for the lock
  change (core now depends on `rustix` and `sha2` directly).

Excluded:

- importing a package back as a new session (round trip, still intended);
- sandboxed export staging (TD-011);
- export of very long sessions;
- a candidate-bound receipt.

### Screen context: explicit scope, sparse events, no pixel retention (ADR 0011, 0012)

Rust store migration 8 owns context state:

- the scope receipt (`open-scribe.context-scope/v1`) and its epoch;
- the scope's condition: active, paused, revoked, failed, superseded, or
  ended with the recording;
- declared participants and topic;
- append-only `open-scribe.context-event/v1` events.

Every change is journaled before it is projected, and replay is idempotent.
Changing the scope issues a new epoch, and so does resuming it. A proposal
is accepted only under the current active epoch while audio is recording.
Its host times map onto the session clock and may not precede the latest
pause boundary or the last event. Text that repeats the epoch's last
reading is refused as a duplicate unless the user marked the moment. An
empty reading, or one larger than the 16 KiB journal bound (TD-012), is
refused. Refusals are values, never durable effects.

On the Swift side:

- One utility-priority worker holds a single candidate slot, counts what it
  drops, and checks a local epoch token after every suspension.
- Each frame is reduced to a 160×90 grayscale fingerprint with Accelerate.
  The largest 10-pixel block-mean luma change must reach 3.0 before Vision
  OCR runs. The first calibration, a whole-frame mean, missed a small text
  change on a large frame; the fixture caught it before this receipt.
- Follow Pointer requires a 16-point, 600 ms dwell and cancels above
  600 pt/s.
- ScreenCaptureKit takes one frame through the exact filter and excludes
  Open Scribe. Topology names such as "Studio Display, right of Built-in
  Display" come from actual display bounds.
- Pointer-transparent perimeter panels use the ADR's exact values and are
  excluded from capture.
- The live window and the menu bar show the scope with Pause, Resume,
  Mark Now, Narrow Scope, and Revoke. Saved conversations list accepted
  context.

Verification:

- `cargo clippy` with warnings denied on store, core, and uniffi: clean.
- `cargo test --offline -p open-scribe-store -p open-scribe-core -p open-scribe-uniffi`:
  store 163 passed, one ignored; core 22; uniffi 8. The six new store tests
  cover:
  - refused authorizations: permission not granted, snapshot retention, no
    self-exclusion, a mode mismatch, out-of-display region bounds, and a
    display absent from the topology. None of them was journaled.
  - pause, stale, and revoked rejections of queued work, and a new scope ID
    after revocation;
  - duplicate, empty, and backward-in-time refusals, user marks, and a
    chained event digest;
  - no acceptance outside Recording, and an unchanged recorder lifecycle;
  - crash replay of scopes, events, and declarations exactly once;
  - malformed and oversized proposals, none of them journaled.
- `./script/build_and_run.sh --verify`: `NATIVE_FIXTURE_XCODE_GREEN`, 190
  tests, four optional skips. `ContextTests` covered:
  - a four-display topology with negative origins, one display above
    another, and one rotated;
  - fast pointer transit and brief pauses producing no candidate;
  - unchanged or one-level-shifted frames running no OCR, and rendered text
    recognized with top-left boxes;
  - a worker run against real Rust authority: two readings accepted, the
    duplicate refused by Rust, a text-free frame not proposed, a user mark
    accepted, and a capture raced by revocation discarded. A late proposal
    was refused as revoked, and no image file existed anywhere in the
    managed root.
  - the scope model never prompting when listing choices, then prompting
    once when authorizing without permission. It paused on a moved display,
    refused to simply resume that pause, and failed when a watched display
    was removed, while the recording stayed `recording`.
  - the perimeter style table and the scope summaries.
- `TEST_RUNNER_OPEN_SCRIBE_CONTEXT_LIVE_CAPTURE=1`, opt-in, with Screen
  Recording already granted to the test host (the test never prompts): one
  real frame of the main display (2560×1654) and a half-display region crop
  (2056×1329) were captured in memory and reduced locally (175 text blocks,
  counted only; no text was logged or kept).
- AppKit renders of the live inspector, the context-off state, the
  preflight, and the saved review were inspected. The inspection moved the
  scope, exclusion, retention, and permission statements out of the
  scrolling form, beside Authorize, and named the region's area. The
  affected test classes were rerun after that change: 61 tests, one optional
  skip.

Excluded:

- the four-display hardware matrix;
- live permission revocation during a recording;
- a two-hour recording under full context load;
- VoiceOver and Full Keyboard Access inspection;
- rendered overlay review across appearances and accessibility settings;
- snapshot retention;
- the macOS 13 one-frame stream (TD-013);
- context in exports;
- a candidate-bound receipt.

The capability manifest keeps `context-and-evidence-lineage` Unavailable.

### Evidence citation and resolution for every kind (ADR 0013)

`open-scribe.evidence-ref/v1` gains the `context_event` kind. The store
derives every reference from stored identity: the caller never supplies
the IDs, ranges, or digests. It covers transcript segments, human
corrections, audio ranges, markers, and context events (whole, or one
`block-N`). Resolution re-reads the record and returns exactly one ADR 0013
state:

- an audio range rehashes the sealed file's full bytes;
- a context event recomputes its event digest;
- a transcript revision that is no longer selected resolves as Superseded
  and names the current revision, but is never replaced.

UniFFI carries references as canonical JSON. In a saved conversation, Play
from a context event resolves the event first and plays only if it is
Available; otherwise it states why not.

- Clippy with warnings denied on evidence, store, core, and uniffi: clean.
- `cargo test --offline` on store, core, and uniffi: store 167 passed, one
  ignored; core 22; uniffi 8. The evidence crate's 2 tests passed. The four
  new store tests cover:
  - transcripts: Available, Superseded by a newer revision, then
    IntegrityMismatch for a changed digest, a changed start, or another
    track;
  - Missing for an absent sequence or an unknown session;
  - UnsupportedVersion for v2, and an error for a malformed identifier;
  - corrections: Superseded by a later correction;
  - audio: a one-byte change resolves as IntegrityMismatch and Available
    again once restored; a range past the segment is refused;
  - Deleted after two-phase deletion;
  - context events and blocks: Available, then IntegrityMismatch after the
    stored event JSON changed;
  - markers: Available, and IntegrityMismatch for a changed digest.
- `./script/build_and_run.sh --verify`: `NATIVE_FIXTURE_XCODE_GREEN`, 192
  tests, four optional skips. The new Swift test saved a conversation
  through recovery and loaded its context event, whose scope reads Ended.
  It navigated only through resolution, and reported UnsupportedVersion for
  a v2 reference and an error for `{}`.

Excluded: claim evidence navigation and adjudication (Milestone 4),
resolution of stored references across app versions, and a candidate-bound
receipt.

### Local-only workflow with IP networking denied (M4)

`./script/check.sh --m4-local-only` launches the development app with
`--local-only-proof-root` as a direct child of `sandbox-exec`. The profile
denies every outbound IP connection, inbound IP connection, and IP bind.
The harness first confirms the profile refuses a `curl` to `1.1.1.1`.

The proof uses its own library, never the user's, and runs this workflow:

1. A synthetic two-source recording on the real writer.
2. A declared participant and topic.
3. One real display frame, captured and reduced in memory; its text is only
   counted.
4. One context event, accepted under an explicit scope.
5. Recovery, and a full render of the playback timeline.
6. A validated mix.
7. Installation of the pinned model from a local file, then transcription
   of a spoken import.
8. A correction, found again by search.
9. Transcript, manifest, WAV-mix, and portable-package exports; the package
   verifies.
10. Two-phase deletion into a proof-local Trash.

The report holds counts only. The harness also checks:

- Only Rust std's precompiled object references socket symbols.
- The app imports no Foundation or Network networking API.
- No networking API appears in Swift or Rust source.
- No IP socket appeared in once-a-second `lsof` samples.
- No sentinel string (title, participant, topic, context text, correction,
  or spoken words) appears in stdout, stderr, or the app's unified log.
- No image file exists in the library.

Result on the build from the preceding `./script/build_and_run.sh --verify`
(`NATIVE_FIXTURE_XCODE_GREEN`, 192 tests):

```
M4_LOCAL_ONLY_GREEN
report={"context_events_accepted":1,"context_frame_pixels":4234240,"context_frame_text_blocks":26,"correction_search_hits":1,"declared_participants":1,"deleted_sessions":1,"package_files":7,"recovered_segments":4,"rendered_frames":1548000,"saved_context_events":1,"screen_recording_permission":"granted","transcript_segments":2,"validated_mix_bytes":95031}
unified_log_lines=4757 ip_socket_samples=0 retained_images=0
```

The first run reported RED. The harness had counted `log show`'s own
filter-header line as a network denial. A positive control then showed that
unprivileged macOS logs neither sandbox denials nor sandbox reports, so
detection by log was removed. Attempted connections are bounded by the
socket samples and the static checks, not observed directly. `os_log`
redacts non-public values, so the log scan catches public logging and
prints, not redacted values.

Excluded:

- a candidate-bound run;
- a signed App Sandbox build;
- a system firewall;
- a live microphone;
- crash-report content;
- deletion through the system Trash;
- providers.
