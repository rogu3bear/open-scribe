# ADR 0017 — Release Authority, Automation, and Canonical Readback

- Status: Accepted for Milestone 5 implementation; publication/deployment still requires explicit authorization
- Date: 2026-08-20
- Owner/approver: repository operator, through the explicit Milestone 5 public-release instruction
- Founding clauses refined: PRD 2.10, 20, 23, 25–27, 29.8–29.9, 31–32, 34, and 39
- Supersedes: nothing

## Context and evidence

Release is a chain of distinct proof planes: source, built application, signed/notarized packages, update feed, GitHub publication, website deployment, and canonical public readback. Combining them in one “release” command makes it easy to publish before clean-machine proof or to let the website advertise a different binary. Third-party notices, model manifests, legal adoption, P0 status, signing identity, and public bytes must be bound to one immutable receipt.

## Decision

### Supply-chain authorities and generated artifacts

- `docs/supply-chain/components.v1.json` records every shipped Rust/Swift/native/Sparkle code component and visual asset: source, version/commit, license, obligation, included targets, binary path, and hash where applicable. Rust inventory derives from `Cargo.lock`/metadata; Swift from `Package.resolved`; native engines/assets require explicit entries. Generation rejects an unknown shipped component.
- `THIRD_PARTY_NOTICES.md` is generated deterministically from that manifest and canonical license texts, then reviewed; it is no longer an independently edited inventory. Release also emits SPDX 2.3 JSON and hashes both artifacts.
- `docs/models/manifest.v1.json` is the sole release-signed catalog described by ADRs 0008 and 0014. Each engine/weight records purpose, source/revision, license and redistribution decision, length/hash, format, compatibility, resources, download origins, prompt/calibration compatibility, and whether bundled. The default application manifest declares no bundled large weight.
- `release-manifest.v1.json` binds version/build, source SHA/tree, toolchains, minimum OS/architecture, bundle/team/designated requirement, capability/legal/notices/model/SBOM hashes, app/update/DMG hashes and sizes, Sparkle signature/feed hash, notary submission IDs/log hashes, test receipt IDs, GitHub asset identity, and later website deployment/readback identity.

### Release stages and authority

- `script/release.sh prepare <version>` is local/reversible. It requires every M0–M4 milestone receipt for the exact tree, adopted legal/security sources, a closed P0 ledger, clean lockfiles, capability/runtime agreement, notices/model/SBOM generation, release notes, version allocation, and all non-secret tests. It produces an unsigned plan and content-addressed inputs only.
- A protected release workflow, triggered only from an approved immutable tag and protected environment, builds once, imports Developer ID/notary/Sparkle credentials into an ephemeral keychain, archives/signs/notarizes/packages/verifies, emits the signed receipt/artifacts, then destroys the keychain. Pull requests, forks, ordinary CI, and preview builds never receive release secrets or publish access.
- Artifact verification and clean-machine/update/network-denial matrices run against copies of the exact signed outputs. Failure at any point leaves a candidate, not a release. The pipeline does not rebuild after proof; publishing promotes those already-hashed bytes.
- GitHub Release publication is a separate protected action. Assets are `Open-Scribe-<semver>-arm64.dmg`, `Open-Scribe-<semver>-arm64.zip`, checksums, release manifest, SPDX, notices, model manifest, release notes, and source archive. A version/asset is policy-immutable: automation rejects an existing tag, release, filename, or differing asset rather than replacing it.
- Website preparation consumes the verified release manifest and policy-immutable GitHub asset URLs, generates `/releases/<version>/...`, the signed appcast, `/download`, and `/download/latest`, and produces a content-addressed Worker/Assets bundle. It may not build a different app or infer capabilities.
- Canonical Cloudflare deployment is a final separate operation through the repository/Cloudflare control-plane gate after an explicit operator authorization for the exact web bundle, routes, manifest, and diff. `script/release.sh`, builds, tests, notarization, GitHub publication, and appcast generation never imply or perform that deployment.

### P0 and publication gate

- The release ledger enumerates every PRD P0 with owner, exact artifact test, environment, receipt, and state. Failed, flaky, skipped, stale, unknown, waived-without-PRD-authority, or lower-plane-only P0 evidence blocks publication. “No unresolved P0” means every entry is Passed against the distributed candidate.
- Required P0s include explicit capture authority/state truth, media durability/recovery/source identity, local-only network behavior, provider scope, evidence/interpretation separation, deletion, update integrity, legal/security truth, and website/binary capability equality.
- P1/P2 limitations may ship only when explicitly recorded, non-deceptive, and outside P0 invariants. The website and release notes disclose material unavailable capabilities without converting them into roadmap promises.

### Canonical download and update authority

- `https://open-scribe.app/download/latest` is the stable human URL. It redirects from the checked current release manifest to the policy-immutable GitHub DMG asset. Versioned canonical paths never change target or hash. The Download page presents the release-manifest SHA-256 before transfer.
- `https://open-scribe.app/updates/appcast.xml` is the Sparkle feed built from the same release manifest. Deployment cannot advance the feed without the corresponding verified update ZIP and cannot advance Download without the matching DMG.
- Post-deploy readback fetches canonical HTML/headers/manifest/appcast and follows the canonical download from multiple fresh regions/clients. It verifies status/redirect chain, TLS origin, byte size/SHA-256, DMG signature/ticket/Gatekeeper, enclosed app identity, Sparkle signatures, legal/capability hashes, cache policy, and website claim-to-capability references.
- Release becomes `Complete` only after canonical readback and one clean-machine canonical install/launch. Before readback it is `Published, unverified`; any public UI must avoid a success claim.

### Rollback and incident behavior

- Before deployment, rollback is deletion of the candidate only. After GitHub publication but before website deployment, leave the immutable release as prerelease/withdrawn and do not expose it canonically. After deployment, restore the preceding content-addressed website/current pointer and remove the bad item from the current appcast; never replace bytes under the same version.
- An already installed bad version is repaired only by a higher signed/notarized build. Compromised Developer ID, Sparkle, GitHub, or Cloudflare authority invokes the security incident/key-rotation runbook and freezes release; automation never routes around a failed trust plane.

## Alternatives

One monolithic build-and-deploy job lets lower-plane success escape publicly. Rebuilding after notarization invalidates exact-artifact proof. Mutable “latest.dmg” bytes defeat receipts. Generating website copy from source features instead of the shipped manifest permits drift. Hand-maintained notices miss transitive/nested components. Treating a passed notarization request as release ignores Gatekeeper, clean-machine behavior, updates, and canonical delivery.

## Consequences

Milestone 5 has more gates and two explicit publication approvals, but each irreversible action promotes already-proven bytes. GitHub hosts versioned, policy-immutable large artifacts while the stateless canonical site owns discoverability and verified redirects. A release can be signed and published yet honestly remain incomplete until canonical readback succeeds.

## Security and privacy

Release secrets exist only in a protected ephemeral environment, with least-privilege publication identities and no PR exposure. Public manifests contain hashes/identity/provenance, never credentials. Canonical readback detects substitution across GitHub, Cloudflare, appcast, and website claims. Legal review and a real private security channel are mandatory external prerequisites, not automated assertions.

## Migration and rollback

The release scripts remain fail-closed stubs until every predecessor receipt and this workflow are implemented. Each stage is added first in dry-run/plan mode, then artifact mode, then protected publication. Existing M0 website truth stays public-source-only until a complete candidate exists. Rollback follows the immutable-version rules above and never weakens a signature, hash, capability, legal, or P0 assertion.

## Proof

Acceptance requires a rehearsal from exact tag through protected build, nested signing, two notarizations, DMG/update generation, independent clean-machine and N−1 tests, GitHub prerelease, content-addressed website preview, explicit deploy authorization, canonical deployment, and authenticated readback. Inject failures at every boundary: stale/missing receipt, unknown dependency/model, legal draft, open P0, secret exposure probe, wrong identity/entitlement, notary warning, asset replacement, feed/manifest mismatch, website overclaim, redirect/hash substitution, partial deploy, and regional stale cache.

The final receipt must identify the exact distributed bytes and show signed/notarized artifact, Gatekeeper, clean-machine launch, update, canonical download, capability equality, distributed-artifact network denial, complete DESIGN native/web matrix, and zero unresolved P0s. Unit tests, CI green, a GitHub Release, or a Cloudflare deployment alone cannot close Milestone 5.
