# ADR 0004 — Session Truth and Native Fixtures

- Status: Accepted for the deterministic state-fixture tranche only
- Date: 2026-08-20
- Owner/approver: repository operator, through the explicit instruction to implement the state records, fixtures, UniFFI boundary, and fixture-driven native surfaces
- Founding clauses refined: PRD 10–13, 18, 25.1–25.2, 26.1–26.3, 31 Milestone 1 state model, and 39
- Supersedes: ADR 0001 only where its immutable M0 status query was the complete native boundary

## Context and evidence

M0 proved only that Swift could render coarse Rust state. The design contract now defines seven durable lifecycle states, Starting as transient presentation, degradation and permission loss as orthogonal conditions, and a hard requirement that Recording follow durable-journal and media-open evidence. No real capture, persistence, or recovery implementation exists, so the native experience must be built from deterministic fixtures without suggesting otherwise.

## Decision

- `open-scribe-types` owns stable session, source, lifecycle, health, permission, durability, and recovery values without I/O or native dependencies.
- `open-scribe-domain` owns deterministic transitions and derives presentation, labels, timer behavior, symbols with reviewed fallbacks, accessibility values, and announcements.
- Starting never enters the durable lifecycle. Degraded health and permission state do not replace lifecycle. Recovery presentation derives from interrupted lifecycle or required recovery.
- Rust rejects entry to Recording unless both durable-journal and media-open evidence are true. Finalization rejects completion until media-safe evidence is true.
- Ten deterministic fixtures cover every durable state and specified orthogonal condition. Fixtures are demonstrations of state semantics, not evidence that their named I/O occurred.
- UniFFI exposes coarse snapshots and fixture commands only. No media buffers, frames, samples, meters, pointers, or high-frequency callback values cross it.
- One Swift `FixtureSessionStore` owns the selected Rust fixture snapshot. The menu bar and compact window observe that exact object. They render Rust-provided labels, timer behavior, accessibility truth, and announcement text. SF Symbols are used only after runtime resolution of the reviewed primary/fallback pair.
- Both native surfaces visibly say that no media is captured. Starting and Ready remain visually neutral and timerless; only evidence-backed Recording receives recording treatment.

## Alternatives

Persisting Starting would create a second state machine and ambiguous recovery. Encoding Degraded as lifecycle would lose whether capture continues. Swift-owned fixture semantics would permit menu/window drift. Sending waveform or meter updates over UniFFI would violate the coarse bridge and create a frame-rate serialization path. Real capture was rejected because its prerequisites and proof plane are outside this tranche.

## Consequences

The repository now has executable state semantics and inspectable native surfaces before capture exists. Fixtures make accessibility, transitions, and the presentation timer deterministic, but do not prove storage, permissions, audio devices, media safety, recovery, or captured elapsed time. The fixture controller is intentionally replaceable by a future persisted session controller while preserving snapshot vocabulary.

## Security and privacy

The tranche reads no device, permission, media, filesystem, database, network, provider, contact, or calendar data. Fixture source names are static. Telemetry records only scene, fixture, lifecycle, presentation, and boolean evidence posture. Accessibility announcements contain only fixture state.

## Migration and rollback

A future runtime may replace fixture construction with persisted records only after capture/persistence ADRs and exact I/O proof. It must preserve transition guards and coarse snapshots or version them explicitly. Rollback removes ADR 0004, state fixtures, new native views, and `--state-fixtures`, then restores the ADR 0001 status-only shell; it changes no external system.

## Proof

`./script/check.sh --state-fixtures` tests every Rust fixture and transition guard, round-trips the catalog through UniFFI, verifies shared crates for `wasm32-unknown-unknown`, rejects hot-path vocabulary at the bridge, regenerates and compares bindings, tests Swift mapping/shared-store/symbol/accessibility contracts, launches the exact unsigned app, and checks diff hygiene. `STATE_FIXTURES_GREEN` explicitly excludes real capture, journal/media I/O, persistence, recovery execution, deployment, signing, and release.
