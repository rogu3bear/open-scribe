# Schema v4 migration fixture

Produced on 2026-09-29 by the store at commit
`7122903` (schema migration 4), importing one generated mono CAF through
`SessionStore::import_recoverable_caf` into a new managed root:

- `Library.sql` is `sqlite3 Library.sqlite3 .dump` of that root.
- `recovery.jsonl` is the session journal for session
  `01a0ef0d-2600-76c4-8f7e-de8905518c51`.

The media is not stored. Tests regenerate it byte for byte: a `caf-pcm-s16le`
file with 48,000 mono frames whose sample `i` is `((i % 480) - 240) * 64`,
SHA-256 `a8c794f178230c3f9e629e1366cf7c6891f1294a3d1eed283df1554fbeaa2587`.
Migration tests prove that later schemas add derived tables without
rewriting any sealed-evidence row.
