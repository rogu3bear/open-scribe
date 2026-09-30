# Rust Workspace Boundaries

Each package states its current source capability below. Components marked
intended have no implementation yet; `docs/TESTING.md` holds the dated proof for
what is implemented.

## WASM-safe shared layer

- `open-scribe-types` — cross-boundary value types
- `open-scribe-domain` — deterministic states and transitions
- `open-scribe-evidence` — evidence and claim-lineage semantics

Shared crates must remain free of filesystem, SQLite, network, Apple, model-runtime, and other native-only dependencies. `./script/check.sh --scaffold` compiles each for `wasm32-unknown-unknown` and checks the dependency direction.

## Native layer

- `open-scribe-store` — the SQLite library and per-session recovery journal: capture timelines, media integrity and recovery, imports, transcripts and human review, context scope and events, evidence resolution, two-phase deletion, and restoring a verified portable package as a new session
- `open-scribe-asr` — `SpeechRecognizer` capability, 48 kHz to 16 kHz mono conversion, chunk planning, overlap reconciliation, and the in-process whisper.cpp 1.8.3 recognizer (Accelerate and Metal)
- `open-scribe-diarize` — intended VAD/embedding/clustering pipeline
- `open-scribe-memory` — intended structured meeting-memory validation
- `open-scribe-models` — checked model catalog, staging from a chosen file, verification, and atomic installation policy; it never downloads or loads a model
- `open-scribe-core` — native orchestration: recording preparation, the review library, transcript, audio, and portable package exports, opening a portable package from another Mac, and local model installation and transcription
- `open-scribe-uniffi` — the coarse Swift control and query boundary

Local transcription runs through a manifest-verified model the user installs from a chosen file. Diarization remains Unavailable.
