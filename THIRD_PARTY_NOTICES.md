# Third-Party Notices

No third-party model weights, icons, fonts, visual assets, or template implementation has been imported into this repository.

## Runtime and build dependencies

### UniFFI 0.32.0

- Source: `https://github.com/mozilla/uniffi-rs` and `https://crates.io/crates/uniffi/0.32.0`
- License: Mozilla Public License 2.0 (`MPL-2.0`)
- Use: generated Swift/C bindings and Rust FFI support for the Milestone 0 native proof; the generator CLI is build-only, while UniFFI support code is statically linked into the unsigned development app.
- Distribution obligation: preserve the MPL-2.0 notice and make any modifications to MPL-covered files available under MPL-2.0 when distributing an artifact. No UniFFI source file is modified in this repository.
- Release status: included only in the local M0 development artifact; no public or signed artifact is produced by this lane.

Transitive Rust packages are pinned in `Cargo.lock`. Their complete license and distribution-obligation audit remains a release gate and is not implied by this development notice.

The attached founding PRD is operator-supplied product material. The repository-context templates were transformed into project-specific doctrine and do not ship as product runtime code.

Before adding another dependency, model, asset, Sparkle component, native library, or `rogu3bear/leptos-cloudflare` source, record its source, version or commit, license, distribution obligations, and whether it is included in a release artifact.

This file must be regenerated or reviewed before every public artifact.
