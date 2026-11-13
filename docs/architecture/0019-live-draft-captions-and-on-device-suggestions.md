# ADR 0019 — Live Draft Captions and On-Device Suggestions

- Status: Proposed. Implemented in the working tree on `task/open-scribe-trusted-review` for operator review; not accepted until the operator approves it.
- Date: 2026-11-12
- Owner/approver: repository operator. The request was "I'd love to see things transcribed as they're happening" and, for titles, "You can even use Apple Intelligence." Approval of this record is still pending.
- Founding clauses refined: PRD 2.5–2.6 and 12 (provisional transcription during capture), 15.1–15.3 (local interpretation), 18.1 (naming); ADR 0008 (local ASR engine); ADR 0014 (local provider scope)
- Supersedes: ADR 0008 only by adding a second engine, used for Draft windows alone. whisper.cpp remains the only engine for Final transcripts.

## Context and evidence

Before this change, a conversation had no text until it was saved, a model was installed, and the queue reached it. Library titles were capture timestamps. On this Mac (macOS 26.2, Apple silicon), Apple's `SpeechAnalyzer` with `SpeechTranscriber` transcribed a file at about 89× real time. Its streaming mode returned settled phrases with word time ranges and finished in about 0.05 s. The work used probes in the session scratchpad, not repository receipts. `FoundationModels` provides an on-device `SystemLanguageModel` with guided generation.

The store already accepted Draft windows during capture (`commit_live_draft_window`): one track, at most 12 s, and only while the session and track are capturing. Those windows had no producer.

## Decision

### Live Draft captions

- On macOS 26 or later, each capture span runs one `SpeechTranscriber` per required source: the microphone as "You", computer audio as "Others". It starts after capture starts and never gates it. On macOS 13–25, or when the language has no installed asset, captions report Unavailable and capture continues unchanged.
- Audio reaches the transcriber only after the CAF writer accepts it. The adapter delivers a copy through `LiveAudioListenerSlot`, and conversion runs on the transcriber's own queue. A recognizer failure ends captions for the span; it never touches capture, the journal, or recovery.
- Settled phrases become Draft windows through the existing store path. Each window is at most 11.5 s and carries engine `apple-speech-transcriber`, reconciliation `live-captions-1`, and a SHA-256 identity of the locale and preset. Volatile text is shown and never stored.
- Stop and Pause settle the last phrase and wait at most 2 s for its windows **before** the recorder records the pause or seals. That is the only time the tracks still accept Draft text.
- Only already-installed speech assets are used. Open Scribe never triggers an asset download. A person can turn the live transcript off in Settings.
- Final transcription is unchanged: whisper.cpp under ADR 0008, verified models, and the scheduler. Final text replaces Draft text through the existing selection rules.

### Suggested titles and names

- Titles: migration 21 adds `conversation_titles` (`named_by_person`, `suggested_title`, engine, `draft|final` basis). A suggestion is stored only while the title is still a capture placeholder and no person has named the conversation. A suggestion based on a Final transcript is never replaced by one based on a Draft. Any rename through `rename_session` sets `named_by_person`. Display, search, and export read the resolved title. The stored `sessions.title` is never rewritten by a suggestion.
- Engine: `SystemLanguageModel.default` only, on-device, with `@Generable` output, and only when it is available. The transcript excerpt is wrapped as quoted material in instructions that forbid following it, and the output schema has no tools. Names are kept only if they occur in the transcript. Without Apple Intelligence, a deterministic fallback uses `NLTagger` person names. Private Cloud Compute and remote providers are not used. ADR 0014's remote content-scope rules are unchanged.
- Names are suggestions in memory only. Applying one ("Others sounds like Dana. Use “Dana”") goes through the existing speaker-rename path, as a person's choice.

### Copy

- `conversation_text` (Rust core) renders turns merged by speaker in timeline order, with optional `[m:ss]` stamps, from the readable document: selected Final text plus Draft text no selected Final range covers. Swift adds the local-date heading and, when any copied text is Draft, a Draft notice. File exports stay Final-only. Copy So Far renders the same way from the Draft windows stored so far.

## Consequences

- Draft text now exists for recordings made on macOS 26 with installed speech assets, so Copy, search, and suggestions work before a whisper model is installed. It is labelled Draft everywhere it appears.
- The binary links `Speech` and `FoundationModels` weakly (`LC_LOAD_WEAK_DYLIB`, checked with `otool -l`). Earlier macOS versions launch without them.
- Proof launches (`suspendsAutomation`) and hosted tests use an inert suggestion model, so no language model runs inside them.

## Proof status

- Source and focused tests: Rust store/core suites green on 2026-11-12, including title-resolution and conversation-text tests.
- Not yet proven: the hosted Swift suites against the redesigned window, a live capture with captions on an attended Mac, a long session's caption backlog, and a signed or installed artifact. None is claimed.
