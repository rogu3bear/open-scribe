---
artifact: acceptance-criteria
version: "1.0"
created: 2026-10-23
status: draft
---

# Acceptance Criteria: Explicit Microphone Restore

## Story Context

As a person recording a conversation, I want to reconnect the microphone that stopped, so the same conversation keeps the audio from before the interruption, the gap, and the audio after I restore the microphone.

The slice is one open recording that selected a microphone and another audio source. Restore happens only through an explicit Reconnect, after microphone permission is authorized and the selected microphone is available. Pause and resume do not restore it. Choosing a different microphone is a separate confirmation. A microphone-only recording that stops is preserved and interrupted; Reconnect does not start a replacement conversation.

These criteria are subordinate to the founding PRD and to [FIRST_CLASS_ACCEPTANCE_CRITERIA.md](FIRST_CLASS_ACCEPTANCE_CRITERIA.md) AC-21, AC-22, and AC-23. They define the recovery behavior those criteria leave to the declared policy. The failure surface is [MICROPHONE_RESTORE_EDGE_CASES.md](MICROPHONE_RESTORE_EDGE_CASES.md). This draft does not show that any criterion passes.

Quoted sentences are the system-audio wording. When the other source is application audio, the same sentence names that source instead.

## Happy Path

### AC-1: A stopped microphone stays visible while the other audio continues

**Given** a recording is in progress with the microphone and system audio, and both have already saved audio

**When** the microphone stops and system audio is still available

**Then** the user sees "The microphone stopped. System audio is still recording." and Reconnect microphone, system audio keeps recording, and the microphone audio from before the stop remains playable

### AC-2: Reconnect restores the selected microphone in the same conversation

**Given** the microphone has stopped, system audio is still recording, microphone access is authorized, and the selected microphone is available

**When** the user activates Reconnect microphone

**Then** the same conversation contains the earlier microphone audio, a gap with no microphone audio, and new microphone audio after the gap, and system audio plays across that gap without a new interruption

### AC-3: Reconnect from pause resumes the same conversation

**Given** the microphone has stopped, the user has paused the recording, and the selected microphone is available with microphone access authorized

**When** the user activates Reconnect microphone

**Then** the same conversation resumes, the new microphone audio follows the gap, and the source that was still active at the pause is included

## Edge Cases

### AC-4: Resume without Reconnect leaves the microphone out

**Given** the microphone has stopped and the recording is paused

**When** the user resumes without activating Reconnect microphone

**Then** the microphone stays absent, the source that was still active continues, and Reconnect microphone remains available

### AC-5: Reconnect is absent while the microphone is recording

**Given** the selected microphone is currently recording

**When** the user looks for Reconnect microphone

**Then** the control is absent, and no additional microphone audio is added

### AC-6: Reconnect is absent when no recording is open

**Given** no recording is in progress or paused

**When** the user looks for Reconnect microphone

**Then** the control is absent, and no new conversation starts

### AC-7: A different microphone requires an explicit choice

**Given** the microphone has stopped, the other audio is still recording, and the available input is a different microphone from the one selected for this recording

**When** the user activates Reconnect microphone

**Then** the user sees "This is a different microphone. System audio is still recording." and Use this microphone instead, and no new microphone audio is added

### AC-8: Dismissing the other microphone records nothing

**Given** the user sees Use this microphone instead

**When** the user dismisses that choice

**Then** no new microphone audio is added, the other audio continues, and the selected microphone remains the restore target

### AC-9: Confirming the other microphone records that choice

**Given** the user sees Use this microphone instead and microphone access is authorized

**When** the user confirms that choice

**Then** the same conversation gains microphone audio from the confirmed microphone after the gap, and the earlier microphone audio remains playable

### AC-10: A second restore appends another gap

**Given** the microphone was restored once and then stops again while the other audio continues

**When** the user reconnects the selected microphone successfully

**Then** the conversation shows two separate gaps and microphone audio after each one

### AC-11: The first microphone audio can arrive after a stop with nothing saved

**Given** the other selected audio has saved audio, and the microphone stops before it has saved any audio

**When** the user reconnects that selected microphone successfully

**Then** the same conversation contains the other audio, a gap with no microphone audio, and the first saved microphone audio after the gap

### AC-12: A microphone-only recording does not gain a replacement session

**Given** a recording has only the microphone selected, and that microphone has already saved audio

**When** the microphone stops

**Then** the user sees "The microphone stopped and the recording was preserved.", the saved audio remains playable, and Reconnect microphone does not start a new conversation

## Error States

### AC-13: The selected microphone is unavailable

**Given** the microphone has stopped, system audio is still recording, and the selected microphone is not available

**When** the user activates Reconnect microphone

**Then** the user sees "The selected microphone is not available. System audio is still recording.", no new microphone audio is added, and Reconnect microphone remains available

### AC-14: Microphone access is denied

**Given** the microphone has stopped, system audio is still recording, and microphone access is denied or restricted

**When** the user activates Reconnect microphone

**Then** the user sees "Microphone access is off. Enable it in System Settings. System audio is still recording.", no new microphone audio is added, and the user can try again after access is allowed

### AC-15: Microphone access has not been decided

**Given** the microphone has stopped and microphone access has not been granted or denied

**When** the user activates Reconnect microphone

**Then** the user sees "Microphone access is needed before the microphone can rejoin." and the system permission prompt, and no microphone audio is added unless access is authorized

### AC-16: The restore attempt fails

**Given** the user has activated Reconnect microphone for an available, authorized microphone

**When** the new microphone audio cannot be saved, or the microphone disappears before any new audio is saved

**Then** the user sees "The microphone could not be restored. System audio is still recording.", the earlier microphone audio remains playable, and Reconnect microphone remains available

### AC-17: The stopped microphone audio cannot be sealed

**Given** the microphone stops while the other audio is recording

**When** the audio from before the stop cannot be sealed

**Then** the user sees "The microphone could not be sealed safely. Existing audio was preserved.", no restored microphone audio is added, and audio that was already saved remains playable

### AC-18: Free space is too low to restore

**Given** the microphone has stopped, the other audio is still recording, and free space is at the declared safe-capture threshold

**When** the user activates Reconnect microphone

**Then** the user sees "Not enough free space to restore the microphone. Existing audio is still recording.", no new microphone audio is added, and the recording is not stopped by the failed restore

### AC-19: A repeated activation makes one attempt

**Given** a restore attempt is still in progress

**When** the user activates Reconnect microphone again

**Then** one attempt runs, and the conversation gains at most one new stretch of microphone audio from that attempt

### AC-20: Stop during restore keeps saved audio

**Given** a restore attempt is in progress and the other audio has saved audio

**When** the user stops the recording

**Then** the recording ends, audio saved before the stop remains playable, and the microphone is not shown as still recording

### AC-21: The other source stops after the microphone

**Given** the microphone has already stopped and system audio is the only source still recording

**When** system audio stops and its saved audio cannot continue the recording

**Then** the saved microphone and system audio remain playable, and Reconnect microphone is absent because the recording is no longer open

### AC-22: Access is withdrawn during the new attempt

**Given** a restore attempt has started and microphone access is withdrawn before new microphone audio is saved

**When** Open Scribe observes the withdrawal

**Then** the user sees "Microphone access was withdrawn. System audio is still recording.", the earlier audio remains playable, and Reconnect microphone remains available

## Non-Functional Criteria

### AC-23: The recovery state is not conveyed by color alone

**Given** the microphone has stopped while another source continues

**When** the user views the recording

**Then** the text "The microphone stopped.", the other source's continuing status, and the Reconnect microphone control are all present as text

### AC-24: Saved audio and the gap remain distinguishable

**Given** a restore succeeded, or a restore attempt failed after the microphone had already saved audio

**When** the user plays the conversation

**Then** the audio from before the stop plays, the gap is marked, and any later microphone audio is a separate span of the same conversation

## Notes

- The October 22, 2026 recording is the reference case: the microphone stopped while system audio continued, and resume brought back system audio only.
- Pause without Reconnect is required to leave the microphone out. That is the current resume behavior, and it remains the expected behavior.
- A virtual audio device, automatic rejoin, a new conversation after a disconnect, and a workspace rebuild are outside this slice.
- Display-name punctuation and network loss are catalogued in the edge-case document. They are not separate done tests here.
- Store proof, run with `cargo test -p open-scribe-store --lib` (244 passed, 1 pre-existing ignored): `explicit_microphone_restore_adds_a_new_source_while_system_audio_continues`, `microphone_restore_from_pause_authorizes_a_new_source`, `resume_without_microphone_restore_leaves_the_microphone_retired`, `a_second_microphone_restore_appends_another_source`, `an_unstarted_microphone_can_be_retired_and_restored`, `microphone_restore_refuses_a_microphone_only_interruption`, `cancelling_an_unstarted_microphone_restore_keeps_the_other_source`, and `recovery_gaps_an_unstarted_microphone_restore`. Those tests cover the journal, the new source, the gap, pause, resume-without-restore, a second restore, an unstarted microphone, microphone-only refusal, cancel, and crash recovery. They do not mark AC-1 through AC-24 passed.
- The Swift recording controller, Reconnect control, and sentences are implemented. A live headphone pull was not run. An injected host result does not mark AC-1 through AC-24 passed.
- Paused startup keeps the approved microphone identity through the resumed system start and probes again immediately before microphone capture. `testPausedRestoreRejectsDeviceChangeDuringSuspendedSystemStartup` and `testPausedRestoreRejectsMissingDeviceDuringSuspendedSystemStartup` change the injected default to another microphone, or remove it, while that start is suspended. They cover both orders of the other source's first sample for a different microphone and for a missing microphone. While the conversation is still paused, before approval, a missing microphone and a different microphone say the recording is paused. Those preflight notices do not say the other source is recording, and they do not start or journal a restore. Permission, free space, and restore-request failures in that paused preflight use the same paused status. While the resumed span is still Starting, the notice says the recording is resuming and does not say the other source is recording. After Rust confirms capture, the notice uses the existing continuing-source sentence and the confirmation or reconnect control. A mismatch must not start the microphone, must keep the earlier audio and the same conversation, and must require a fresh confirmation for a later microphone. Source presence is not acceptance of AC-7 or AC-9, and it is not a hardware reproduction.
- An approved paused restore can start the microphone adapter and still fail before any microphone sample. `testPausedRestoreCaptureFailureBeforeMicrophoneSampleConfirmsTheSurvivingSource` and `testPausedRestorePermissionWithdrawalBeforeMicrophoneSampleConfirmsTheSurvivingSource` approve the current microphone, suspend the resumed system start, and fail that adapter before a microphone sample. They cover both orders of the other source's first sample for a capture failure and for an injected permission withdrawal. The microphone is retired, the earlier audio and the conversation stay, and the other source is not stopped. If that source's first sample is already durable, Rust confirms the surviving source and the continuing-source notice appears. If the sample is still pending, Starting says the recording is resuming and does not say the other source is recording; Recording and the continuing-source notice wait for that sample. An explicit retry can start another microphone after access is allowed. A live restore is already Recording and keeps its continuing-source sentence. This is not acceptance of AC-16 or AC-22, and it is not a hardware or TCC reproduction.
- A paused restore can fail while opening the replacement microphone, before that adapter starts and before the resumed system writer is accepted. `testPausedRestoreMediaOpenFailureBeforeResumedSystemSampleKeepsResumingWording` injects that one media-open failure and suspends the resumed system start. It covers both orders of the surviving system sample. Preparing and Starting say the recording is resuming and do not say the other source is recording. After Rust confirms the surviving sample, the continuing-source sentence appears. A sample that confirms Recording while system startup is still suspended leaves that source running when startup returns. The replacement microphone does not start, the earlier audio and the conversation stay, the other source is not stopped, the cancellation is durable, and an explicit retry can start another microphone. `testRetiredMicrophoneResumeKeepsConfirmedSystemWhenStartupReturnsLater` covers that same return for an ordinary resume that leaves the retired microphone out. This is not acceptance of AC-16 or AC-22, and it is not a hardware reproduction.
- The source follow-up binds alternate-device approval to its offered identity,
  handles failures before and after a restored first sample, and resets health
  observation sequencing for each replacement adapter. Injected Swift regressions
  cover B-to-C confirmation, first-sample route/write failure and retry, a second
  disconnect with a restarted sequence, stale health/failure/first-sample
  callbacks, and post-restore writer failure. Their presence and compile checks
  are not execution results; native host and live-device acceptance remain
  outstanding.
