# ADR 0007 — Platform Floor, Permissions, Playback, and Import

- Status: Accepted for Milestone 1 implementation
- Date: 2026-08-20
- Owner/approver: repository operator, through the explicit Milestone 1 reliable-recorder instruction
- Founding clauses refined: PRD 8–9, 11, 20, 21.2, 21.6, 23, 31 Milestone 1, 34, and 39; DESIGN sections 5–7 and 12
- Supersedes: ADR 0001 where it left permanent platform/signing capability decisions open; the macOS 13 deployment floor remains

## Context and evidence

The product must offer honest permission recovery, selected application/system capture, playback/import, and an accessible document UI across the accepted macOS 13 matrix. Direct-download distribution requires Hardened Runtime for eventual notarization. App Sandbox is not required outside the Mac App Store, but constraining access now prevents a later storage and permission redesign.

## Decision

### Platform and availability

- Keep Apple Silicon and macOS 13 as the supported floor for Milestone 1. This is stricter than the PRD’s macOS 15 recommendation because the accepted design contract explicitly requires macOS 13 fallback proof.
- On macOS 14+, prefer `SCContentSharingPicker` for system-mediated source selection. On macOS 13, present an Open Scribe native list derived from `SCShareableContent`, name the scope explicitly, and use the same selected content filter.
- Use AVAudioEngine microphone capture on every supported OS. Do not make ScreenCaptureKit’s newer microphone output a separate behavioral path during Milestone 1.
- Features without a truthful fallback are unavailable with an explanation; never silently widen capture scope. Capability records, not OS-version checks scattered through views, drive UI availability.

### Hardened Runtime and sandbox

- Convert the native app to an Xcode project before real capture. Keep SwiftPM packages for code organization, but Xcode owns the application target, capabilities, test host, archive, and entitlements.
- Enable Hardened Runtime with only audio-input resource access. Add no runtime exception, JIT, unsigned-executable-memory, library-validation bypass, Apple Events, camera, contacts, calendar, or network entitlement in Milestone 1.
- Enable App Sandbox with audio input and user-selected read-only file access for import. Managed media stays inside the application container/Application Support. No broad home-directory entitlement is allowed.
- ScreenCaptureKit access remains governed by macOS Screen Recording TCC and explicit system/user source selection; do not invent a screen-capture entitlement.
- Development/ad hoc signing can prove local capabilities, but Developer ID signing, notarization, distribution identity, and release remain separate proof planes.

### Permission flow

- Preflight explains the named source and consequence immediately before the platform prompt. Request microphone only when selected; request Screen Recording only for application/system audio.
- Persist only coarse authorization posture and last checked time. TCC remains authority.
- Denial shows the unavailable source and a non-recording Ready state. Revocation during capture seals the affected track, records a source event, announces what stopped and what continues, and offers the correct System Settings destination.
- Restoration never auto-resumes capture. The user explicitly reselects/repairs the source; a new segment starts after Rust records restoration intent.

### Playback and timeline

- Swift AVAudioEngine/AVAudioPlayerNode owns playback I/O. Rust supplies the coarse timeline/segment plan and receives play/pause/seek commands and low-frequency position updates.
- Source tracks remain authoritative. The validated mix is the default player; the inspector can solo/mute source tracks without rewriting them.
- Seeking resolves session nanoseconds to segment/frame offsets. Gaps, source changes, and recovered truncation remain visible timeline events rather than hidden silence.
- Playback never opens files still owned by an active writer. Finalizing may expose only sealed playable ranges.

### Import

- Import through `NSOpenPanel`, drag/drop, or Finder open uses security-scoped user-selected URLs. Default behavior copies the source into a new managed session; Open Scribe never mutates the original.
- Probe type, duration, tracks, and decode support before copying; enforce configurable size/duration limits and reject malformed or unsupported media without partial library rows.
- Copy to a staging name, synchronize, digest, probe the managed copy, then atomically rename and commit the import event. Failure removes only the staging copy.
- Imported sessions enter Ready for Review with `origin=import`; they never contain capture-start or recovery claims. Their timeline begins at zero and preserves original media metadata separately.

### Library and native structure

- The primary window uses `NavigationSplitView`: date-grouped lightweight conversation sidebar, document detail, optional closed-by-default inspector. It is not a dashboard or recorder console.
- Detail begins with title/metadata, playback/timeline, markers, and source events. Transcript and derived sections remain truthful unavailable states during Milestone 1.
- The compact live window and menu remain remote controls over the same Rust session snapshot. Pause/resume, marker, stop, source failure, and permission recovery use the exact design-contract labels and announcements.
- Every action is keyboard reachable. VoiceOver values come from the same state/timeline vocabulary as visible text; meters expose throttled source name plus level at 2 Hz and never announce routine changes.

## Alternatives

Raising the floor to macOS 15 simplifies capture but violates the accepted fallback matrix. Remaining SwiftPM-only obscures entitlements/archive behavior. Running unsandboxed broadens compromise impact and postpones storage migration. Referencing imported files in place makes playback depend on bookmarks, moves, and removable volumes. Swift-owned lifecycle state would reintroduce menu/window drift.

## Security and privacy

The entitlement set is least privilege and network-free. Permission prompts are just-in-time. Imports are treated as untrusted, copied into managed storage, and never executed. UI and telemetry contain coarse state, not media content or absolute paths.

## Migration and rollback

The Xcode target initially consumes the existing SwiftPM/Rust outputs and must reproduce the current native fixture gate before capture code is admitted. Sandbox migration has a fixture-only checkpoint and a managed-root migration test. Rollback disables real adapters and returns to fixture mode; it does not weaken entitlements to keep capture working.

## Proof

Acceptance requires real permission grant/deny/revoke/restore runs on macOS 13 and current macOS; codesign entitlement inspection; sandbox-denial tests; no-network capture; application/system source selection; playback/seek across segments, pause boundaries, gaps, and recovered media; malicious/unsupported/import-on-removable-media cases; and the complete rendered matrix for VoiceOver, Full Keyboard Access, light/dark, Increase Contrast, Reduce Transparency/Motion, localization, and minimum/preferred/wide windows. Source or unit tests cannot close these claims.

## Primary references

- Apple, “Hardened Runtime”: https://developer.apple.com/documentation/security/hardened-runtime
- Apple, “Audio Input Entitlement”: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input
- Apple, “App Sandbox”: https://developer.apple.com/documentation/security/app-sandbox
- Apple, “Protecting user data with App Sandbox”: https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox
- Apple, “Capturing screen content in macOS”: https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos
