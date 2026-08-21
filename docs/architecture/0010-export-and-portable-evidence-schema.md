# ADR 0010 — Export and Portable Evidence Schema

- Status: Accepted for Milestone 2 implementation
- Date: 2026-08-20
- Owner/approver: repository operator, through the explicit Milestone 2 Evidence Ledger instruction
- Founding clauses refined: PRD 3.5, 10, 17, 18.3–18.5, 21.3–21.4, 31 Milestone 2, and 39
- Supersedes: nothing

## Context and evidence

The Evidence Ledger becomes useful only when ordinary playback, text, subtitles, structured data, and a portable session preserve the same timeline and provenance. Export formats must not confuse Draft with Final, tidy text with verbatim evidence, or a speaker cluster with a verified person.

## Decision

### Version authorities

- `docs/data-format/` will own checked JSON Schemas and examples. Schema identifiers are stable URIs under `https://open-scribe.app/schema/`; implementation constants and exporters derive from the checked version registry rather than duplicating numbers.
- Initial schemas are `open-scribe.transcript/v1`, `open-scribe.session-manifest/v1`, and `open-scribe.portable/v1`. Additive optional fields may retain a major version; changed meaning, removed required fields, or incompatible timestamp semantics require a new major version.
- Every structured export includes schema ID/version, exporter version, session ID, export time, timeline unit (`nanoseconds`), source media digests, transcript/model-run IDs, finality, and correction/adjudication provenance.

### Export families

- Audio: validated M4A mix by default; WAV lossless mix; optional selected source-track CAF/WAV. Never export an unsealed active segment as complete audio.
- Text: UTF-8 plain text and Markdown. Header states Draft/Final/Failed/Unavailable, model identity when applicable, duration, and whether speaker names are declared, user-adjudicated, or anonymous.
- Subtitles: WebVTT and SubRip. Cue ranges derive from authoritative session nanoseconds, are ordered/nonnegative, split to format constraints, and never imply precision unavailable from the transcript. Speaker prefix is included only when a stable assignment exists.
- JSON: transcript v1 contains immutable verbatim segments, optional tidy text, effective human correction, session range, track/source reference, speaker assignment and provenance, finality, language, confidence diagnostics when meaningful, model run, and evidence IDs.
- Portable: a macOS package directory `<name>.openscribe` using portable v1. It contains `manifest.json`, copied media, transcript JSON, evidence/marker/source events, license/provenance records, and user-requested normal exports. Context and future derived memory are included only when present and explicitly selected.

### Portable integrity and round-trip

- Manifest paths are relative, normalized, unique, and may not escape the package. Every included file has byte length, SHA-256, media type, role, and source record.
- Export writes to a sibling staging package, synchronizes files/directories, validates schema and digests, then atomically replaces/moves the destination. Cancellation or failure leaves no apparently complete package.
- Import treats the package as untrusted: reject absolute/traversal/symlink/device paths, duplicate normalized paths, undeclared files when strict mode applies, oversized entries, digest mismatch, unsupported schema, and decompression bombs if zip support is added later.
- Round-trip creates a new local session ID while preserving the portable source session ID/provenance. Re-export must preserve semantic timeline, media digests, verbatim transcript, finality, markers, speaker adjudications, and schema meaning; byte-identical packaging is not required.

### State and authority

- Export never promotes state. Draft export remains labeled Draft; Failed/Unavailable exports may contain media and explicit transcript status but no invented transcript.
- Final transcript export selects one explicit Final revision. Superseded Drafts and model diagnostics are omitted from ordinary exports and optionally included in a technical provenance bundle.
- User corrections and speaker renames are exported as adjudications alongside the immutable machine output, not flattened into an unexplained replacement.
- Media-only export remains available when transcription is disabled or failed. Export queues run below capture priority and never hold the SQLite writer or media-writer locks.

## Alternatives

An app-specific binary archive hides provenance and limits recovery. A zip without a manifest cannot prove completeness. Flattening effective text loses verbatim and correction history. Reusing one mutable “v1” string for incompatible meanings defeats round-trip guarantees. Blocking media export on transcript status violates reliability-before-intelligence.

## Security and privacy

Export is an explicit user action to a user-selected destination. The UI previews included content categories and warns that portable packages contain conversation media. No provider or cloud upload is implied. Export filenames are sanitized display conveniences; manifest identity never depends on them.

## Migration and rollback

Readers support every released major schema or fail with a clear unsupported-version receipt. Writers emit only the current version unless a tested compatibility exporter is explicitly selected. Schema migration creates a new package/session and preserves the original. Rollback retains old readers and disables newer writers; it never rewrites an existing portable package in place.

## Proof

Acceptance requires schema validation and semantic round-trip for every export family; exact cue/timeline comparison; Draft/Final/Failed/Unavailable fixtures; correction and speaker-rename preservation; media-only export with transcription disabled/failed; cancellation, disk-full, destination replacement, malformed package, traversal, symlink, duplicate path, digest mismatch, unsupported version, and oversized-entry tests; and import/re-export of a two-hour recovered multi-track session. Unit tests are necessary but portable package acceptance also requires opening audio/subtitles in independent standard applications.
