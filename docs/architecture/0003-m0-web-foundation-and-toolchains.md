# ADR 0003 — Milestone 0 Web Foundation and Toolchain Pins

- Status: Accepted for Milestone 0 only
- Date: 2026-08-20
- Owner/approver: repository operator, through the explicit instruction to initialize and prove the M0 website foundation
- Founding clauses refined: PRD 22, 25.3–25.4, 31 Milestone 0, 34, and 39
- Supersedes: ADR 0002 only where it left Swift/Xcode and website toolchains open

## Context and evidence

The founding PRD selects `rogu3bear/leptos-cloudflare` but requires a complete de-template. Upstream commit `2ee33f2930a60228024ee868b0414cf0fc0e526c` was inspected on 2026-08-20. It provides useful Leptos 0.8, Worker SSR, hydration, asset hashing, CSP, and deep-route wiring, but also contains a todo/contact domain, D1 migrations, session state, realtime examples, starter routes and identity, icons, and a complete starter visual system. Those application assumptions are not Open Scribe requirements.

The repository already pins Rust 1.93.1. The accepted local M0 checkout was observed with Swift 6.3.3 and Xcode 26.6 (build 17F113). The imported web build shape was verified against cargo-leptos 0.3.5, worker-build 0.7.5, Bun 1.3.14, Wrangler 4.107.0, and the Cargo-locked wasm-bindgen version.

## Decision

- Import the upstream as a one-time, selective architecture reference. Do not add an upstream remote, submodule, subtree, copied Git history, initialization script, or automatic synchronization job.
- Open Scribe owns every imported line after review. Future upstream changes enter only as narrowly selected, attributed patches after reviewing their product assumptions, security effect, lockfile delta, migration need, rollback, and exact local proof.
- Retain only the SSR/hydration split, Cloudflare Worker entrypoint, Worker Assets routing, content-hashed static assets, CSP generation, no-store dynamic HTML, immutable hashed assets, and deep-route SSR fallback.
- Exclude D1, migrations, session cookies, contact intake, todos, realtime/WebSocket examples, starter routes, starter icons, starter metadata, and all starter design tokens. The M0 website is stateless.
- Keep canonical legal text in `docs/legal/`; website legal routes compile those exact files with `include_str!` rather than maintaining web copies.
- Pin Swift and Xcode in `.swift-version`, `.xcode-version`, and `.xcode-build-version`, enforced by `script/check_apple_toolchain.sh`. Pin web build tools in `web/toolchain.env`; derive the effective wasm-bindgen CLI requirement from `Cargo.lock`. Wrangler is pinned for a later authorized local/runtime lane but is not invoked by the build receipt.
- `script/build_web.sh` may compile and verify local artifacts only. It may not run Wrangler, read Cloudflare account state, deploy, or imply a public website.
- Keep presentation intentionally minimal. This ADR authorizes semantic HTML, truthful M0 copy, responsive reading order, and visible focus only; it does not authorize the full website visual direction or an explanatory capture demonstration.

## Alternatives

Fork tracking, Git subtree, and periodic merge preserve easier upstream synchronization but also make starter-domain assumptions recurring merge inputs. Running the upstream initializer removes only part of the example and retains starter identity and visual language. Rebuilding without attribution would obscure the origin of security-sensitive Worker wiring. Using D1 for future convenience would create state, privacy, and abuse obligations without a current need.

## Consequences

The website has a small, reviewable edge surface and no database. Upstream improvements require manual comparison and may cost more to adopt, while upstream domain drift cannot enter automatically. Exact local tool pins improve repeatability but do not prove hosted-runner availability or deployed compatibility. The legal routes are visibly draft repository text until legal adoption.

## Security and privacy

The source introduces no credential, database, form intake, telemetry, native bridge, media path, or provider flow. The Worker response applies CSP, frame denial, MIME sniffing protection, strict-origin referrer policy, and no-store HTML caching. Static hashed assets are immutable. Deployment remains a separately authorized Cloudflare proof plane.

## Migration and rollback

Rollback removes `web/`, the root workspace member, toolchain pin files, this ADR, and website-specific checks. It does not alter native code or external state. A future stateful feature requires its own privacy, abuse, schema, migration, and rollback decision before D1 or another store is added.

## Proof

`./script/build_web.sh` must produce a Worker bundle, hashed client assets, and `target/web-ssr/index.html`; assert useful HTML before hydration; and report `WEB_BUILD_GREEN`. The scaffold must compile shared crates for `wasm32-unknown-unknown`, and `./script/check.sh --m0-native` must remain green on the same checkout. `./script/check.sh --m0` binds those planes into the exact `M0_COMPLETE_GREEN` receipt required before Milestone 1. These receipts exclude Cloudflare deployment, native capture, persistence, signing, notarization, distribution, and release.
