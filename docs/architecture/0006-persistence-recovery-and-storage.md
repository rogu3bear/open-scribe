# ADR 0006 — Persistence, Recovery, and Managed Storage

- Status: Accepted for Milestone 1 implementation
- Date: 2026-08-20
- Owner/approver: repository operator, through the explicit Milestone 1 reliable-recorder instruction
- Founding clauses refined: PRD 7.3–7.7, 9.2, 9.8, 11.5–11.6, 18, 21.3–21.4, 31 Milestone 1, 33.1, and 39
- Supersedes: no founding invariant

## Context and evidence

SQLite and media files cannot participate in one physical atomic transaction. Open Scribe therefore needs a recoverable intent protocol whose intermediate states are explicit. The per-session journal must survive independently of the database, and the database must be rebuildable enough to locate and reconcile media. Current SQLite documentation also records a WAL-reset race affecting many SQLite versions when multiple connections write/checkpoint concurrently; the first implementation avoids that condition with one serialized writer connection.

## Decision

### Authorities and schema

- Rust `open-scribe-store` owns one SQLite database and all structured writes. Use WAL, `synchronous=FULL`, foreign keys, a busy timeout, and one serialized writer connection. UI reads use short transactions; no second connection may write or checkpoint.
- Schema v1 contains `sessions`, `sources`, `tracks`, `segments`, `session_events`, `markers`, `imports`, `deletion_receipts`, and `schema_migrations`.
- Primary keys are opaque UUIDv7 values. Every row carries a schema version where external interpretation may outlive the app.
- `session_events` is append-oriented with per-session monotonically increasing sequence, event kind, session nanoseconds, wall time, typed JSON payload, and prior-event digest. Materialized session/source status is derived and updated in the same SQLite transaction as its event.
- `segments` records relative path, source/track, sequence, lifecycle, original/mapped timestamps, format, sample count, byte length, digest, and seal/recovery state. SQLite never stores media bytes.

### Recovery journal

- Every session directory contains `recovery.jsonl`. Each line is a versioned, length-bounded record with sequence, event kind, identifiers, relative path only, timestamps, payload, prior digest, and record digest.
- Rust is the only journal semantic authority. Swift requests coarse appends through UniFFI before/after media operations; the call completes only after append and file synchronization.
- Never log transcript, OCR, media, secrets, absolute home paths, or unbounded framework errors.

### Logical atomic creation

1. Rust allocates the session ID and commits a `preparing` session plus `session_create_intent` in SQLite.
2. Rust creates the session directory and journal using create-new semantics, appends `session_directory_ready`, and synchronizes the file and containing directory.
3. Swift opens initial source segment files and reports their descriptors.
4. Rust appends/commits `segment_opened` evidence for every required source.
5. Only after the journal is durable and required files are open may Rust commit `recording_started`; only that snapshot permits the UI to say Recording.

Any interruption is a recoverable `preparing` session, never a partially successful Recording claim.

### Logical atomic finalization

1. Rust commits `stop_requested`; Swift stops adapters and seals each open segment.
2. Rust durably records segment results and enters Finalizing only when source media is safe or an explicit loss condition is recorded.
3. Recovery/playability validation runs before mixdown status.
4. Rust commits `session_finalized` and materialized `ready_for_review` in one SQLite transaction, then appends a matching journal receipt.

If the journal receipt is interrupted after the SQLite commit, recovery reconciles by event ID; operations are idempotent.

### Startup recovery

- Before allowing a new capture, scan SQLite nonterminal sessions and managed session directories with journals not represented by terminal database state.
- Validate journal chains, inspect every referenced segment, recover/truncate the active CAF segment to the last valid packet/frame, and never modify sealed valid segments.
- Emit a recovery plan before mutation. Apply idempotently, preserving original files when validation is uncertain.
- Mark the session Interrupted, then Ready for Review only after at least one track is playable and every loss/gap is explicit. Never recreate missing audio with silence without a visible gap event.
- Recovery receipts record what was preserved, truncated, missing, or rejected. “Recovered” never means “complete” unless validated durations and segment coverage prove it.

### Layout, migration, and deletion

- Resolve the managed root through `FileManager`’s Application Support directory and append `Open Scribe/`; under App Sandbox this is the application container. Sessions are `Sessions/<session-id>/` with `recovery.jsonl`, `audio/`, `video/`, `context/`, and `exports/`.
- Segment names are identity-free and deterministic: `<track-id>/<six-digit-sequence>-<start-nanoseconds>.caf`. User titles and source names never become paths.
- Database migrations are ordered, transactional, forward-only Rust migrations. Before a destructive migration, checkpoint/close SQLite and make an atomic local backup. A failed migration leaves the prior database and media untouched.
- Delete means move the entire session directory to macOS Trash first, capture the resulting URL when available, then commit a database tombstone/deletion receipt. If Trash fails, no database deletion occurs. Permanent deletion is a separate explicit future action.
- Never move or copy an open WAL database without its WAL/SHM state; close and checkpoint first.

### Disk pressure

- Preflight requires configured reserve plus estimated five minutes of selected-source PCM. During capture, inspect free capacity at least every sealed segment.
- Warning and critical thresholds are recorded configuration, not scattered constants. Critical pressure stops opening new segments, seals current writable media, and enters Finalizing/Interrupted explicitly. Never delete source media or old sessions automatically.

## Alternatives

SQLite-only journaling cannot recover media/directories unknown to the last commit. JSONL-only storage makes library queries and migrations fragile. Multiple writers complicate ordering and expose WAL concurrency risk. Treating filesystem and SQLite work as physically atomic is false. Immediate recursive deletion makes mistakes unrecoverable.

## Security and privacy

All paths are relative to a managed root. Inputs are length- and type-bounded. Journal parsing treats malformed records as untrusted and never follows symlinks outside the session. Logs remain content-free. No network access is involved.

## Migration and rollback

Schema v1 is admitted only with create/open/migrate/backup/restore tests. Rollback can disable writes and open the last compatible database read-only; it never down-migrates or removes media. Each migration requires its own fixture, rollback boundary, and forced-termination phase matrix.

## Proof

Acceptance requires forced termination after every numbered creation/finalization step, during segment write/seal, during journal append, during SQLite commit/checkpoint, and during recovery itself; restart must converge idempotently to playable media or an explicit loss receipt. Test full disk, read-only directory, malformed/truncated journal, missing segment, digest mismatch, WAL/SHM retention, migration failure, Trash failure, and repeated recovery. Zero silent media loss is mandatory.

## Primary references

- SQLite, “Write-Ahead Logging”: https://sqlite.org/wal.html
- SQLite, “Atomic Commit”: https://sqlite.org/atomiccommit.html
- Apple, `FileManager`: https://developer.apple.com/documentation/foundation/filemanager
- Apple, `trashItem(at:resultingItemURL:)`: https://developer.apple.com/documentation/foundation/filemanager/trashitem(at:resultingitemurl:)
