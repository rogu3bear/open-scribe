# Open Scribe Anchors

> **Budget:** 350 words. These are durable projections of the founding PRD.

Lower layers may implement these invariants but may not weaken them.

## A1 — Capture is explicit and truthful

- Capture begins only after a deliberate user action. “Recording” is shown only after durable media and recovery state are active.
- Active state, sources, pause, failure, and revocation use redundant non-color signals.
- Proof: capture-authority, permission-revocation, and source-failure acceptance tests. Until they pass, recording support is unproven.

## A2 — Evidence outranks interpretation

- Audio, transcript ranges, timestamps, markers, declared context, and corrections remain distinguishable from summaries, decisions, commitments, and Loose Ends.
- Every material derived claim retains navigable supporting or contradicting evidence; unsupported output is labeled or omitted.
- Proof: evidence-lineage and human-adjudication tests.

## A3 — Local-first is the default

- Recording, durable storage, OCR reduction, and installed-model transcription work without an account or network.
- Provider selection never implies content authorization; each remote data category is separately scoped and receipted.
- Proof: network-denial and provider-scope tests.

## A4 — Reliability precedes intelligence

- Capture, durability, recovery, playback, transcript, diarization, context, then intelligence is the implementation order.
- ML backpressure may degrade derived work, never media capture.
- Proof: long-session, disk-pressure, source-change, and forced-termination tests.

## A5 — Watched scope stays bounded

- Context observation is explicit, inspectable, pausable, and revocable. Fast pointer transit is ignored.
- Raw pixels are discarded after local reduction by default; context writes are sparse and append-oriented.
- Proof: multi-display, unchanged-frame, raw-frame-retention, and permission-revocation tests.

## A6 — Platform boundaries stay legible

- Swift owns Apple UI and platform adapters; Rust owns durable state, policy, evidence, recovery, and exports; UniFFI remains coarse; shared crates remain WASM-safe.
- No Python, FastAPI, React, Tauri, Electron, localhost app server, upload-first semantics, or monolithic rewritten jobs file.
- Proof now: `./script/check.sh --scaffold`. Runtime ownership requires later integration proof.

## Change rule

Changing an anchor requires an explicit founding-PRD revision or approved ADR that names the superseded clause and its evidence.
