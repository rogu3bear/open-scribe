# Supply-Chain Inventory

`components.v1.json` is generated deterministically from the locked Cargo
dependency graph by `./script/generate_supply_chain_manifest.sh`. Use `--check`
to detect drift.

The current inventory is intentionally `open`: workspace crates are admitted as
repository-owned inputs, while external dependencies remain `Pending` until
their shipped-target relevance, license text, binary inclusion, obligations,
and notices are reviewed. Graph completeness is not release clearance. Swift,
native, Sparkle, model, and visual-asset components must be added when adopted;
unknown shipped components block release.
