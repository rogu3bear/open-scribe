# Data Format Authority

Session/source types already exist in [open-scribe-types](../../crates/open-scribe-types/src/lib.rs). The [Rust store](../../crates/open-scribe-store/src/lib.rs) owns the current SQLite schema, migrations, journal, media integrity, recovery, and imported CAF/M4A records; its [timeline module](../../crates/open-scribe-store/src/timeline.rs) owns capture-clock mapping and playback plans. [ADR 0006](../architecture/0006-persistence-recovery-and-storage.md) supplies the governing persistence decision.

This directory remains the documentation owner for versioned specifications of:

- session and evidence identifiers;
- append-oriented lifecycle, transcript, context, model-run, adjudication, and recovery events;
- SQLite schema and migrations;
- export formats and the `.openscribe` portable package;
- compatibility, deletion, and retention behavior.

Rust types and schemas are canonical. Swift views, website demo fixtures, SQLite projections, and exports must be derived consumers rather than independently edited definitions.

Current, not yet stable:

- [`open-scribe.evidence-ref/v1`](../../crates/open-scribe-evidence/src/lib.rs) — evidence reference and its validation (ADR 0013). The store derives references for transcript segments, human corrections, audio ranges, markers, and context events, and resolves each to exactly one ADR 0013 state ([evidence_resolution.rs](../../crates/open-scribe-store/src/evidence_resolution.rs)); an audio range rehashes the sealed file. A transcript segment reference names its revision as both `record_id` and `revision_id`, so the references `transcript.json` exports resolve in the library that wrote them.
- [`transcript.v1.schema.json`](transcript.v1.schema.json) — `open-scribe.transcript/v1` JSON export; the core exporter takes its schema identity from this file. Plain text, Markdown, WebVTT, and SubRip exports render the same selected Final revisions.
- Store migrations 6 and 7 — append-only transcript corrections and speaker names, the FTS5 search projection, and deletion intents, tombstones, and receipts.
- Store migration 8 — context scope epochs, append-only accepted context events, and declared participants and topic. Every change is journaled first. The scope receipt is `open-scribe.context-scope/v1` ([context.rs](../../crates/open-scribe-store/src/context.rs)). The event is `open-scribe.context-event/v1` ([context_events.rs](../../crates/open-scribe-store/src/context_events.rs)): reduced text blocks with boxes in thousandths, a semantic hash, the prior event's digest, and `retention: no_pixels`. It contains no pixels or pointer samples. Context events are not yet part of exports or the portable package.
- [`session-manifest.v1.schema.json`](session-manifest.v1.schema.json) — `open-scribe.session-manifest/v1`: session identity, each sealed media file's placement, length, and SHA-256, markers, and the selected transcript revisions.
- [`portable.v1.schema.json`](portable.v1.schema.json) — `manifest.json` of a `<name>.openscribe` package directory: every file's role, media type, length, and SHA-256. The core writer stages, verifies, then renames the package; its verifier rejects unsafe or duplicate paths, links, undeclared files, digest or length mismatches, and unsupported versions.
- Audio exports: the validated AAC mix, a lossless WAV mix rendered from the validated timeline, timeline-aligned WAV per PCM track, and an import's managed original. Media leaves only through leases whose full bytes match their sealed digest.
- Store migration 9 — `session_restorations`: opening a portable package ([package_import.rs](../../crates/open-scribe-core/src/package_import.rs), [package_restore.rs](../../crates/open-scribe-store/src/package_restore.rs)) verifies it, binds `session.json` and `transcript.json` to the manifest digests, then restores it as a new local session that keeps the source session ID and manifest digest as provenance. Each media file is rehashed as it is copied and checked for length, sample count, and channels; every placement is journaled before it is projected. A restored capture plays from those journaled placements, never a synthesized capture clock. A selected Final revision is restored only when its input digest, recomputed from the package's own identities, names exactly those media bytes; corrections, speaker names, and markers come with it. A restore that does not finish is removed and leaves a deletion tombstone. Re-export preserves the semantic timeline, media digests, verbatim and corrected text, finality, markers, and speaker names under the new identities. A package holding a compressed M4A import cannot be opened yet, and a failed transcription restores as pending.

No format may be called stable before round-trip fixtures, migration tests, path-safety tests, and recovery behavior are implemented.
