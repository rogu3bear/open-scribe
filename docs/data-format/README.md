# Data Format Authority

No session, database, event, export, or portable-archive schema exists yet.

Before implementation, this directory will own versioned specifications for:

- session and evidence identifiers;
- append-oriented lifecycle, transcript, context, model-run, adjudication, and recovery events;
- SQLite schema and migrations;
- export formats and the `.openscribe` portable package;
- compatibility, deletion, and retention behavior.

Rust types and schemas will be canonical. Swift views, website demo fixtures, SQLite projections, and exports must be derived consumers rather than independently edited definitions.

No format may be called stable before round-trip fixtures, migration tests, path-safety tests, and recovery behavior are implemented.
