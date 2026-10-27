---
artifact: edge-cases
version: "1.0"
created: 2026-10-23
status: draft
---

# Edge Cases: Explicit Microphone Restore

## Feature Overview

While a recording session is still open, a person can restore the microphone that stopped without starting a new conversation. The failed microphone span stays sealed. Any source that is still recording keeps recording. The interruption remains a visible gap. Restore runs only after an explicit Reconnect and a check of microphone permission plus the selected device. Choosing a different microphone is a separate explicit action. Pause and resume do not restore a retired microphone.

This catalog is the failure surface for that slice. It does not add a virtual audio device, automatic rejoin, a workspace rebuild, or a new conversation. It creates no product authority beyond the founding contract. The recording controller keeps a failed microphone retired for later spans, including resume and a later source selection, until an explicit Reconnect. That Swift path was not host-executed. A live headphone pull was not run.

The October 22, 2026 session is the production case: microphone and system audio started at 1:09 p.m. Central, the microphone sealed at 1:27 p.m. with `source_failed` / `capture_failed` and `recording_continues`, and resume at 1:50 p.m. continued with system audio only.

**Related Documents:**

- Founding contract: [FOUNDING_PRD.md](FOUNDING_PRD.md)
- Loop criteria: [FIRST_CLASS_ACCEPTANCE_CRITERIA.md](FIRST_CLASS_ACCEPTANCE_CRITERIA.md)
- Done tests for this slice: [MICROPHONE_RESTORE_ACCEPTANCE_CRITERIA.md](MICROPHONE_RESTORE_ACCEPTANCE_CRITERIA.md)
- Recorder rule: [LiveMicrophoneRecordingController.swift](../../apps/macos/Sources/OpenScribeApp/Media/LiveMicrophoneRecordingController.swift)

## Edge Case Categories

### Input Validation

| Scenario | Expected Behavior | Priority | Notes |
|----------|------------------|----------|-------|
| Reconnect when the microphone is still recording | The control is absent. No second microphone segment opens. | P1 | Restore applies only to a retired microphone. |
| Reconnect when no recording session is open | The control is absent. A new recording remains the existing Start action. | P1 | Restore does not invent a session. |
| Reconnect with microphone permission not yet decided | Ask for permission. Open a segment only after it is authorized. Until then the other audio continues and the gap stays open. | P1 | Same gate as a new recording. |
| Reconnect with permission denied or restricted | Do not open a segment. Other audio continues. | P1 | Current fresh start fails the whole session. Current resume stays paused and does not restore the microphone. |
| Selected device is absent | Do not open a segment. Do not substitute another input. Other audio continues. Reconnect stays available. | P1 | Headphones still disconnected is the reported case. |
| Current input identity differs from the identity selected for this session | Do not restore silently. Keep the other audio running. Offer the separate action "Use [microphone name] instead", naming the pending device. | P1 | A Bluetooth return often has a new CoreAudio identity. Current code clears `microphoneCaptureIdentity` when the source fails, so the slice must retain the pre-failure identity for this check. |
| "Use [microphone name] instead" confirmed | Open a new microphone segment on that explicitly chosen device, in the same session, after the permission check. The gap and the earlier audio stay sealed. | P1 | This is the only path that may change devices. |
| "Use [microphone name] instead" dismissed | No new segment. The selected device remains the restore target. Other audio continues. | P1 | Dismissal is not a device change. |
| Device display name is empty | Still match on identity. Show "Microphone" in the status. Do not refuse restore because the name is blank. | P2 | The name is a label, not the key. |
| Device display name contains punctuation, spaces, or non-Latin characters | Show the name as the system reports it. Do not use it as a file path or journal key. | P3 | Paths stay on the existing segment authorizations. |

### Boundary Conditions

| Scenario | Expected Behavior | Priority | Notes |
|----------|------------------|----------|-------|
| Microphone fails before its first durable sample | Seal or abandon that empty attempt. Other audio continues. The gap starts at the failure. Reconnect can open the first real microphone segment. | P1 | Current degraded path abandons a reserved successor that never accepted a first sample. |
| Microphone fails after a long successful span | Seal the span at its last durable sample. Other audio continues. Reconnect appends a later segment. The earlier audio remains. | P1 | October 22 span was about 18 minutes. |
| Failure and a successful restore with no extra speech in between | The gap can be short. The journal still has a sealed failure and a new segment. The gap is not deleted to make one continuous file. | P2 | A short gap is still a gap. |
| Repeated restores in one session | Each successful Reconnect adds another microphone segment. There is no one-restore limit. Each attempt rechecks permission and device identity. | P2 | Headphones can drop more than once. |
| Microphone is the only source and it fails | The session is interrupted and preserved. Reconnect is not offered inside an interrupted session, and this slice does not start a replacement session. | P1 | Current code degrades only while another source is still going. A sole-source failure stops the session. |
| Other source fails while the microphone is already retired | Preserve every sealed span. Interrupt the session. Remove Reconnect, because the session is no longer recording or paused. | P1 | Current code stops when the last continuing source cannot be sealed into continued recording. |
| Pause, then resume, without Reconnect | Resume reopens only the sources that were still active. The microphone stays retired. Reconnect remains available. | P1 | Current resume keeps `failedSources`. This is the October 22 result and stays true after the slice. |
| Reconnect while paused | Reconnect is available. It checks permission and device, then resumes this session with the restored microphone and any source that was still active. Pause without Reconnect does not do that. | P1 | October 22 paused about one minute after the failure and resumed about 22 minutes later. |
| Storage at the reserve during Reconnect | Do not open the new segment. Keep the session recording or paused as it was. Existing audio stays preserved. | P1 | Current critical storage stops the whole recording. A failed restore must not use that stop as its first result. |
| Storage check cannot be read | Do not open the new segment. Leave the session where it was. | P2 | Unknown free space is not treated as enough space. |

### Error States

| Scenario | Expected Behavior | Priority | Notes |
|----------|------------------|----------|-------|
| Permission withdrawn while the restored segment is starting | Seal or abandon the new attempt. Other audio continues. The microphone returns to retired. Reconnect remains available after permission is restored. | P1 | Current permission watch does not resurrect a retired source. A withdrawn permission on an active microphone seals it and continues the other audio. |
| Capture fails again on the new segment | Seal or abandon that attempt. Other audio continues. Show one failure message. Reconnect stays available. | P1 | One failed restore does not end the session or ban a later try. |
| The failed span cannot be sealed | Stop opening any new segment. Preserve whatever audio is already durable. If continued recording cannot be confirmed, interrupt the session and say that recovery state could not be confirmed. | P1 | Current degrade path does this for the original failure. Restore must not run on top of an unconfirmed seal. |
| Journal or segment authorization fails | Do not claim the microphone is recording. Leave the sealed audio and the other source as they were. Reconnect stays available. | P1 | A durable failure record is required before a successor segment. |
| Audio route changes, then the same device is still the selected input | Treat the route change as a microphone failure. Do not auto-restore when the route returns. The person uses Reconnect. | P1 | Current route interruption calls the same capture-failure path and then retires the source. |
| Session already interrupted or saved | Reconnect is absent. Existing recovery and review paths remain the way back to preserved audio. | P2 | Restore is a live-session action. |
| App leaves the foreground during the permission prompt | The attempt waits for the prompt. No segment opens before authorization. Other audio is unchanged. | P2 | The prompt is the system permission dialog. |

### Concurrency

| Scenario | Expected Behavior | Priority | Notes |
|----------|------------------|----------|-------|
| Reconnect activated twice quickly | One attempt runs. The control is disabled until that attempt seals a segment or returns a message. | P1 | One local operator. The race is a double activation. |
| Reconnect during an in-flight source seal | Wait until the seal settles. Then run the permission and device checks. Do not authorize a successor against an unsealed failure. | P1 | Source-failure handling is already serialized. |
| Pause and Reconnect overlap | Whichever operation started first finishes. The later one then sees the settled state. Pause never clears retirement. Reconnect never drops the other source. | P1 | October 22 paused while the failure was still the active fact. |
| Stop during a restore attempt | Stop wins. Seal what is durable, including the other source. Do not leave a microphone segment that claims it is recording. | P1 | Stop remains available. |
| Device disappears after the check and before the first sample | Abandon the new attempt, keep the other source, and return the microphone to retired. | P1 | The check is not a promise that the device stays. |
| Two people edit one recording | Out of scope. A session has one local operator. | P3 | No shared live editor. |

### Integration Failures

| Scenario | Expected Behavior | Priority | Notes |
|----------|------------------|----------|-------|
| CoreAudio or the microphone capture adapter errors | Same as a capture failure: seal the attempt, continue other audio, keep Reconnect. | P1 | There is no network call in this slice. |
| System permission service unavailable | Treat as permission not authorized. Do not open a segment. | P1 | Local TCC, not a server. |
| System audio adapter errors while the microphone is retired | Preserve sealed audio. If it was the last continuing source, interrupt the session and remove Reconnect. | P1 | System-audio stop failure already preserves recovery state. |
| Journal process cannot record the failure or the new segment | Do not present the microphone as restored. Preserve durable audio already accepted. | P1 | `recordSourceFailure` must be durable and `recordingContinues` before degraded recording is claimed. |
| Disk full while sealing the failed span | Preserve the last durable sample. Do not start the restored segment. If the seal cannot be confirmed, interrupt and say so. | P1 | Storage reserve already stops a healthy recording. |
| Network unavailable | Recording and restore are unchanged. | P3 | This slice does not contact a service. |

## Error Messages

| Error State | User Message | Additional Action |
|-------------|--------------|-------------------|
| Microphone retired, other audio continues | "The microphone stopped. System audio is still recording." | Reconnect microphone |
| Microphone retired and the session is paused | "The microphone stopped. The recording is paused." | Reconnect microphone |
| Selected device absent | "The selected microphone is not available. System audio is still recording." | Reconnect microphone |
| Permission denied or restricted | "Microphone access is off. Enable it in System Settings. System audio is still recording." | Open System Settings |
| Permission not yet decided | "Microphone access is needed before the microphone can rejoin." | Continue the system prompt |
| Identity differs | "This is a different microphone. System audio is still recording." | Use [microphone name] instead |
| Restore capture failed | "The microphone could not be restored. System audio is still recording." | Reconnect microphone |
| Not enough free space | "Not enough free space to restore the microphone. Existing audio is still recording." | Reconnect microphone |
| Seal or journal unconfirmed | "The microphone could not be sealed safely. Existing audio was preserved." | Stop stays available; Reconnect stays hidden until the session is recording or paused again |
| Sole source failed, session interrupted | "The microphone stopped and the recording was preserved." | Existing recovery for an interrupted session |
| Permission withdrawn on the new segment | "Microphone access was withdrawn. System audio is still recording." | Reconnect microphone |

When the other source is application audio rather than system audio, the same messages name that source instead of system audio.

## Recovery Paths

### Microphone Fails While Another Source Continues

**User sees:** "The microphone stopped. System audio is still recording." and Reconnect microphone.

**Recovery options:**

1. Reconnect the selected microphone after the device and permission checks.
2. Keep recording the other source and reconnect later, including after a pause.
3. Stop. Sealed audio from both sides of the gap is kept.

**Data preservation:** The microphone audio before the failure stays sealed. The gap stays visible. The other source keeps its current span.

### Resume Without Reconnect

**User sees:** The paused or recording session, still without the microphone, and the same Reconnect action.

**Recovery options:**

1. Resume, which continues only the sources that were still active.
2. Reconnect from the paused state, which resumes this session with the microphone restored and the surviving source included.
3. Stop and keep the preserved audio.

**Data preservation:** Resume does not delete the gap or reopen the sealed microphone span. Current code already resumes this way. The missing piece is the explicit restore.

### Selected Device Absent or Permission Denied

**User sees:** The matching message from the table. The other source's state is unchanged.

**Recovery options:**

1. Restore the headphones or enable microphone access, then activate Reconnect again.
2. Choose "Use [microphone name] instead" only when a different device is actually present and the person confirms it.
3. Continue or stop without the microphone.

**Data preservation:** No new microphone segment is written. Existing audio stays where it was.

### Different Device Identity

**User sees:** "This is a different microphone. System audio is still recording."

**Recovery options:**

1. Activate "Use [microphone name] instead" to record that device in this session.
2. Dismiss it and reconnect only when the selected device identity is back.
3. Continue with the other source.

**Data preservation:** Dismissal writes nothing. Confirmation opens a new segment after the gap and leaves the earlier audio sealed.

### Restore Attempt Fails or the Device Drops Before the First Sample

**User sees:** "The microphone could not be restored. System audio is still recording."

**Recovery options:**

1. Activate Reconnect again. The control accepts another attempt.
2. Continue or stop.

**Data preservation:** The failed attempt is sealed or abandoned. It does not replace the earlier microphone audio or stop the other source.

### Seal or Journal Cannot Be Confirmed

**User sees:** "The microphone could not be sealed safely. Existing audio was preserved."

**Recovery options:**

1. Stop if the session is still open.
2. Review the preserved audio through the existing interrupted-session recovery.

**Data preservation:** Audio already accepted as durable remains. Restore does not start. The session is not described as still recording the microphone.

## Test Scenarios

### Must Test (P1)

- [ ] Microphone fails after a durable span while system audio continues: the span is sealed, system audio keeps going, and Reconnect is offered.
- [ ] Pause and resume without Reconnect: the microphone stays retired and its earlier audio remains.
- [ ] Reconnect while paused, with the same device and permission authorized: the same session resumes with a new microphone segment and the surviving source.
- [ ] Reconnect while the selected device is absent: no segment opens, system audio continues, and Reconnect can be tried again.
- [ ] Reconnect with permission denied: no segment opens, and the message points to System Settings.
- [ ] The current input identity differs from the selected identity: no silent restore; confirmation is required before that device is recorded.
- [ ] A second Reconnect activation during the first attempt opens only one segment.
- [ ] The new segment fails before its first sample: the attempt is abandoned, system audio continues, and Reconnect remains.
- [ ] The failed span cannot be sealed: no restored segment opens, and durable audio is preserved.
- [ ] Storage is at the reserve during Reconnect: no new segment opens, and the session is not stopped as the first result.
- [ ] A microphone-only recording fails: the session is preserved and interrupted, and Reconnect does not start another session.

### Should Test (P2)

- [ ] Two successful restores in one session produce two later microphone segments and two visible gaps.
- [ ] A route change that returns the same device identity still waits for Reconnect.
- [ ] Permission is withdrawn after the new segment is authorized and before its first sample.
- [ ] Pause and Reconnect start together: one finishes, then the other sees the settled session.
- [ ] Stop during the restore seals the other source and does not leave an active microphone segment.
- [ ] The device display name is empty: identity match still allows restore, and the label reads "Microphone."
- [ ] System audio fails after the microphone is retired: sealed audio remains and Reconnect is removed because the session is interrupted.

### Nice to Test (P3)

- [ ] A device name with punctuation and non-Latin characters is shown unchanged and is not used as a path.
- [ ] Network loss during Reconnect leaves the attempt on the local permission, device, and journal result.
- [ ] A second person or process cannot join the live session.
