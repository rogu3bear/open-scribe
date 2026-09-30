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

- [`open-scribe.evidence-ref/v1`](../../crates/open-scribe-evidence/src/lib.rs) — evidence reference and its validation (ADR 0013).
- [`transcript.v1.schema.json`](transcript.v1.schema.json) — `open-scribe.transcript/v1` JSON export; the core exporter takes its schema identity from this file. Plain text, Markdown, WebVTT, and SubRip exports render the same selected Final revisions.
- Store migrations 6 and 7 — append-only transcript corrections and speaker names, the FTS5 search projection, and deletion intents, tombstones, and receipts.

Audio exports, the session manifest, and the `.openscribe` portable package remain intended.

No format may be called stable before round-trip fixtures, migration tests, path-safety tests, and recovery behavior are implemented.
