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

Release inputs are semantic, not presence flags:

- `p0-ledger.v1.json` is valid but deliberately `open`; every entry must be
  `Passed` with the canonical P0 set, owner, environment, exact artifact test,
  candidate-bound receipt, and distributed-artifact SHA-256 before preparation
  can advance.
- `docs/capabilities/manifest.v1.json` labels only the M0 shell and short local
  microphone run as `Fixture`; later product capabilities are `Unavailable`.
- `docs/models/manifest.v1.json` truthfully declares that no large model weight
  is bundled or admitted.
- `docs/supply-chain/components.v1.json` is generated from the complete Cargo
  graph and remains `open` while external-component obligations are reviewed.
- `script/validate_release_input.sh` rejects malformed schemas and distinguishes
  unresolved `HOLD` state from a closed input.
- `script/verify_bundle.sh` now implements read-only app/DMG rejection and
  verification paths. Its contract tests do not prove that a signed artifact
  exists or passes.
- `docs/release/signing-policy.v1.json` remains absent until the operator
  approves the exact Developer ID team/common name, leaf-certificate SHA-256,
  and Sparkle public key. The verifier cannot emit a production-identity pass
  without that separate authority.

ADRs 0015–0017 decide the future capability-true website, production bundle,
Sparkle, notarization, and staged release authority. They admit implementation
only after the preceding runtime gates and do not change the current no-release
status. Cloudflare deployment remains separately authorization-gated.
