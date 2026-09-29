# Open Scribe Testing

## Test Strategy

Open Scribe tests the evidence chain in order: source/configuration, deterministic unit and integration behavior, build, installed/runtime behavior, recovery, signed artifact, and release. A lower plane never proves a higher one. `./script/check.sh --m1-live-microphone` proves ordinary real-device capture/seal/playability; `--m1-forced-termination-recovery` separately proves external-kill relaunch recovery and native playback. Both last passed before segmented capture and need requalification (see [CI Gates](#ci-gates)). `--m1-interruption-state` is a supporting repository-plane regression and cannot substitute for either runtime outcome. Each receipt proves only the inclusions and exclusions it names.

Characterization tests pin observed behavior before correction. Safety-critical invariants—durable media before capture claims, audio survival independent of transcription, required-source truth, and recovery—need tests at the layer that owns the claim plus runtime evidence on an exact artifact.

Repository and source tests currently cover managed local CAF and M4A (AAC/Apple Lossless) import, deterministic deduplication and rejection, imported-conversation projection, validated-byte playback leasing, and shared recovered/imported playback failures. One dated real-file receipt (September 27, commit `3e51b72`, `~/Documents/Codex/2026-09-27/open-scribe-large-import/RETURN.md`) imported an operator-selected 865 MB stereo 48 kHz Apple Lossless M4A through the normal workflow and passed a 41-test run covering reopen, first- and last-frame decode, silent player startup, and bounded memory. Those tests do not prove other real files or formats, audible or full-duration playback, long-running sessions, source-loss recovery, an installed or signed artifact, or public delivery.

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
