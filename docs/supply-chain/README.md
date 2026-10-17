# Supply-Chain Inventory

`components.v1.json` is generated deterministically from the locked Cargo
dependency graph by `./script/generate_supply_chain_manifest.sh`. Use `--check`
to detect drift. The contributor candidate gate also runs this check, so a
lockfile change must include its regenerated inventory before qualification.
Generation does not approve an external component or close its obligations.
Metadata discovery is locked and offline: generation never fetches a package.
An incomplete local Cargo cache fails explicitly rather than enabling network
access. Packages present only in the lockfile can retain `UNKNOWN` license
metadata and remain unresolved; no license is inferred from a similarly named
or different-version package.

The current inventory is intentionally `open`: workspace crates are admitted as
repository-owned inputs, while external dependencies remain `Pending` until
their shipped-target relevance, license text, binary inclusion, obligations,
and notices are reviewed. Graph completeness is not release clearance. Swift,
native, Sparkle, model, and visual-asset components must be added when adopted;
unknown shipped components block release.

## Offline native license materials

Run `ruby script/prepare_license_materials.rb /absolute/new-output-directory`
to collect material for the existing native component review. An output inside
this repository must be ignored, for example a fresh directory below `var/`.
The tool refuses an existing or redirected output; it never downloads a crate,
changes a lockfile, or edits canonical manifests/notices.

It snapshots locked, offline Cargo metadata for `aarch64-apple-darwin`, walks the
`open-scribe-uniffi` normal/build dependency graph without dev edges, and
separately labels normal paths without procedural macros. This conservative
declared graph can include workspace feature unification; it does not establish
which code is linked into one particular app. Every collected archive must match
its exact `Cargo.lock` SHA-256 before its license bytes are read. The collection
includes recognized nested native license/notice filenames, with size bounds,
path checks and content hashes. Archive substitution fails before output creation.

`review-materials.json` binds the lockfile, current component inventory, metadata,
producer and draft notice hashes. `cargo-metadata.json`, content-addressed texts
under `licenses/`, and `THIRD_PARTY_NOTICES.DRAFT.md` accompany it. Missing cached
archives and missing license texts are explicit per-component gaps. A prepared
collection, even with no detected gap, has `admission_effect: none`; every review
remains `Pending`. Filename recognition cannot prove complete legal obligations.

Review still needs actual artifact inclusion, canonical license/source notices
(including missing upstream texts), non-Cargo resources, redistribution decisions,
and authorized adoption. `THIRD_PARTY_NOTICES.md` remains the canonical development
notice. The ADR 0017 deterministic release notices/SPDX path is still a prerequisite;
this collection does not implement or admit that later path. No component, model,
legal, signing or release gate is changed by running it.
