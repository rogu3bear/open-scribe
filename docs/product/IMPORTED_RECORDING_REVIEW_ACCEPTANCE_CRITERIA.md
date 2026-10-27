---
artifact: acceptance-criteria
version: "1.0"
created: 2026-10-22
status: draft
---

# Acceptance Criteria: Review and Reuse an Imported Recording

## Story Context

As the [Conversation Reviewer][persona], I want to open a deliberately supplied
recording, check an important passage against its audio, correct the text and
speaker attribution, and later find and export that reviewed passage without
losing the source or repeating my review work.

This is a scoped test projection of the [whole-loop acceptance criteria][loop],
refining the [founding PRD][prd], particularly sections 5.3, 5.6, 9.9, 10.7,
12.4, and 18.3. It creates no replacement capability, format, or release
contract. [Import][import], [transcript][transcript], and [export][export] ADRs
and the [data-format authority][formats] govern their respective behavior.
The `IR-AC` identifiers distinguish these scenarios from the parent `AC` set.

The finish is one usable native review journey through inspected export
output. This document specifies expected behavior; **none of its scenarios
is marked passed by authoring it**. [H-001][hypothesis] and its [trial][trial]
separately evaluate review effort and voluntary reuse. Passing these criteria
does not establish customer preference, a competitive advantage, or release
readiness.

## Happy Path

### IR-AC-01: Open an imported conversation

**Given** capture is idle and the user has selected a supported local recording

**When** the user completes import using the default managed-copy behavior
and opens the resulting conversation

**Then** the conversation is identified as imported and provides playable retained
audio and its duration, without being represented as a live or recovered capture.

### IR-AC-02: Verify the intended passage

**Given** an imported conversation has a transcript and a target passage with
a known source-audio interval

**When** the user selects that passage for playback

**Then** playback seeks to that interval in that conversation's source audio,
so the known spoken passage can be heard.

### IR-AC-03: Save the user's correction

**Given** the selected Final transcript contains a phrase the user wants to correct

**When** the user enters replacement text and saves the edit

**Then** the saved reviewed passage displays exactly that replacement text as a human
correction, distinguishable from the original machine text.

### IR-AC-04: Confirm a passage's speaker

**Given** the target passage has an unresolved speaker and another passage
belongs to a different speaker

**When** the user explicitly assigns a named person to the target passage

**Then** that passage displays the assigned name as human attribution without
changing the other speaker's passage or claiming machine verification of identity.

### IR-AC-05: Reopen the reviewed record

**Given** the correction and speaker assignment were successfully saved

**When** the user closes the conversation, quits, relaunches, and opens it again

**Then** the same selected transcript, corrected text, and passage attribution
are available without entering the review work again.

### IR-AC-06: Find the correction again

**Given** the reopened selected Final transcript contains a distinctive corrected
term that occurs nowhere else in the library

**When** the user searches for that term and opens its result

**Then** the result opens the corrected passage in the correct conversation,
with playback linked to the same source interval checked in IR-AC-02.

### IR-AC-07: Export the reviewed text

**Given** a selected Final transcript contains the saved correction and confirmed
speaker attribution, and the chosen transcript format can represent that output

**When** the user exports to a selected local destination and opens the resulting file

**Then** its reviewed text and effective speaker labels match the selected
transcript, with the status and timing information required by that format.

### IR-AC-08: Retain evidence and correction provenance

**Given** the reviewed passage has original machine text, a human correction,
and a retained source-audio reference

**When** the user exports transcript JSON and inspects its evidence references

**Then** the output distinguishes the original text from the human correction
and resolves the passage to the same retained source and interval in the
originating library.

## Edge Cases

### IR-AC-09: Import the recording again

**Given** the library already contains a reviewed conversation from the selected file

**When** the user imports that file again

**Then** the existing conversation and its review work remain unchanged, with
either an existing-source warning or an explicitly separate new conversation.

### IR-AC-10: Review without a transcription model

**Given** retained audio is playable and no compatible local transcription
model is installed

**When** the user opens the conversation

**Then** playback and any already saved review remain usable, while new
transcription is shown as unavailable with the existing model-management action.

### IR-AC-11: Preserve review during replacement processing

**Given** a replacement transcription is running for a conversation with a
selected reviewed transcript

**When** the user saves a newer correction or speaker assignment before that
replacement finishes

**Then** the later processing result does not silently replace the user's
reviewed selection or discard the newly saved work.

## Error States

### IR-AC-12: Reject an unreadable import

**Given** a selected file is unsupported, corrupt, truncated, or no longer readable

**When** import validation fails

**Then** the user sees the specific failure and an applicable recovery or
supported-input instruction, without a conversation falsely shown as ready
or any change to the selected original.

### IR-AC-13: Keep review available after transcription fails

**Given** retained audio is playable and a transcription attempt fails or is cancelled

**When** the user returns to the conversation

**Then** the attempt is visibly failed or cancelled while playback and any
previously selected reviewed transcript remain available, with a recovery
action appropriate to the reported cause.

### IR-AC-14: Report a correction that could not be saved

**Given** a previous correction is saved and persistence is made unavailable
before the next correction is committed

**When** the user attempts to save the new correction

**Then** the app reports that it was not saved, retains the previously committed
review, and permits another save after the blocking condition is resolved.

### IR-AC-15: Refuse an unavailable or changed evidence source

**Given** a reviewed passage's retained audio is missing or fails its integrity check

**When** the user requests playback of that passage

**Then** the app reports that its source is unavailable or unverified and what
must be restored before playback, keeps the saved text readable, and does not
substitute another conversation or present the changed audio as verified evidence.

### IR-AC-16: Do not present an incomplete export as complete

**Given** the user has requested a local export

**When** the user cancels it or the destination cannot finish accepting the output

**Then** the app reports cancellation or the write failure with a recovery
action, leaves the reviewed conversation intact, and does not present partial
output as a completed export.

### IR-AC-17: Refuse a portable export that would lose attribution

**Given** the reviewed transcript has active passage-level assignments that
the selected portable format cannot represent

**When** the user requests that portable export

**Then** the app explains the unsupported attribution before creating or
replacing the package and leaves the review intact so the user can choose a
compatible transcript export without silently discarding assignments.

## Non-Functional Criteria

### IR-AC-18: Preserve an acknowledged save across interruption

**Given** the app has acknowledged a correction and speaker assignment as saved

**When** its process is interrupted and the same library is reopened

**Then** the last acknowledged review is present once, on the same passage and
selected transcript, without re-entry or manual library repair.

### IR-AC-19: Complete the journey with accessible controls

**Given** the user is operating a supported keyboard, VoiceOver, or display
configuration from the existing native accessibility matrix

**When** the user imports, plays, corrects, assigns a speaker, reopens, searches,
exports, and encounters the specified failures

**Then** every required action and state is reachable and perceivable with
labels, values, visible and logical focus, and signals that do not depend on
color alone, without clipped required content.

### IR-AC-20: Complete local review without network access

**Given** network access is denied, LLM features are disabled, and any model
needed to create the transcript is already installed and compatible

**When** the user completes the import, review, reopening, search, and export journey

**Then** the journey succeeds without an account, model download, or outbound
content request.

### IR-AC-21: Keep import and review within the selected scope

**Given** capture and context observation are inactive and the user has not
authorized remote processing

**When** the user imports and reviews the selected recording, including when
a model or other dependency is missing

**Then** the app does not start capture or context observation, request unrelated
capture permissions, or send the recording or transcript to a provider.

### IR-AC-22: Keep diagnostics free of conversation content

**Given** diagnostics are enabled for the review journey

**When** normal operations and the specified failures generate logs or copied
diagnostic details

**Then** those diagnostics contain no audio, transcript or correction text,
participant identities, credentials, or private path components.

### IR-AC-23: Preserve original recording bytes

**Given** the selected file's bytes are recorded before default managed-copy import

**When** import, review, replacement processing, and export succeed, fail, or are cancelled

**Then** the selected original remains byte-for-byte unchanged and every
successfully imported conversation retains a byte-identical managed copy of
that selected file through later operations, independently of derived audio
or transcripts.

## Notes

- **Test fixture:** use deliberately supplied non-private material in an
  isolated library. Record its digest, duration, known spoken intervals, and
  expected speaker assignments. Use at least two distinct speakers, a second
  conversation to expose wrong-source navigation, and a distinctive correction
  term absent from the original transcript and other records. Include a
  superseded term and a Draft-only term when checking default search; neither
  should be returned as selected Final text. Expected results are recorded
  before execution rather than inferred from the app's output.
- **Recognition boundary:** correction tests may start with a prepared
  transcript containing a deliberate error. That setup tests review behavior;
  it does not prove transcription quality or real local recognition. Any
  claimed import-to-transcript completion needs its corresponding native
  transcription proof.
- **Export coverage:** exercise each transcript format declared available for
  the candidate and state. Inspect the files, not only a success message.
  The [format owner][formats] defines contents and precision. Readable text,
  effective labels, and resolvable evidence do not imply transport of the
  editable identity history. IR-AC-17's honest refusal is a safety result,
  never a successful portable backup or a substitute for IR-AC-07/08.
- **Historical preservation gap:** at source revision `25c9d25`, the
  [native normalized-import path][normalized-import] passes a derived CAF and
  original-file metadata to the [store's normalized import][normalized-store],
  which retains the CAF rather than a copy of the source M4A. This is a
  source-inspection finding. The current native importer instead uses the
  original-preserving compressed path for M4A, and derives the required PCM
  only for transcription. Existing normalized imports remain playable but
  cannot export a missing original. The focused regression moves the selected
  M4A, reopens the library, compares exported original bytes, and checks the
  48 kHz companion. Its execution receipt is separate from this requirement;
  implementation alone does not mark IR-AC-23 accepted.
- **Execution evidence:** bind results to the exact candidate, library and
  fixture identities, operating system, relevant model, and selected export
  formats. Record actual outcome and supporting evidence for each scenario;
  keep missing execution, setup failure, and product failure distinct. Observe
  the connected journey as well as individual cases. A failed or unexecuted
  required step leaves this slice unqualified.
- **Existing gates:** native actions and accessibility require actual native
  execution on the supported matrix; source, component, or HTML prototype
  checks cannot close them. The existing no-app/test-host-launch restriction
  remains in force for this task. An allowed native-test environment is needed
  before those scenarios run. Full capture, long-session, integration, signing,
  and release obligations remain with their existing owners.
- **Open execution inputs:** the actual native candidate/environment, fixture
  identities, format coverage, and operator are not assigned by this draft.
  Existing owners set supported media/model limits and accessibility settings;
  this document introduces no new performance threshold. The [trial][trial]
  retains its own effort and return-use thresholds and scheduling.

### Traceability to the existing contract

| Scoped criteria | Governing requirements |
| --- | --- |
| IR-AC-01, 09, 12, 23 | [Whole-loop AC-8, 17, 27][loop]; [ADR 0007 import][import] |
| IR-AC-02, 06 | [Whole-loop AC-9, 11][loop]; [ADR 0009 timeline and search][transcript] |
| IR-AC-03, 04, 05, 11, 14, 18 | [Whole-loop AC-7, 10, 19][loop]; PRD 12.4; [ADR 0009 correction and selection][transcript]; [current review semantics][formats] |
| IR-AC-07, 08, 16, 17 | [Whole-loop AC-13][loop]; [ADR 0010][export]; [current format support and refusal][formats] |
| IR-AC-10, 13, 15 | [Whole-loop AC-18, 25][loop]; [ADR 0007 playback][import]; [ADR 0009 availability][transcript]; [media integrity authority][formats] |
| IR-AC-19, 20, 21, 22 | [Whole-loop AC-29, 31, 32, 33][loop]; [capture and local-first anchors][anchors] |

[persona]: PERSONA_PU_001.md
[loop]: FIRST_CLASS_ACCEPTANCE_CRITERIA.md
[prd]: FOUNDING_PRD.md
[anchors]: ../../ANCHOR.md
[import]: ../architecture/0007-platform-permissions-playback-and-import.md
[transcript]: ../architecture/0009-transcript-diarization-and-timeline.md
[export]: ../architecture/0010-export-and-portable-evidence-schema.md
[formats]: ../data-format/README.md
[hypothesis]: experiments/2026-10-22-reviewed-conversation-hypothesis.md
[trial]: experiments/2026-10-16-reviewed-conversation-validation.md
[normalized-import]: ../../apps/macos/Sources/OpenScribeApp/Stores/RuntimeLibraryStore.swift
[normalized-store]: ../../crates/open-scribe-store/src/import.rs
