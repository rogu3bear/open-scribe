# Release Proof

No Open Scribe release exists.

`0.1.0-LAUNCH-CHECKLIST.md` coordinates the working cross-functional path to a
first public release. Its dates are planning targets, not evidence or release
authority. The checklist remains on hold until every blocker closes against
the exact candidate under this release-proof contract.

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
M0–M4 fail-closed gate availability, legal/security adoption, the P0 ledger, capability,
supply-chain and model manifests, release notes, and artifact-verification
availability. It returns `RELEASE_PREPARE_HOLD` with every observed blocker and
does not allocate a version, execute milestone proofs, sign, notarize, package,
publish, deploy, or mutate the tree. `./script/check.sh --release-prepare`
validates that contract.

Milestone, closed-P0, adoption, and qualification receipts are post-candidate
evidence and therefore live outside the tracked tree. Preparation may inspect
them from the absolute
`OPEN_SCRIBE_RELEASE_RECEIPTS_DIR`, or by default from the ignored
`var/release-receipts/<source-sha>/` directory. They remain advisory: an external
JSON file can be relabeled or forged, so preparation does not admit it as proof
until an approved provenance/authentication policy and canonical verifier exist.
This explicit hold avoids both self-invalidating tracked receipts and invented
local trust authority.

Preparation remains unconditionally held at the ADR 0017 transaction boundary
until semantic validators exist for a non-Cargo component inventory, SPDX SBOM,
deterministic third-party notices, an unsigned content-addressed plan, and the
canonical exact-candidate non-secret command set. Mere file presence or an
external Passed string cannot close these gates.

`script/verify_bundle.sh` remains intentionally fail-closed until the signed
artifact lane is implemented and authorized. `RELEASE_PREPARE_READY` is
currently unreachable by design; implementing authenticated evidence admission
and the semantic ADR 0017 transaction verifier is a separately reviewed change.

Release inputs are semantic, not presence flags:

- `p0-ledger.v1.json` is valid but deliberately `open`; every entry must be
  `Passed` with the canonical P0 set, owner, environment, exact artifact test,
  candidate-bound receipt, and distributed-artifact SHA-256 before preparation
  can advance.
- `docs/capabilities/manifest.v1.json` labels only the M0 shell and bounded M1
  runtime evidence as `Fixture`; later product capabilities are `Unavailable`.
  `open-scribe-core` owns the matching checked compile-time registry. Read-only
  preparation compares its normalized JSON with the claim manifest and checks
  the source linkage; artifact verification must later prove that the exact
  compiled app embeds the same registry.
- `docs/models/manifest.v1.json` truthfully declares that no large model weight
  is bundled or admitted.
- `docs/supply-chain/components.v1.json` is generated from the complete
  `Cargo.lock` package set and remains `open` while shipped-target classification and
  external-component obligations are reviewed.
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
