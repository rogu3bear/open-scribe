# ADR 0013 — Evidence Lineage, Derived Claims, and Adjudication

- Status: Accepted for Milestone 4 implementation
- Date: 2026-08-20
- Owner/approver: repository operator, through the explicit Milestone 4 Intelligence-as-Annotation instruction
- Founding clauses refined: PRD 2.3–2.4, 10, 12.3–12.4, 14, 15.2–15.6, 16, 17.4–17.9, 18, 21.3–21.4, 29.6, 31 Milestone 4, 33.4–33.5, and 39; DESIGN sections 5, 11–12, and 14
- Supersedes: nothing

## Context and evidence

Intelligence is useful only when it remains an annotation over durable evidence. A fluent decision without a resolvable source, an owner inferred from proximity, or a reprocessing pass that erases a human rejection would turn model output into competing truth. The data model therefore needs immutable evidence lineage, typed claim semantics, append-only adjudication, and deterministic validation before any proposal enters canonical meeting memory.

## Decision

### Versioned evidence references

- `open-scribe-evidence` owns the WASM-safe `open-scribe.evidence-ref/v1` schema and deterministic validation. Native Rust resolves references through the media ledger, transcript/context revisions, and SQLite; Swift and the website consume resolved navigation projections but never reinterpret reference identity.
- An `EvidenceRef` contains schema version, session ID, evidence kind, stable evidence record ID, immutable revision ID where applicable, half-open session range `[start_ns, end_ns)`, optional bounded sub-item ID, content digest, and resolver-state hint. The stored identity never depends on display text, a mutable row number, or a filesystem path.
- Transcript references bind an exact transcript revision/finality, segment IDs, and a range inside verified media coverage. Final evidence citations prefer Final verbatim or human-corrected effective text. A Draft reference stays visibly Draft and may not silently retarget when Final text replaces that range.
- Context references bind an accepted context event, its scope epoch, reducer revision, semantic digest, observation range, and optional text-block ID. They cite reduced text/layout or an explicitly retained snapshot reference, never a discarded frame.
- Audio/video ranges resolve through the M1 segment ledger. Markers, participant declarations, human corrections, source transitions, notes, and imported-document references bind their immutable event/revision records.
- Resolution returns exactly `Available`, `Superseded`, `Missing`, `Deleted`, `IntegrityMismatch`, or `UnsupportedVersion`. Superseded evidence may navigate to its preserved revision and disclose the newer revision; missing or deleted evidence is never silently substituted.

### Derived-claim schema

- `open-scribe-evidence` also owns `open-scribe.derived-claim/v1`. A claim contains stable claim and revision IDs, session ID, kind, text, typed status, optional owner/due date only when supported, supporting and contradicting `EvidenceRef`s, producer (`Human` or `ModelRun`), confidence/uncertainty, creation/update time, lineage key, validation revision, and effective adjudication ID.
- Claim kinds are `Fact`, `Decision`, `Commitment`, `Question`, `OpenLoop`, `LooseEnd`, `Topic`, `NumberOrTerm`, and `SummaryStatement`. Status is kind-aware: for example, Mentioned or Proposed never validates as Agreed; a nearby name never validates as Assigned; Unknown never becomes False; and Completed requires later resolving evidence.
- A material claim is any item that says what happened, was agreed, is owed, remains unresolved, attributes a person/date/number, or appears as a factual summary sentence. Every material claim requires at least one available supporting reference. Unsupported model material is rejected from canonical meeting memory and counted in the run receipt. An explicitly human-authored draft may exist in a separate review queue as `Unsupported — needs evidence`; it never appears as settled memory.
- Contradicting references are independent of support. A supported claim with material contrary evidence becomes `Contradicted` or remains `Unresolved`; the UI shows both sides. Contradiction is not resolved by confidence score or by selecting the newest model output.

### Decisions, commitments, open loops, and Loose Ends

- A Decision advances only through evidence-backed Mentioned → Proposed → Agreed, with Contradicted/Superseded/Unknown as explicit alternatives. Silence after a proposal is not agreement.
- A Commitment distinguishes Mentioned, Proposed, Assigned, Accepted, Completed, Contradicted, Unresolved, and Unknown. Owner and due date are separate evidence-backed fields; grammatical proximity is insufficient attribution.
- An Open Loop records the initiating question/issue, first evidence, relevant later evidence, current Open/Answered/Closed/Contradicted/Unknown status, and its last resolution search.
- A Loose End is a versioned derived item proving that material evidence was introduced and that a bounded search of later evidence found no resolution. It contains why the item matters, first evidence, searched evidence range/revisions, relevant later evidence, resolution-search algorithm/run, status, and uncertainty. It never says a person forgot something.

### Proposed deltas and validation

- A model returns `open-scribe.meeting-memory-delta/v1`, never database mutations. Operations are limited to proposing a claim, a new claim revision, status/evidence/relation changes, a resolution-search result, or supersession. There is no evidence-write, evidence-delete, arbitrary SQL, tool, filesystem, network, or generic patch operation.
- Every delta names its model run, input-manifest digest, schema version, and expected base meeting-memory revision. Rust rejects oversized/deep payloads, unknown fields, stale bases, duplicate operation IDs, invalid enums/transitions, fabricated or unauthorized references, digest/range mismatch, cross-session references, unsupported material claims, and attempts to alter human adjudications or evidence.
- Rust derives persistent IDs and lineage keys; providers do not choose storage keys. A transaction first stores the immutable model proposal/validation result, then appends only accepted claim revisions and evidence links, and finally advances the meeting-memory projection. Partial acceptance is explicit per operation and fully receipted.
- Models cannot delete. Deduplication and supersession preserve lineage. Deleting model-derived state follows claim-to-run ownership and has no cascading foreign key from claims into evidence.

### Human correction and adjudication

- Human actions append `Accepted`, `Corrected`, `Rejected`, or `Unresolved` adjudication events against an exact claim revision. Correction stores the replacement fields and evidence links alongside, not over, the original model proposal.
- Effective meeting memory applies the latest valid human adjudication above model revisions. Reprocessing creates a new model run and new proposals; it cannot overwrite, resurrect, or silently bypass accepted/corrected/rejected state.
- Rust carries adjudication forward only when the stable claim lineage and cited evidence revisions still match. A changed evidence set or contradictory replacement produces an adjudication conflict for human review. A prior rejection suppresses an identical lineage proposal while retaining the new run receipt.
- “Delete Model Results” removes unadjudicated model claims, raw model outputs, and regenerable model caches without deleting audio, transcripts, context, markers, declarations, corrections, or other evidence. Accepted/corrected human state becomes human-owned memory with its evidence links; rejected-state retention follows the user's chosen history/privacy deletion scope.

### Evidence navigation and disabled state

- Every material interpretation item exposes its kind, textual status, Evidence count, Contradictions count when nonzero, producer/run, and human state. Selecting a reference seeks audio, highlights the exact transcript revision/range, reveals the context event/snapshot, or opens the source/receipt inspector. A return action restores focus to the originating claim.
- Wide layouts may show claim and evidence side by side; narrow layouts use the same ordered navigation with a return path. VoiceOver reads claim kind, status, support/contradiction availability, and adjudication before actions. Color is never the only status cue.
- With intelligence Disabled, the Interpretation section is absent or truthfully `Intelligence off`; playback, transcript, context review, search, markers, evidence navigation, correction, and export remain complete. The empty state is not an upsell and creates no fake decisions or Loose Ends.

## Alternatives

Free-form summaries cannot be validated sentence by sentence. Mutable foreign keys silently retarget evidence after reprocessing. One universal status collapses proposal, agreement, assignment, and completion. Letting models upsert rows bypasses policy and human history. Treating Loose Ends as tasks invents intent. Flattening adjudication into corrected prose destroys the distinction between observation, model interpretation, and human judgment.

## Consequences

Meeting memory uses more small immutable records and explicit projections, and navigation must handle unavailable historical revisions. Model output may be partially or wholly rejected even when syntactically valid. This costs storage and implementation complexity but makes every effective claim explainable, removable, and reprocessable without weakening evidence.

## Security and privacy

Evidence text and derived claims remain sensitive local session data. Resolvers accept typed IDs and ranges, never provider paths or URLs. Content-free logs may include IDs, counts, timings, and rejection codes but never transcripts, OCR, prompts, claims, or human corrections. Deletion operates from user-visible ownership categories rather than cascading from model state into evidence.

## Migration and rollback

Evidence-ref, claim, delta, validator, and adjudication schemas version independently. Readers preserve old immutable revisions and fail explicitly on unsupported versions. Migration builds new projections from events without rewriting evidence. Rollback selects the prior projection/validator and disables incompatible intelligence; it never retargets a reference or discards a human adjudication.

## Proof

Acceptance requires fixtures for every evidence kind/resolver state, range boundary, claim kind/status, contradiction, unsupported item, and adjudication. Every rendered material item must navigate to its exact supporting or contradicting media/transcript/context artifact and return focus correctly. Draft-to-Final replacement, transcript/context reprocessing, missing/deleted evidence, model reruns, identical rejected proposals, changed evidence conflicts, and app restart must preserve reference and human-state truth.

Deleting all model-derived state must leave media, transcript, context, markers, corrections, playback, search, and evidence exports byte/digest intact. A full network-denied run with intelligence Disabled must prove the application remains useful through recording, recovery, playback, transcript/context review, correction, search, and export. Unit tests are necessary but do not replace real navigation, accessibility, reprocessing, deletion, and independent artifact inspection.
