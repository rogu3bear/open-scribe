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
