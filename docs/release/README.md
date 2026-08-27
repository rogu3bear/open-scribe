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

`script/release.sh prepare <semver>` is now the read-only first release stage. It
binds a candidate version to the exact source SHA/tree, examines tree cleanliness,
M0–M4 gate availability, legal/security adoption, the P0 ledger, capability,
supply-chain and model manifests, release notes, and artifact-verification
availability. It returns `RELEASE_PREPARE_HOLD` with every observed blocker and
does not allocate a version, execute milestone proofs, sign, notarize, package,
publish, deploy, or mutate the tree. `./script/check.sh --release-prepare`
validates that contract.

`script/verify_bundle.sh` remains intentionally fail-closed until the signed
artifact lane is implemented and authorized. A future `RELEASE_PREPARE_READY`
receipt proves only that local inputs exist; it is not a release receipt.

ADRs 0015–0017 decide the future capability-true website, production bundle,
Sparkle, notarization, and staged release authority. They admit implementation
only after the preceding runtime gates and do not change the current no-release
status. Cloudflare deployment remains separately authorization-gated.
