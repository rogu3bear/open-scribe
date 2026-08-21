# ADR 0016 — Bundle Identity, Signing, Notarization, and Updates

- Status: Accepted for Milestone 5 implementation, gated on Milestones 1–4 runtime proof
- Date: 2026-08-20
- Owner/approver: repository operator, through the explicit Milestone 5 public-release instruction
- Founding clauses refined: PRD 20.2–20.3, 21.6, 25, 26, 29.9, 31 Milestone 5, 33.7, and 39; DESIGN sections 5–7, 12, and 14
- Supersedes: ADR 0007 where it deferred distribution identity and prohibited later-required export/network/Sparkle IPC entitlements; the macOS 13 Apple-Silicon floor, App Sandbox, Hardened Runtime, and least-privilege posture remain

## Context and evidence

A debug bundle or successful source build is not distributable evidence. The final app must have one stable identity, a deliberate icon, exact production entitlements, valid nested signatures, offline-available notarization tickets, a simple DMG, and an update channel whose signing key is independent of Developer ID. Apple requires Developer ID, Hardened Runtime, secure timestamps, valid nested code, and notarization for direct distribution. Sparkle 2 supports EdDSA update/archive and feed verification plus an installer XPC service for sandboxed applications.

## Decision

### Product and bundle identity

- The production identity is display/product name `Open Scribe`, executable `Open Scribe`, bundle identifier `app.open-scribe`, Apple Silicon architecture `arm64`, and macOS 13 deployment floor. `app.open-scribe.dev` remains development-only and may never sign or publish a production artifact.
- `CFBundleShortVersionString` is release SemVer without build metadata. `CFBundleVersion` is a monotonically increasing decimal allocated by the release ledger and never reused. Sparkle, the release manifest, DMG/update filenames, and website display the same pair.
- The portable package declares extension `.openscribe` and exported/imported UTType `app.open-scribe.session`, conforming to package/data. No URL scheme, login item, launch agent, privileged helper, browser extension, or background daemon is admitted.
- The icon brief is `Open evidence ledger`: a native macOS rounded volume with a warm-white paper field, graphite open-ledger/spine form, and three restrained evidence/timestamp notches. It uses tonal depth but no recording red, microphone, waveform, AI sparkle, letters, glass orb, or additional brand color. A 1024 px master and Xcode asset catalog generate every required size; 16/32 px inspection must preserve the open-ledger silhouette without relying on the notches.

### Sandbox, Hardened Runtime, and entitlements

- Xcode archive/export owns the app bundle. Distribution uses Developer ID Application, automatic secure timestamp, Hardened Runtime, and Library Validation. All Mach-O code, Rust/native libraries, Sparkle framework, XPC services, updater, and helpers are signed with the same team as required. Release scripts never sign with `--deep`; they enumerate and sign/verify nested code inside-out.
- Production app entitlements are exactly App Sandbox, audio input, user-selected read/write files for import/export, outbound network client for explicit model downloads/update checks/remote providers, and Sparkle's two bundle-derived Mach lookup exceptions `<bundle>-spks` and `<bundle>-spki`.
- `SUEnableInstallerLauncherService=YES` enables Sparkle's sandbox installer XPC service. Because the app already has the network-client entitlement, `SUEnableDownloaderService` is absent/false and the Downloader XPC service is not used.
- Screen/system capture remains governed by TCC and user selection, not an invented entitlement. The production artifact has no `get-task-allow`, Apple Events/automation, camera, contacts, calendar, location, network server, JIT, unsigned executable memory, disabled Library Validation, broad filesystem, application-group, or debug entitlement.

### Sparkle update mechanism

- Use an exact pinned stable Sparkle 2.9-or-later release through Swift Package Manager/`Package.resolved`; updates to Sparkle are dependency changes with sandbox, nested-signature, license, and N−1 update proof.
- Stable feed URL is `https://open-scribe.app/updates/appcast.xml`. `SUPublicEDKey` embeds the dedicated Sparkle Ed25519 public key. Set `SURequireSignedFeed=YES`, `SUVerifyUpdateBeforeExtraction=YES`, and `SUSignedFeedFailureExpirationInterval=0` so feed-signature failure never expires into weaker behavior.
- Manual `Check for Updates…` is always available. Automatic checks are explicit opt-in and automatic downloading/installing is off by default. Check, availability, download, validation, install, cancellation, and failure create user-readable activity receipts.
- The update archive is a `ditto -c -k --sequesterRsrc --keepParent` ZIP of the already stapled app, preserving Sparkle/framework symlinks and permissions. Sparkle's pinned `generate_appcast`/`sign_update` produces EdDSA archive, appcast, and release-note signatures. Initial release emits full updates only; deltas require later N−1/N−2 proof.
- The Sparkle private key is separate from Developer ID and stored only in the protected release environment/offline recovery escrow. The repository contains only the public key. Rotation requires a rehearsed signed migration; loss never permits an unsigned feed.

### App, DMG, and notarization sequence

- Build/archive with pinned Xcode from an exact clean release checkout; export a Developer ID app; inspect nested entitlements/signatures and reject warnings, adhoc code, unexpected Mach-O files, writable executable locations, or unsigned resources.
- Submit a `ditto` ZIP of the signed app using `xcrun notarytool submit --wait`; retain the submission ID and complete log, require Accepted with no unresolved warning, staple/validate the ticket on the app, then create the Sparkle ZIP from that stapled app.
- Build a plain read-only compressed UDZO DMG named `Open-Scribe-<semver>-arm64.dmg`, containing the stapled `Open Scribe.app` and an Applications symlink. No installer script, custom background executable, package, privileged helper, or mutable post-sign customization is allowed.
- Sign the DMG with Developer ID Application, submit it separately with `notarytool`, inspect the log, staple and validate its ticket, verify the image, mount read-only, and compare the contained app against the previously verified app identity. Neither the app nor DMG is modified after its final signature/ticket.

### Artifact verification

- Verify nested code with `codesign --verify --deep --strict --verbose=4`, enumerate designated requirements and entitlements, reject `get-task-allow`, validate app and DMG tickets with `xcrun stapler validate`, assess the app with `spctl --assess --type execute`, assess the DMG with Gatekeeper's open/install context, and run `hdiutil verify` before hashing.
- A clean macOS 13 and current-macOS Apple-Silicon VM or physical Mac downloads through the canonical Safari path, mounts, copies to Applications, launches through Gatekeeper, exercises permissions, then repeats signature/ticket verification after real use. The machine has no Xcode/developer tools, prior app data, model cache, certificate, or release secret.
- Update proof starts from an independently signed/notarized N−1 or release-candidate build with the production bundle ID/key, discovers the new version through a staging copy of the signed feed, installs via Sparkle, relaunches, preserves user evidence/settings, and verifies the resulting app hash/version/signature/ticket and activity receipt.

## Alternatives

An unsigned ZIP omits the install experience. A custom installer adds scripts and privilege without need. Disabling the sandbox or Library Validation to make Sparkle work weakens the product boundary. Sparkle 1 lacks the accepted sandbox path. A homegrown updater adds archive replacement, signature, rollback, and privilege risk. Reusing the Developer ID key for appcast signing collapses independent trust roots. A red microphone/waveform icon turns live recording state into branding.

## Consequences

Sparkle adds nested XPC code and two narrowly named temporary Mach exceptions that must be inspected in every artifact. Network client is present even in local-only use, so runtime network-denial proof—not entitlement absence—proves local-only behavior. Double notarization of the app and DMG costs time but gives both extracted app and container stapled offline trust. Exact icon artwork remains a bounded visual artifact implementation under the locked brief.

## Security and privacy

Signing and Sparkle secrets never enter source, logs, PR builds, or artifacts. Hardened Runtime and sandbox remain enabled. Updates require Developer ID code signature, EdDSA archive signature, signed feed/release notes, pre-extraction verification, HTTPS, and expected bundle/version identity. The updater never changes model/evidence semantics and no model weight is bundled by default.

## Migration and rollback

The production Xcode target first reproduces all native gates under the production bundle/entitlement shape before signing. Migration from `app.open-scribe.dev` copies no dev data automatically. A published bundle ID or Sparkle public key is immutable except through a proven signed migration. A faulty published release is removed from the current appcast/download pointer and superseded by a higher build; published bytes/version numbers are never replaced in place.

## Proof

Acceptance requires exact nested signature/entitlement inventories, hardened-runtime and sandbox behavior, app and DMG notary logs/tickets, Gatekeeper assessments, clean-machine Safari download/install/launch, signature stability after capture/recovery/transcription, and N−1 update verification with signed-feed tamper, archive tamper, wrong bundle/team/version, downgrade, cancellation, offline, and interrupted-install cases.

The distributed app must complete the full native DESIGN accessibility/appearance/localization/window matrix and the network-denial local-only journey with installed model, no provider/account, and no pre-existing model cache. No source, archive, notarization, or local developer-machine result alone closes release.

## Primary references

- Apple, notarizing macOS software before distribution: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Apple, customizing the notarization workflow: https://developer.apple.com/documentation/security/customizing-the-notarization-workflow
- Apple, packaging Mac software for distribution: https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution
- Sparkle 2 documentation: https://sparkle-project.org/documentation/
- Sparkle sandboxing: https://sparkle-project.org/documentation/sandboxing/
- Sparkle publishing: https://sparkle-project.org/documentation/publishing/
