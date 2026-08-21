# ADR 0012 — Local Context Reduction, Retention, and Events

- Status: Accepted for Milestone 3 implementation
- Date: 2026-08-20
- Owner/approver: repository operator, through the explicit Milestone 3 Spatial instruction
- Founding clauses refined: PRD 14.3–14.8, 20, 21, 28.4, 31 Milestone 3, and 39
- Supersedes: nothing

## Context and evidence

An attention field becomes an evidence source only after a local frame has been reduced into a sparse, explainable event. Retaining screenshots by accident, emitting unchanged OCR repeatedly, sending frame-rate values through UniFFI, or allowing slow Vision work to contend with audio would violate the product's privacy and reliability order.

Apple Vision can recognize text and return observations with bounds from in-memory images. That capability is a local reducer, not a retention policy or event authority. Rust must accept only a coarse reduced event tied to a live scope epoch, while Swift must keep raw pixels, image similarity work, and Vision values off the ordinary bridge and off the media hot path.

## Decision

### Isolation and bounded sampling

- Swift owns one context worker with its own task priority, buffers, autorelease scope, and bounded latest-candidate slot of capacity one. It shares no queue, lock, callback, buffer pool, or real-time thread with microphone or system-audio capture. When the slot is full, the older context candidate is dropped and a bounded diagnostic counter advances; context never backpressures audio.
- Follow Pointer may request one frame only after accepted dwell and observes a one-second minimum interval for the same scope. A fixed selected display/window/region samples at no more than 1 Hz while context is active, backs off to 0.2 Hz after 30 seconds without accepted semantic change, and wakes on relevant window/display changes or an explicit user mark.
- macOS versions with `SCScreenshotManager` use its one-frame capture. The macOS 13 fallback creates a tightly bounded `SCStream`, accepts one complete frame, and immediately stops it. Both use the exact authorized `SCContentFilter`, region, self-exclusion, and epoch.
- Raw frames never cross UniFFI, enter Rust, appear in logs, telemetry, crash metadata, fixtures, or caches. Pointer coordinates, frame-rate meters, full-resolution similarity maps, and unaccepted OCR results follow the same rule.

### Change detection and OCR reduction

- The worker masks excluded/transient surfaces where practical, then aspect-fits the authorized region to a 160-by-90 grayscale working image using Accelerate. It computes a versioned block-luma fingerprint and mean absolute luma delta against the last candidate for that scope epoch.
- Only a calibrated visual-change threshold advances to Vision. The initial threshold and masking revision are fixture-bound implementation constants recorded with diagnostics; changing their meaning requires a new reducer revision. A byte-identical or below-threshold frame produces no OCR work and no event.
- Vision runs locally on the authorized crop. Text is Unicode-normalized, whitespace-normalized, ordered by stable reading-order rules, and paired with quantized normalized bounding boxes. A semantic hash covers reducer revision, scope identity, normalized text, and layout. Confidence is diagnostic and may not silently delete low-confidence evidence.
- An event is proposed only when the semantic hash differs from the last Rust-accepted event for that scope epoch, or when the user explicitly marks the moment. A visual change with no recognized semantic content creates no automatic event; a user mark may record that no text was recognized. The last candidate fingerprint is not itself durable evidence.
- Only Rust acceptance advances the accepted hash and may trigger the Active-attention overlay. A failed, duplicated, stale, paused, revoked, or unavailable proposal returns a coarse rejection and produces no visual success signal.

### Sparse append-oriented event

- The versioned `ContextEvent` contains event/session/scope IDs, scope epoch, monotonic session range and wall-clock observation time, reason (`attention`, `fixed_scope_change`, or `user_marked`), named source identities and normalized bounds, reducer and Vision revisions/languages, ordered normalized text blocks and quantized boxes, semantic hash, prior accepted event digest, retention policy, and optional durable snapshot reference.
- It contains no pointer trail, raw pixels, thumbnails, transient platform handles, or frame-rate values. Platform identifiers needed for provenance are bounded strings/integers, never live objects.
- Rust validates scope/epoch and monotonic time, suppresses duplicate semantic hashes, appends the journal event, and projects it into SQLite through the serialized writer defined by ADR 0006. Context failure or event rejection never changes media durability or Recording truth.

### Pixel lifetime and explicit retention

- Retention is a versioned policy with `NoPixels`, `UserMarkedSnapshots`, and `MeaningfulSnapshots`. `NoPixels` is the default and constructs no file encoder or snapshot writer. Explicit screen video is a separate capture authorization and is not smuggled into these snapshot policies.
- Under `NoPixels`, the raw frame, grayscale image, masks, and Vision request image are released as soon as reduction completes or aborts. Owned mutable buffers are cleared before reuse where the platform permits. The durable event states `retention: no_pixels` and has no snapshot reference.
- Enabling snapshot retention is an explicit per-session choice that previews scope, trigger policy, sensitivity, and storage consequences. It applies prospectively and cannot reconstruct earlier frames. Narrowing scope does not silently preserve broader retention authority.
- A retained image is a PNG written under the managed session context directory through a same-volume staging file, synchronized, SHA-256 hashed, and atomically renamed. Rust accepts the snapshot reference only after the file receipt is durable; failure leaves a text-only event and an explicit retention failure rather than claiming a snapshot.
- Pause and revoke stop new frame acquisition and retention. Session deletion and Trash behavior follow ADR 0006 and include retained context artifacts. No context frame or reduced text is sent to a provider merely because a provider is configured.

## Alternatives

Continuous screen video is disproportionate to sparse context. OCR on every frame wastes energy and produces duplicate noise. Keeping “temporary” screenshots on disk makes the default retention claim false. Passing frames through Rust or UniFFI expands copies and couples unrelated lifetimes. An unbounded queue preserves stale context at the cost of recording reliability. A context event for every non-text visual delta invents meaning the reducer cannot support.

## Consequences

The 1 Hz/adaptive ceiling and dwell rules trade completeness for explainability, privacy, and bounded resource use. Text-free visual changes are absent unless marked. Retained snapshots require additional durable-write and deletion proof. Reducer versions become part of event provenance so future calibration cannot rewrite old meaning.

## Security and privacy

The default durable raw-frame count is structurally zero because no writer is constructed. Reduction is local, scopes are epoch-bound, logs are content-free, and explicit retention is prospective. OCR text can still be sensitive; it inherits session protection, export selection, provider-scope, deletion, and recovery policy. Best-effort masks do not justify a claim that every notification or secret is always excluded.

## Migration and rollback

Events record schema and reducer versions. Readers preserve unknown fields and expose unsupported reducers without recomputing old evidence. Rollback disables context acquisition while retaining readable events and managed snapshots. It never fabricates OCR, reconstructs discarded pixels, converts `NoPixels` to retained, or deletes existing artifacts outside the ordinary user-visible deletion flow.

## Proof

Acceptance requires deterministic frame fixtures showing that identical and below-threshold frames produce no OCR/event, semantic duplicates produce no append, changed text produces one event, and user-marked text-free change is explicit. A default-retention run must inspect the session tree, SQLite, journal, logs, caches, and temporary directories and report exactly zero retained raw-frame artifacts.

The runtime matrix must include two hours of simultaneous audio and worst-case context load, injected slow OCR, saturated candidate production, retention disk latency/failure, permission loss, pause, revoke, and topology churn. Audio loss, discontinuity, and drift must remain within the independent Milestone 1 acceptance bounds, and context queues may grow no larger than their declared bound. Revocation-race proof must show no accepted event or retained image after the invalidated epoch. Unit tests alone do not satisfy these requirements.
