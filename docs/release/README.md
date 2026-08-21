# Release Proof

No Open Scribe release exists.

A source build is not a release receipt. Public-release status requires proof bound to the exact distributed artifact, including:

- Developer ID and nested signatures;
- hardened runtime and entitlements;
- notarization and stapled ticket;
- Gatekeeper on a clean machine;
- launch, fixture recording, forced termination, media recovery, and offline transcription when a model is installed;
- unchanged signature after use;
- SHA-256, SBOM or dependency manifest, release notes, architecture/minimum OS, and canonical download readback;
- signed Sparkle appcast when updates are enabled;
- public website claims matching demonstrated capability.

`script/release.sh` and `script/verify_bundle.sh` intentionally fail until these lanes are implemented and authorized.

ADRs 0015–0017 decide the future capability-true website, production bundle,
Sparkle, notarization, and staged release authority. They admit implementation
only after the preceding runtime gates and do not change the current no-release
status. Cloudflare deployment remains separately authorization-gated.
