# Third-Party Notices

## leptos-cloudflare

The Open Scribe website foundation adapts build and Cloudflare Worker patterns
from `rogu3bear/leptos-cloudflare`, inspected at commit
`2ee33f2930a60228024ee868b0414cf0fc0e526c`, under the MIT License. Starter
application content, identity, data model, routes, icons, and visual system were
not imported.

No third-party model weights, icons, fonts, or visual assets have been imported.
The adapted website wiring named above is source, not product identity or visual
direction.

## Runtime and build dependencies

### UniFFI 0.32.0

- Source: `https://github.com/mozilla/uniffi-rs` and `https://crates.io/crates/uniffi/0.32.0`
- License: Mozilla Public License 2.0 (`MPL-2.0`)
- Use: generated Swift/C bindings and Rust FFI support for the Milestone 0 native proof; the generator CLI is build-only, while UniFFI support code is statically linked into the unsigned development app.
- Distribution obligation: preserve the MPL-2.0 notice and make any modifications to MPL-covered files available under MPL-2.0 when distributing an artifact. No UniFFI source file is modified in this repository.
- Release status: included only in the local M0 development artifact; no public or signed artifact is produced by this lane.

### rusqlite 0.40.2 and libsqlite3-sys 0.38.2

- Source: `https://github.com/rusqlite/rusqlite`, `https://crates.io/crates/rusqlite/0.40.2`, and `https://crates.io/crates/libsqlite3-sys/0.38.2`
- License: MIT.
- Use: Rust-owned native session metadata, append-oriented event projection, migration, and recovery preparation. The connection is confined to `open-scribe-store`; shared WASM-safe crates do not depend on it.
- Linking: the `bundled` feature statically compiles the SQLite 3.53.2 amalgamation supplied by `libsqlite3-sys` so the tested SQLite implementation does not vary with the host operating system.
- Distribution obligation: preserve the MIT notices for rusqlite and libsqlite3-sys. SQLite itself is dedicated to the public domain as described by `https://sqlite.org/copyright.html`.
- Release status: present only in an unsigned local development artifact. Transitive dependency and exact binary-component review remains a release gate.

Transitive Rust packages are pinned in `Cargo.lock`. Their complete license and distribution-obligation audit remains a release gate and is not implied by this development notice.

The attached founding PRD is operator-supplied product material. The repository-context templates were transformed into project-specific doctrine and do not ship as product runtime code.

Before adding another dependency, model, asset, Sparkle component, native
library, or upstream website patch, record its source, version or commit,
license, distribution obligations, and whether it is included in a release
artifact.

This file must be regenerated or reviewed before every public artifact.
