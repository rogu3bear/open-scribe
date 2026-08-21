# ADR 0011 — Context Scope, Attention, and Overlays

- Status: Accepted for Milestone 3 implementation
- Date: 2026-08-20
- Owner/approver: repository operator, through the explicit Milestone 3 Spatial instruction
- Founding clauses refined: PRD 9.4, 14.1–14.5, 14.8–14.9, 20, 28.4, 31 Milestone 3, and the Design Contract sections 8–9
- Supersedes: nothing

## Context and evidence

Spatial context is unusually easy to make invasive or misleading. A bright rectangle can look like evidence capture when it is only scope, pointer motion can be mistaken for attention, a display ID can become invalid during hot-plug, and a visual-only picker can exclude VoiceOver and Full Keyboard Access users. The founding contract instead requires explicit authorization, sparse attention evidence, honest permission state, actual display topology, and an exact perimeter treatment that never implies pixel retention.

Apple's ScreenCaptureKit supplies shareable display, application, and window identities and content filters. Newer systems also supply a system content-sharing picker and one-frame screenshot API; the macOS 13 fallback uses the same explicit filter with a bounded one-frame stream. Core Graphics display-reconfiguration callbacks are the topology invalidation signal. A borderless AppKit overlay can ignore mouse events, but that visual surface is not an accessible substitute for ordinary controls.

## Decision

### Ownership and authorization

- Swift owns the participant/topic preflight UI, ScreenCaptureKit enumeration and filters, display topology, pointer sampling, region editor, overlay windows, and platform permission observation. Rust owns the durable scope record, authorization epoch, lifecycle/health conditions, retention policy, sparse event acceptance, and pause/narrow/revoke commands.
- Participant and topic are optional declared session metadata. Entering them grants no context permission. Context starts Off and Starting or Recording audio never silently enables it.
- The user explicitly selects one mode: Follow Pointer, Watch Display, Watch Window, Watch Region, or manual Add Current Window. The preflight states the exact eligible scope, current Screen Recording permission, best-effort exclusions, and pixel-retention policy before authorization.
- An authorization receipt contains a stable scope ID, monotonically increasing epoch, mode, authorized platform identities and human-readable names, normalized bounds and topology snapshot, authorization time, exclusions, permission posture, and retention policy. Narrowing or otherwise changing scope creates a new epoch; it is never an in-place expansion hidden from the user.
- Screen Recording permission is requested only when a chosen operation requires it. Accessibility permission is not required for base recording or context selection, and Open Scribe does not scrape arbitrary accessibility text to evade screen-capture authorization.

### Selection and topology

- On macOS versions that provide it, the system ScreenCaptureKit picker is preferred for display/window/application selection. The macOS 13 fallback enumerates `SCShareableContent` into an ordinary SwiftUI list or table with native selection controls. System selection is reflected into the same Rust scope receipt.
- Every selectable display is described by platform name and topology position, such as “Built-in Display, left of Studio Display.” Window choices include application and window names. Color is never the only identity. Invalid or untitled items receive honest fallback labels, not inferred titles.
- Regions are bound to a named display and stored as normalized display-relative bounds plus the topology receipt. Pointer drag is complemented by arrow-key move, Shift-arrow resize, editable position/size fields, cancel, and explicit confirmation. VoiceOver exposes display, bounds, selection state, and consequences. Focus returns to the invoking control after confirmation or cancellation.
- Topology uses actual Core Graphics bounds, scale, rotation, and relative origin, including negative coordinates and arbitrary horizontal or vertical layouts. A display-reconfiguration callback rebuilds the topology. Removed or materially changed displays invalidate affected filters and epochs; the dependent scope pauses with an explanation until the user confirms a valid narrower scope.
- The inspected scope summary is always available from preflight, menu bar, compact live window, and the context inspector. These ordinary controls provide native buttons for Pause, Narrow Scope, and Revoke. Revoke is never hidden behind the visual overlay.

### Follow Pointer

- Follow Pointer is an attention approximation, not pointer history. Swift samples global position in memory at 30 Hz without an event tap and never persists or sends samples over UniFFI.
- The initial versioned acceptance parameters require the pointer to remain within a 16-point radius on the same eligible surface for 600 ms. A surface change, movement faster than 600 points per second, or departure from authorized scope cancels the candidate. The parameters must be calibrated against the acceptance fixtures; a later change is versioned rather than silently changing recorded meaning.
- Accepted dwell creates only a capture candidate. It does not create a context event or Active-attention treatment. Dock, menu bar, notification, Open Scribe, known password-manager, private-window denylist, and lock-screen surfaces are filtered where technically practical; the UI states that these safeguards are best effort rather than claiming perfect sensitive-field detection.

### Revocation ordering

- Revocation first stops the Swift sampler, invalidates the local epoch token, clears pending candidates, releases frames, tears down the ScreenCaptureKit filter, and removes or changes the overlay. Rust then records the durable revoked condition and receipt.
- Every candidate and reduced event carries scope ID and epoch. Rust rejects a missing, paused, revoked, failed, expired, or stale epoch deterministically. Therefore work already queued when revocation begins cannot become an accepted event.
- Permission loss follows the same fail-closed invalidation. It stops context immediately while preserving audio capture, durable media truth, UI feedback, and recovery behavior. Permission restoration permits a new explicit authorization; it does not resurrect the previous scope automatically.

### Exact overlay projection

- Overlays are borderless, nonactivating, pointer-transparent AppKit panels with no shadow, no hit testing, and no independent accessibility element. They are excluded from Open Scribe's capture filters. The controlling SwiftUI surface carries all names, roles, values, focus, and actions.
- Eligible scope is a 1-point white perimeter at 10% opacity, with no bloom, only while choosing scope.
- Hover is a 1-point white perimeter at 55% opacity with an 8-point outer bloom at 20% opacity. Other screens are not dimmed.
- Selected is a 2-point white perimeter at 70% opacity with a 12-point outer bloom at 25% opacity, plus the nonvisual selected-scope description in the controlling UI.
- Active attention is one 160 ms rise to a 2-point white perimeter at 90% opacity with a 16-point outer bloom at 35% opacity, immediately returning to Selected. Only a real Rust-accepted context event may trigger it; pointer motion, dwell, capture, change detection, or OCR alone may not.
- Paused is a 1-point white perimeter at 30% opacity with no bloom, plus explicit Paused text in menu and live surfaces. Revoked or failed is text and warning/failure treatment in the controlling UI, never a decorative red halo.
- Eligibility, hover, and selection luminance transition over 160 ms ease-out; selected depth changes over 200 ms ease-out. Reduce Motion removes the Active rise and uses immediate state changes or opacity-only transitions no longer than 100 ms. Reduce Transparency does not alter the perimeter. Increase Contrast replaces the relevant perimeter with a 2-point 100%-opacity white line plus a 1-point black outer keyline and removes bloom.
- The overlay never represents or announces retention. Retention truth is separately labeled in every scope summary.

## Alternatives

A visual-overlay-only picker excludes nonvisual users. Persisting global pointer events creates surveillance data without evidentiary value. Treating pointer entry as attention creates noise during transit. Hard-coded horizontal displays fail real topologies. Automatically restoring an old scope after permission or topology changes conceals a material authorization change. Using a red halo for failure turns decoration into ambiguous product state.

## Consequences

Milestone 3 needs a narrow AppKit bridge in addition to SwiftUI and explicit macOS 13/current availability paths. Selection and authorization contain more ceremony, but the receipt can answer exactly what was observed and why. Follow Pointer will intentionally miss brief attention; that is preferable to inventing evidence. Overlay conformance is a rendering obligation, not permission or retention proof.

## Security and privacy

Context is Off by default, authorization is scope-specific, pointer samples are ephemeral, and stale work cannot cross revocation. Open Scribe does not claim it can identify every sensitive field without broader permissions. Lock-screen suspension, self-exclusion, explicit denylist controls, and best-effort transient-surface filtering reduce exposure but are disclosed as safeguards, not guarantees.

## Migration and rollback

Scope receipts carry a schema version and epoch semantics. Unsupported receipts remain inspectable but cannot resume. Rollback disables context selection and records Context Unavailable; it does not broaden a scope, reuse a stale epoch, or alter media state. Existing sparse events remain readable under their recorded scope receipt.

## Proof

Acceptance requires a real four-display matrix including negative origins, vertical placement, mixed scale/rotation, hot-plug, and removal; scripted fast pointer transit that produces no candidate event; epoch-race tests at dwell, frame, OCR, and enqueue phases proving no event after revoke; and live permission revocation proving immediate context stop with uninterrupted audio.

VoiceOver and Full Keyboard Access inspection must select displays/windows/regions, read the same scope and retention truth, pause, narrow, and revoke without the perimeter. Matched rendered review must cover light/dark appearances, varied light and dark wallpapers, Increase Contrast, Reduce Motion, and Reduce Transparency. It must measure boundary visibility and inspect focus/semantics from the running UI; screenshots alone do not prove accessibility. Unit tests are necessary but cannot satisfy this gate.
