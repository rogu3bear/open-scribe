# M1 attended operator session

This is an execution procedure, not an acceptance receipt. Product requirements
remain in founding PRD 10.7, 11.4–11.7, 19.2–19.3, 29.3/29.7, and Milestone 1;
ADRs 0005 and 0007 govern timeline and supported-platform behavior. Record actual
results in `docs/TESTING.md`. Never turn an unavailable device into a passing row.

## Admission and operator stop points

Use one clean, committed, qualified candidate record for the whole session.
Resolve existing preparation/storage failures before selecting a closing
candidate. A new build requires new receipts throughout. Do not use a historical
record to bypass the current checkout binding in `script/candidate.sh`.

Confirm an attending operator, removable microphone, AirPods, headphones,
external display, chosen real import file, and mounted external VM volume.
Record device models, source/output selections, sample rates, OS/build, and
candidate SHA/tree plus executable, debug-dylib, Info.plist and Rust-library
digests. Restore the recorded device/permission settings after each case.

Native inspection must work before claiming visible or keyboard/VoiceOver
results. Pause and ask the operator before each unplug/replug, route-device
handling, display connection, sleep/wake, power/cable change, or physical volume
connection. Wait for their completed action before continuing. Never advance
several physical actions on one assumed response.

Creating, booting, or copying to the VM is gated on the named external volume.
Do not initialize or erase a drive. Use only an Apple-distributed restore image;
record its exact version/build, bytes and hash. Validate host/image compatibility
before installation. A failed compatibility check leaves macOS 13 unproved.

## Evidence capture for every step

Create an ignored `artifacts/m1-operator/` notes directory and a new evidence
directory alongside the candidate, outside its managed media library. Give each
step an ID from the table below. Write a notes JSON file for each phase:

```json
{
  "observer": "operator name",
  "observation_source": "native_and_operator",
  "action": "actual action and selected devices/scope",
  "visible_state": "observed text, timer, sources, focus and recovery instruction",
  "recovery_outcome": "not_yet_attempted, or the actual outcome"
}
```

Use `observation_source: operator` when only the operator reported a result.
Keep that distinction in the receipt. Save the native accessibility tree and
an explicitly captured UI screenshot with the notes when native inspection is
available; no continuous screen retention is required.

```bash
ruby script/m1_operator_snapshot.rb \
  --candidate "$RECORD" --library "$LIBRARY" \
  --step microphone-disconnect --phase before \
  --notes "$NOTES/microphone-disconnect.before.json" \
  --output "$EVIDENCE/microphone-disconnect.before"
```

Repeat with `after` and, when applicable, `recovery`. The snapshot revalidates the
candidate and its qualification logs, saves a read-only SQLite backup and event
tables, copies journal bytes, and hashes media without copying it. Changed
sealed media is reported as an error. Active-media hashes are observations,
not immutability proof. Journal and SQLite copies are independently timed;
compare their event IDs and sequence after capture has settled. The snapshot
prints `OPERATOR_SNAPSHOT_SAVED`, never an M1 admission marker.

For each action, record its UTC time and host/session timeline position from
the durable event. Compare before/after event sequences, source identity,
health/lifecycle and sealed-media hashes. Recover interrupted capture by a
normal relaunch, reopen it in the library, play the available source tracks,
then relaunch again to check idempotence and unchanged media. Record absent
events, lost audio, silent fallback, or misleading Recording as failures.

## Ordered attended checklist

Run the permission rows on current macOS and again inside macOS 13. A fresh
guest account can exercise first grant and denial without resetting host TCC.
Record any required restart separately; never claim a mid-session revocation
from a permission change that only takes effect after relaunch.

| Step ID | Action | Observe and retain |
|---|---|---|
| permission-microphone-deny | Select microphone and deny its first request | Point-of-use request, truthful failure, actionable recovery, no invented media |
| permission-microphone-grant | Later grant, relaunch, start capture | Actual permission state and durable first sample before Recording |
| permission-system-deny | Select computer audio and deny its first request | Only dependent capability denied; exact scope and recovery text |
| permission-system-grant | Later grant, relaunch, start dual-source capture | Both source samples durable; exact selected scope |
| microphone-disconnect | Record beyond a 30-second boundary; unplug selected microphone | Seal/source-change event, surviving source or truthful stop, preserved media |
| microphone-reconnect | Replug and explicitly recover/reselect as offered | Identity, format, explicit retry/resume; no silent continuity claim |
| airpods-route | Connect AirPods and change input/output route | Old segment sealed, new format/identity, visible transition, audible review |
| headphone-route | Connect/disconnect headphones and change output | No captured-audio feedback; visible route behavior and intact tracks |
| sample-rate-change | Change the selected device's supported hardware sample rate | Original format and 48 kHz normalization, sealed boundary, honest failure if unsupported |
| microphone-revoke | Revoke microphone while both sources record | Dependent capture stops; visible loss, durable event, existing media retained |
| microphone-restore | Grant again and follow explicit recovery/relaunch | Actual restart requirement, deliberate resumption, identity and retained bytes |
| system-revoke | Revoke screen/system-audio access mid-recording | Dependent capability stops; scope, event, failure/recovery text |
| system-restore | Grant again and follow explicit recovery/relaunch | Actual permission readback and source samples; no automatic claim of missing content |
| display-disconnect | Disconnect the selected external display | Source disappearance visible/journaled; bounded fallback or dependent stop |
| display-reconnect | Reconnect and explicitly reselect if necessary | Display/source identity, selected scope, preserved media |
| real-sleep-wake | Put the Mac to real sleep, then wake it | Sleep event and sealed pause, no automatic resume, explicit resumed boundary |
| application-scope | Pick a real app; play distinguishable audio in it and another app | Only selected content captured; retain included/excluded signal evidence and picker behavior |
| record-library | Record, pause/resume, add markers, stop/save, open library, relaunch | Durable markers, source tracks and playable mix, library identity and reopen |
| interrupted-library | Interrupt an owned recording process; relaunch and open recovered item | Truthful Interrupted/recovered state, playable retained tracks, unchanged digests and idempotence |
| real-file-import | Operator selects a real local supported CAF/M4A | Source hash before/after, managed copy hash, import ID, library item, audible seek/play/reopen |
| keyboard-controls | Exercise every enabled control in every reachable state | Focus order/restoration, activation, disabled semantics, menu-bar and main-window behavior |
| voiceover-controls | Traverse/activate every control with VoiceOver | Spoken label/value/state, focus, errors, source/scope descriptions, non-color status |
| accessibility-settings | Exercise reduced motion, increased contrast and zoom/text scaling | Readable status/focus, logical headings and usable controls |
| macos13-picker-capture | Boot verified macOS 13 guest with the identical app bytes | Native picker, selected-app isolation, system audio, microphone if guest supports it, permission rows, save/reopen |

Declared shortcuts to exercise: Command-Shift-R Record; Command-Shift-S Stop;
Command-Shift-P Pause/Resume; Command-Shift-M Marker; Command-Shift-I Refresh
Library; Command-Q Quit. Inventory all current controls from the actual native
tree in idle, recording, paused, degraded, interrupted, saved, playback, import,
Sources/picker, menu-bar and Settings surfaces. Shortcut declarations and a
static control list do not substitute for those interactions.

## Overnight two-hour run and reproducible drift measurement

Keep this run separate from route, sleep and revocation tests. Use an explicit
dual-source start, stable speaker output acoustically reaching the selected
microphone, fixed device positions and quiet surroundings. Ask the operator
to arrange devices/power and confirm a suitable audible stimulus before start.
Do not use headphones that prevent the shared signal reaching the microphone.

Use a retained deterministic coded broadband chirp stimulus, with a unique
identifiable pulse at least every 30 seconds. Retain its generator/version,
seed, PCM format and SHA-256, plus output-route and playback start/stop times.
Capture at least 7,200 seconds of overlapping durable microphone and computer
audio, including a pulse near the start and after the two-hour boundary.
Scheduling timestamps or matching track durations alone do not measure drift.

For each pulse, independently decode both sealed source tracks. Detect the
same code with normalized cross-correlation; preserve channel choice, window,
correlation score and rejected/ambiguous detections. Map each detected sample
to the shared session timeline using its segment's persisted `mapped_start_ns`
plus `sample_index / 48000`. Include boundaries and discontinuities; do not
concatenate away gaps or resample to align the tracks.

Let `offset[i] = mic_session_ns[i] - system_session_ns[i]`. Report both absolute
offset and `drift[i] = offset[i] - offset[first]`; the latter removes the fixed
speaker-to-microphone latency. Record fixture latency/calibration uncertainty
and timing resolution. A passing relative drift result does not conceal an
absolute alignment over 100 ms. Fail if either supported measurement exceeds
100 ms, detections are missing/ambiguous, coverage is shorter than two hours,
sources fail, or evidence/media identity differs. Show drift versus time and
retain every raw detection and analysis command for rerunning the result.

The detector/generator and scheduled stop still require implementation and
qualification before an unattended run. This procedure alone is not a
reproducible executed measurement. The agent must not leave an unbounded
recording running or stamp a short proof as two-hour evidence.

For sizing, the current segmented writer uses 48 kHz Int16. At 7,200 seconds,
mono microphone plus stereo computer audio requires 2,073,600,000 source bytes
before headers. Verify the candidate's actual file format first. Add measured
mixdown scratch, final mix, journal and probe allowance; measure actual format
and a representative interval first. Admit the complete allowance with
`disk-guard run --budget-gb MEASURED --volume "$CAPTURE_VOLUME" -- …` and retain
the reservation for the whole run. Preserve a HOLD and do not start capture.

## macOS 13 VM and final admission

No external data volume was mounted at preparation time. Stop for the operator
to attach/name one. Use Apple Virtualization through an available supported
host app; verify macOS 13 restore-image compatibility on this host before
allocating a guest. Keep the VM bundle, guest disk, restore image and temporary
downloads on the named external volume. Bound disk capacity and Disk Guard
allowance before creation. Do not upgrade the guest to a newer macOS and call
it a macOS 13 result.

Copy the existing unsigned candidate app into the guest. Rehash executable,
debug-dylib and Info.plist in the guest before and after each capture case and
tie them to the original record/Rust-library digest. Never rebuild or sign it
for the guest. Record actual guest audio-input/output support; virtual hardware
cannot qualify the physical AirPods/USB/display matrix. [UTM's macOS backend](https://docs.getutm.app/guest-support/macos/)
does not provide USB sharing. [Apple's restore-image compatibility requirements](https://developer.apple.com/documentation/virtualization/installing-macos-on-a-virtual-machine)
and the guest microphone path must be checked before the run.

Keep all injected-failure and live-controls receipts on the same candidate.
Only after all automated, long-run, current-OS, macOS 13, consumer and human
receipts exist may the completion owner admit them. The current
`script/check_m1_complete.sh` has no human/long-run receipt consumer and remains
fail-closed; implement/verify that consumer against the actual evidence without
dropping any existing requirement before rerunning:

```bash
./script/check.sh --m1-complete --candidate "$RECORD"
```

Any missing receipt, different candidate, unavailable hardware, inaccessible
native bridge, unsupported guest, or failed row leaves `M1_COMPLETE_HOLD`.
