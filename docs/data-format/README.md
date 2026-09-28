# Data Format Authority

Session/source types already exist in [open-scribe-types](../../crates/open-scribe-types/src/lib.rs). The [Rust store](../../crates/open-scribe-store/src/lib.rs) owns the current SQLite schema, migrations, journal, media integrity, recovery, and imported CAF/M4A records; its [timeline module](../../crates/open-scribe-store/src/timeline.rs) owns capture-clock mapping and playback plans. [ADR 0006](../architecture/0006-persistence-recovery-and-storage.md) supplies the governing persistence decision.

This directory remains the documentation owner for versioned specifications of:

- session and evidence identifiers;
- append-oriented lifecycle, transcript, context, model-run, adjudication, and recovery events;
- SQLite schema and migrations;
- export formats and the `.openscribe` portable package;
- compatibility, deletion, and retention behavior.

Rust types and schemas are canonical. Swift views, website demo fixtures, SQLite projections, and intended exports must be derived consumers rather than independently edited definitions. Public export formats and the portable package remain intended; current storage records do not establish their implementation or compatibility.

No format may be called stable before round-trip fixtures, migration tests, path-safety tests, and recovery behavior are implemented.
