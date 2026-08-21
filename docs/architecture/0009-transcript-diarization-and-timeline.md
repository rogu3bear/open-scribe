# ADR 0009 — Transcript, Diarization, and Timeline Semantics

- Status: Accepted for Milestone 2 implementation
- Date: 2026-08-20
- Owner/approver: repository operator, through the explicit Milestone 2 Evidence Ledger instruction
- Founding clauses refined: PRD 2.3–2.6, 10, 12–13, 17.2–17.4, 18.2, 21.3–21.4, 31 Milestone 2, and 39
- Supersedes: nothing

## Context and evidence

A transcript is derived evidence over immutable media. Provisional text can be useful during capture but is lossy, revisable, and expendable. Final text must restart after interruption, align with the session timeline, preserve verbatim output and human corrections, and never make recording depend on inference. Diarization assigns anonymous voice clusters, not human identities.

## Decision

### Timeline authority

- The M1 Rust segment ledger and signed session nanoseconds are the sole transcript/audio timeline authority. Media sample/frame counts and segment mappings outrank ASR timestamps.
- ASR/VAD timestamps are derived observations mapped into session ranges, clamped to verified media bounds, and rejected when inverted or materially outside input coverage. Click-to-seek always resolves through the media segment ledger.
- Waveform tiles are derived from sealed media at fixed session-time buckets and carry source digest plus algorithm version. They may be regenerated and never become evidence authority.

### Final transcription and checkpoints

- Final transcription runs after source media is sealed and readable. Prefer per-source authoritative tracks: known microphone topology can map to the declared local participant; selected application/system tracks remain remote/unknown and are diarized only where needed. Single-track/import sessions use that track directly.
- Decode/resample to 16 kHz mono for inference without modifying source media. Use Whisper’s 30-second context as the maximum model window, VAD-aligned chunks targeting 20–28 seconds, and 5 seconds of overlap.
- Each chunk has a deterministic ID from session, track digest, model artifact hash, engine version, options hash, and session range. Persist `pending/running/complete/failed`, raw hypothesis, tokens/segments where available, language, timestamps, confidence diagnostics, and reconciliation version.
- Commit after every chunk. Restart skips only complete chunks whose full identity still matches. A changed model/media/options creates a new model run and never reuses incompatible checkpoints.
- Reconciliation removes overlap duplicates using timestamp/text agreement, records discontinuities, and creates immutable verbatim transcript revisions. Tidy text is separately derived. Human correction is a later adjudication layer and never overwrites verbatim output.

### Bounded provisional transcript

- Provisional transcription is optional and explicitly `Draft`. A single-producer/single-consumer native PCM ring receives a copy after the media writer accepts the same audio; it is not part of media durability.
- Process VAD-bounded windows up to 12 seconds with 2-second overlap. Queue at most two windows per active source. If the consumer falls behind, discard oldest provisional windows and persist/announce a Draft gap; never block or slow capture.
- Do not repeatedly transcribe the growing file. Provisional chunks are append/correct operations within a bounded trailing range.
- Final results never mutate Draft rows into Final. A contiguous final range is inserted atomically and then marks overlapping Draft rows `superseded`. UI swaps that range as one transaction and labels any remaining Draft range. Draft text never supports final evidence citations when Final exists.
- Routine provisional tokens, corrections, and dropped windows produce no accessibility announcements.

### Transcript states and progress

- Transcript availability is exactly `Unavailable`, `Draft`, `Final`, or `Failed`. `Unavailable` includes disabled/no compatible model. `Failed` retains media and a retry action. A session may contain Final ranges plus explicitly Draft/pending ranges while batch work continues; the document’s aggregate state is Draft until all required ranges are Final.
- Background progress is completed verified media duration divided by required media duration, plus explicit stages (`decoding`, `transcribing`, `reconciling`, `diarizing`, `indexing`). Never estimate capture durability from inference progress.
- Canceling, failing, or disabling transcription stops derived work only. Recording, recovery, playback, markers, and exports of media remain available.

### VAD and diarization

- Silero VAD ONNX is the speech-boundary authority for the selected model revision. Resample to 16 kHz mono. Persist threshold, minimum speech/silence, padding, model hash, and algorithm version with each run.
- Diarize only topology-unknown speech. Known source identity is applied before embeddings and clustering; never use clustering to rediscover microphone-versus-application distinction.
- For unknown speech, create 1.5-second speech windows with 0.75-second stride, excluding windows with insufficient voiced duration. WeSpeaker ECAPA512 ONNX produces L2-normalized embeddings.
- Use deterministic agglomerative hierarchical clustering with cosine distance, bounded to 1–8 speakers. Merge short phantom clusters into the nearest sufficiently supported neighbor only when the calibrated margin permits; otherwise keep `Unknown speaker` rather than force certainty.
- No universal numeric clustering threshold is accepted in prose. Threshold, single-speaker detector, short-cluster rule, overlap policy, and confidence calibration are versioned artifacts selected by a reproducible labeled evaluation corpus spanning microphones, applications, noise, accents, overlap, and the supported hardware matrix. A model version is Unavailable until its calibration artifact meets recorded false-split/false-merge gates.
- Speaker labels are stable anonymous identities (`Speaker 1`, etc.). Rename creates a Rust adjudication event mapping cluster/turns to a participant ID. Re-diarization preserves adjudications where evidence ranges still match and surfaces conflicts; it never silently reassigns a human name.

### Search and document behavior

- SQLite FTS5 indexes Final effective text: human correction when present, otherwise verbatim. Draft is excluded from default search and visibly scoped when explicitly searched.
- Search hits retain transcript revision and session ranges. Selecting a hit seeks through the authoritative media timeline.
- The transcript document shows timestamp, speaker, effective text, finality, correction provenance, and playback linkage without exposing model-token detail by default.

## Alternatives

One batch job without checkpoints makes long sessions restart from zero. Mutating Draft into Final erases replacement provenance. ASR timestamps as authority allow text to drift away from media. Whole-mix-only transcription discards known topology. Python diarization violates architecture. Fixed folklore clustering thresholds create confident but uncalibrated speaker claims.

## Security and privacy

All inference is local. PCM rings are bounded process memory and zeroed/released after consumption. Checkpoints contain transcript content and stay in managed local storage under session deletion rules. Logs and telemetry contain IDs, durations, state, and bounded diagnostics—not transcript text or embeddings. Voice embeddings are sensitive derived data and are deleted with their session/model run unless the user explicitly enrolls a future identity feature.

## Migration and rollback

Transcript, VAD, embedding, clustering, reconciliation, and waveform algorithms are separately versioned. New runs create new revisions; old Final text remains readable until the replacement is complete and selected. Rollback selects the prior compatible run or Unavailable; it never rewrites media or human adjudications.

## Proof

Acceptance requires network-denied final transcription; two-hour checkpoint/restart at every chunk stage; model failure/removal/disablement while recording; provisional overload proving capture remains unaffected; atomic Draft-to-Final range replacement; transcript/playback and waveform alignment across segments, pause, source changes, gaps, and recovered media; VAD/diarization regression fixtures; single/multi-speaker and phantom-cluster calibration reports; speaker rename persistence through restart/re-diarization; FTS hit-to-audio seeking; and accessible rendered states for Unavailable, Draft, Final, and Failed. Unit tests alone cannot accept this ADR.
