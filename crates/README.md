# Rust Workspace Boundaries

These packages are compileable placeholders, not product implementations.

## WASM-safe shared layer

- `open-scribe-types` — cross-boundary value types
- `open-scribe-domain` — deterministic states and transitions
- `open-scribe-evidence` — evidence and claim-lineage semantics

Shared crates must remain free of filesystem, SQLite, network, Apple, model-runtime, and other native-only dependencies. `./script/check.sh --scaffold` compiles each for `wasm32-unknown-unknown` and checks the dependency direction.

## Native layer

- `open-scribe-store` — future SQLite/filesystem persistence and recovery journal
- `open-scribe-asr` — future speech-recognizer capability and native adapters
- `open-scribe-diarize` — future VAD/embedding/clustering pipeline
- `open-scribe-memory` — future structured meeting-memory validation
- `open-scribe-models` — future model catalog and verification policy
- `open-scribe-core` — future orchestration and durable product authority
- `open-scribe-uniffi` — future coarse Swift control/query boundary

No external dependency, public domain type, FFI contract, persistence schema, or model engine has been selected.
