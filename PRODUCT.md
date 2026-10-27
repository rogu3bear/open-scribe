# Open Scribe product context

<!-- impeccable:product-schema 1 -->

This is the compact product context for design work. The
[founding PRD](docs/product/FOUNDING_PRD.md) and approved
[architecture decisions](docs/architecture/README.md) retain authority.
[NORTH_STAR.md](NORTH_STAR.md) owns the mission projection;
[ANCHOR.md](ANCHOR.md) owns invariants. The existing
[design contract](docs/design/DESIGN.md) owns presentation decisions.
This file creates no new capability, milestone, or release claim.

## Platform

macos

Native macOS on Apple Silicon. The separate website explains the product;
it is not a browser recorder. Impeccable's current platform vocabulary lacks
macOS; preserve this explicit value rather than classifying the app as web,
iOS, or a product with multiple native platforms.

## Users

The primary intended user is an individual Mac operator personally responsible
for reviewing important conversations. They need to establish what was said,
check consequential details against audio, preserve corrections, and reuse the
result outside the app.

The [conversation reviewer persona](docs/product/PERSONA_PU_001.md) is
provisional, with low behavioral confidence. Specific occupations, broader
market demand, repeat use, and willingness to pay remain unvalidated.

## Product Purpose

Preserve conversations as recoverable local evidence and make them useful to
review. The core journey is deliberate recording or import, saved source
audio, timestamped transcript, verification and correction, search, export,
and later reopening without losing reviewed work.

Success means that the user can find a consequential passage, hear its source,
correct it, find the correction again, and export a usable result. Recording
must remain truthful through interruption. Product success also requires
voluntary reuse; passing implementation tests alone cannot establish it.

## Positioning

The intended distinction is user-controlled capture and inspectable local
evidence. Source audio, machine wording, human corrections, speaker assignments,
and derived interpretations retain distinct identities. A claim should lead
back to its supporting or contradicting evidence.

This is a product thesis, not a demonstrated competitive advantage. The
[existing validation work](docs/product/experiments/2026-10-16-reviewed-conversation-validation.md)
owns the comparison and repeat-use decision rule.

## Operating Context

- Capture is deliberate. The compact recorder and menu-bar controls support
  an ongoing conversation; the library and conversation document support review.
- The user may also import an existing recording. Playback remains useful
  before transcription is ready. Installed, verified local models support
  transcription; model failure must not destroy source audio or reviewed work.
- An interruption belongs to the same conversation. Preserve prior audio,
  show the gap and affected source, and require a deliberate choice when a
  replacement microphone differs from the approved device.
- "Passthrough" in the current user brief means recording quietly alongside
  other audio activity. It does not authorize changing system audio routing,
  introducing a virtual device, hidden capture, or automatic device approval.
- Review follows the controls described in the
  [conversation review guide](docs/REVIEW_GUIDE.md). Setup and diagnostics
  should not become repeated steps in finding, checking, and exporting a passage.

## Capabilities and Constraints

The developer preview contains recording/import, recovery and playback,
local transcription, transcript search and correction, speaker review, and
export implementations. Consult [current verification limits](docs/TESTING.md)
before presenting any of these as qualified behavior. There is no supported
installer or binary release; M1 remains incomplete.

- SwiftUI and narrow AppKit adapters own Apple UI and platform integration.
  Rust owns durable state, evidence, recovery, provider policy, and exports.
  UniFFI remains a coarse control boundary; frame-rate media stays out of it.
- Local operation without an account is the default. A remote provider choice
  does not authorize sending content; each content category needs explicit scope.
- New supported M4A imports retain the original bytes. Older normalized imports
  cannot reconstruct an original that was never retained. The portable package
  has [documented format limits](docs/data-format/README.md); do not present
  transcript or audio exports as complete restorable backups.
- Optional context observation and evidence-linked intelligence remain within
  their existing milestones and proof requirements. They do not justify expanding
  the immediate review workflow into a dashboard or autonomous assistant.
- Preserve the established stack. No Electron, Tauri, React, Python application
  server, implicit cloud processing, or continuous default screenshot retention.

## Brand Commitments

The approved name is Open Scribe. Use plain, precise language about what is
recording, saved, incomplete, corrected, or unavailable. Do not turn model
output, guessed speaker identity, or a source-level check into a stronger claim.
The founding promise is: "Record what happened. Preserve what mattered. Show
where every conclusion came from."

## Evidence on Hand

The [testing record](docs/TESTING.md),
[imported-recording acceptance criteria](docs/product/IMPORTED_RECORDING_REVIEW_ACCEPTANCE_CRITERIA.md),
and [microphone-restore acceptance criteria](docs/product/MICROPHONE_RESTORE_ACCEPTANCE_CRITERIA.md)
separate implementation, automated checks, and remaining native/hardware proof.
Receipts apply to the exact source and artifact they name.

The existing five-operator repeat-use trial has not started. No customer
testimonials, measured review-time advantage, or market validation are available.
Private recordings are not public proof assets or implicit test fixtures.

## Product Principles

1. Preserve source evidence and reviewed work before adding interpretation.
2. Make capture scope and interruption state clear at the moment of action.
3. Complete one useful local review journey before adding product breadth.
4. Reduce recurring setup and decisions while preserving deliberate consent.
5. Keep source, automated, live-hardware, user-value, and release proof distinct.

## Accessibility & Inclusion

The founding contract requires complete keyboard operation, VoiceOver labels,
visible and logical focus, semantic headings and scalable type, reduced-motion
and increased-contrast support, accessible errors, and transcript navigation by
speaker and timestamp. State must never depend on color alone. These are
requirements to verify, not a claim that an assistive-technology audit has passed.
