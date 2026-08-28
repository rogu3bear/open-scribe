---
artifact: acceptance-criteria
version: "1.0"
created: 2026-08-27
status: working-contract
---

# Acceptance Criteria: First-Class Local Conversation Loop

## Story Context

As a demanding individual Mac operator, I want to deliberately record a live conversation or import existing audio, preserve the source locally, and revisit a timestamped, speaker-reviewable conversation record so that I can recover what happened without an account, a meeting bot, or blind trust in model output.

This is a test projection of the founding PRD, not an independent product authority. The founding PRD and approved ADRs win if wording diverges. Audio and model output need not be bit-for-bit deterministic; preservation, authority, recovery, correction, and evidence behavior must be observable and repeatable.

## Happy Path

### AC-1: Deliberate menu-bar start

**Given** Open Scribe is idle and the required permissions are available

**When** the user opens the menu-bar control and starts a recording

**Then** capture preparation begins in no more than two user interactions and the selected microphone and computer-audio sources remain visible

### AC-2: Progressive permission

**Given** Open Scribe lacks one or more required capture permissions

**When** the user deliberately starts a recording

**Then** each permission is explained and requested only when needed, and no unrelated permission is requested

### AC-3: Truthful Recording transition

**Given** a recording is being prepared with microphone and computer audio selected

**When** only one source has begun producing durable media

**Then** the interface remains in a non-Recording state until every required source has durable media and recovery state

### AC-4: Active capture visibility

**Given** every required source has begun producing durable media

**When** Open Scribe enters Recording

**Then** the user can identify the Recording state, elapsed time, and status of each captured source without relying on color alone

### AC-5: Provisional live transcript

**Given** local live transcription is available during an active recording

**When** transcript text appears before final processing

**Then** it is labeled provisional and can change without changing or deleting the captured audio

### AC-6: Stop, seal, and save

**Given** a conversation is Recording from microphone and computer audio

**When** the user stops the recording

**Then** both source tracks are closed, playable, and presented as one saved conversation before derived processing is required

### AC-7: Local conversation library

**Given** one or more live, recovered, or imported conversations exist

**When** the user opens the main application or relaunches it later

**Then** each conversation can be found, named, opened, played, and distinguished by date, duration, source status, and processing status

### AC-8: Imported audio joins the same loop

**Given** the user has a supported local audio file

**When** the user drops it into Open Scribe and confirms the import

**Then** the original remains unchanged and the resulting item supports the same playback, transcription, speaker review, search, correction, and export journey as a live recording

### AC-9: Timestamped transcript navigation

**Given** a conversation has a transcript

**When** the user selects a transcript range or search result

**Then** playback navigates to the corresponding audio interval and identifies whether the text is provisional, final, or user-corrected

### AC-10: Speaker review and correction

**Given** a conversation contains inferred speaker turns

**When** the user renames, merges, splits, or corrects a speaker assignment

**Then** the reviewed presentation updates while the source audio and prior machine inference remain recoverable as distinct history

### AC-11: Conversation search

**Given** multiple local conversations contain final or corrected transcript text

**When** the user searches for a word or phrase

**Then** Open Scribe returns matching conversations and timestamped ranges that can be opened without a network connection

### AC-12: Evidence-linked information

**Given** Open Scribe identifies a decision, commitment, question, topic, person, date, amount, or other derived item

**When** the user inspects that item

**Then** the user can navigate to supporting or contradicting transcript and audio ranges and can confirm, correct, reject, or leave the item unresolved

### AC-13: Portable export

**Given** a conversation contains source metadata, transcript revisions, speaker review, notes, and derived items

**When** the user exports it in a supported portable format

**Then** the export identifies evidence separately from interpretation and contains enough stable timestamps to navigate back to the retained local source

## Edge Cases

### AC-14: Delayed required source

**Given** one selected source is available but the other has not produced a sample

**When** preparation continues

**Then** Open Scribe does not claim Recording and offers a visible cancel or source-recovery path without discarding already written media

### AC-15: Quiet intervals

**Given** a required source contains silence during an otherwise active meeting

**When** the quiet interval occurs

**Then** the source remains represented on the timeline without fabricating speech or treating silence alone as source loss

### AC-16: Two-hour conversation

**Given** microphone and computer audio remain available for two hours

**When** the user records and then plays corresponding moments near the beginning, middle, and end

**Then** the tracks remain within the synchronization tolerance declared by the runtime receipt and every sampled interval is playable

### AC-17: Repeated import

**Given** the user selects media already imported into the library

**When** the import is attempted again

**Then** Open Scribe warns about the existing source or creates an explicitly separate conversation without silently overwriting either record

### AC-18: Model not installed

**Given** playable local audio exists but no compatible local transcription model is installed

**When** the user opens the conversation

**Then** playback and conversation management remain available and transcription is shown as unavailable with an explicit installation path

### AC-19: Alternate transcript run

**Given** a final transcript already exists

**When** the user runs a compatible replacement model or retries processing

**Then** a new revision is created without modifying the source audio or deleting the selected transcript before the replacement completes

## Error States

### AC-20: Permission denied before capture

**Given** a required capture permission is denied

**When** the user tries to start recording

**Then** Open Scribe does not claim Recording, names the blocked source, explains how to recover, and permits a later retry

### AC-21: Source loss during Recording

**Given** microphone or computer audio is lost during Recording

**When** the loss is detected

**Then** the affected source and loss time become visible immediately, safely capturable sources continue according to the declared policy, and the saved conversation marks the incomplete interval

### AC-22: Permission revoked during Recording

**Given** the user revokes a required permission during Recording

**When** Open Scribe observes the revocation

**Then** it stops receiving that source, does not silently widen or substitute capture scope, preserves previously written media, and presents recovery choices

### AC-23: Disk pressure

**Given** available storage approaches the declared safe-capture threshold

**When** a recording is active

**Then** the user receives a content-free warning before unsafe exhaustion and Open Scribe either seals recoverable media or visibly records the exact preservation failure

### AC-24: Forced termination

**Given** an active recording has durable source media

**When** the application process is forcibly terminated and relaunched

**Then** Open Scribe discovers the interrupted session, preserves the original bytes, exposes all strictly valid playable tracks, marks gaps or invalid tracks, and performs the same recovery idempotently on another relaunch

### AC-25: Transcription failure

**Given** a saved or imported conversation has playable audio

**When** transcription fails, is cancelled, exhausts resources, or produces an invalid result

**Then** the audio remains playable and unchanged, the failed run is distinguishable from a final transcript, and the user can retry or select another compatible model

### AC-26: Speaker attribution failure

**Given** a transcript exists but reliable speaker attribution cannot be produced

**When** processing completes or fails

**Then** the transcript remains usable with unresolved speaker labels and the user can manually review speakers without rerunning capture or transcription

### AC-27: Unsupported or corrupt import

**Given** a selected import is unsupported, truncated, corrupt, replaced, or unsafe to read

**When** Open Scribe validates it

**Then** no false conversation is created, the original is not modified, and the user receives a specific local recovery or conversion message

### AC-28: Deletion

**Given** a conversation has audio, transcripts, corrections, derived items, and exports

**When** the user requests deletion and confirms the exact scope

**Then** Open Scribe states what will be removed, what may remain in external exports or backups, and whether the local operation is recoverable through Trash before changing data

## Non-Functional Criteria

### AC-29: Local-only operation

**Given** network access is denied and a compatible local model is installed

**When** the user records or imports, recovers, plays, transcribes, reviews speakers, searches, corrects, and exports a conversation

**Then** the complete journey succeeds without an account or an outbound content request

### AC-30: Capture priority under processing load

**Given** transcription, diarization, indexing, or derived processing is slow or resource constrained

**When** recording is active

**Then** capture continues within its declared buffer and durability limits while derived work slows, pauses, or fails independently

### AC-31: Content-free diagnostics

**Given** capture, recovery, transcription, speaker review, import, provider, or export diagnostics are enabled

**When** a normal or failing journey is exercised

**Then** logs contain no audio, transcript text, participant identity, prompt content, credentials, private path components, or raw screen content

### AC-32: Accessible state and controls

**Given** the user operates Open Scribe with keyboard navigation, VoiceOver, increased text size, reduced motion, or without color perception

**When** they start, inspect, stop, recover, play, correct, search, or export a conversation

**Then** every required control and state remains perceivable and operable with an unambiguous accessible label, value, focus order, and non-color signal

### AC-33: Explicit remote scope

**Given** an optional remote provider is configured

**When** the user requests remote processing

**Then** provider selection alone sends nothing and the user must separately authorize each content category before any corresponding outbound request

### AC-34: Model provenance without determinism theater

**Given** a transcript, speaker assignment, or derived item was produced by a model

**When** the user inspects its provenance

**Then** Open Scribe identifies the compatible engine and model revision, input scope, run state, and evidence ranges without claiming that repeated model output must be identical

### AC-35: Exact-artifact release truth

**Given** a public build is proposed for release

**When** product, website, release-note, privacy, or support claims are evaluated

**Then** every claimed capability is supported by the exact signed and notarized distributed artifact and every unavailable or unproved capability remains visibly excluded

## Notes

- The first validated computer-audio mode is all authorized system audio; application-specific selection remains a later choice unless runtime evidence changes that decision.
- Live transcript text is useful provisional output, never recording authority or a preservation receipt.
- Consent reminders and legal copy cannot determine whether recording is lawful in every jurisdiction; adopted release text and operator review remain required.
- Exact synchronization tolerance, supported import formats, model hardware floor, and deletion/backup semantics must be fixed by their owning ADRs before the corresponding criteria can close.
