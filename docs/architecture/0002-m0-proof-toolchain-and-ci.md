# ADR 0002 — Milestone 0 Proof Toolchain and CI Boundary

- Status: Accepted for Milestone 0 only
- Date: 2026-08-20
- Owner/approver: repository operator, through the explicit instruction to carry the M0 proof on one PR
- Founding clauses refined: PRD 25.3–25.4, 31 Milestone 0, 34, and 39
- Supersedes: nothing

## Context and evidence

The native proof spans Rust, a WASM compatibility check for shared crates, generated UniFFI bindings, SwiftPM, development app assembly, and runtime scene observation. A passing local checkout alone does not protect the PR from toolchain drift or later boundary violations. Signing, notarization, packaging, website builds, and protected capabilities are outside M0 and must not be implied by this job.

## Decision

- Pin Rust `1.93.1` with `rustfmt` and the `wasm32-unknown-unknown` target in `rust-toolchain.toml`.
- Run one least-privilege macOS PR job invoking only `./script/check.sh --m0-native`.
- Pin the checkout action to an exact upstream commit and grant only read access to repository contents.
- Install only the shell linters required by the repository gate. No CI secret, signing identity, Cloudflare credential, deployment permission, artifact publication, or external write is admitted.
- Keep the CI receipt named as an M0 native proof and preserve its explicit exclusion list.

## Alternatives

- An unpinned Rust channel is simpler but makes binding generation and compiler behavior drift invisibly.
- Separate Rust and Swift jobs improve fault isolation but duplicate the exact staged-boundary proof and can falsely suggest that independently built halves were integrated.
- A packaging or notarization job would cross an unresolved release boundary and require protected credentials.

## Consequences

Every PR receives one integrated development proof on a macOS runner. The hosted runner image and Xcode patch version can still change; the workflow proves compatibility with that observed runner, not bit-for-bit artifact reproducibility. Future production packaging needs a separate ADR, isolated credentials, artifact identity, and release-only proof.

## Security and privacy

The workflow receives no secrets, requests read-only repository contents, and exercises no media, user data, network provider, deployment, or signing path. Third-party action code is limited to the official checkout action pinned by commit.

## Migration and rollback

A reviewed dependency/toolchain update changes the pin and lockfile together and reruns the full M0 gate. Rollback reverts this ADR, toolchain file, and workflow without altering product or external state.

## Proof

The local source gate must pass before commit. The hosted proof is established only when the exact PR head reports the `SwiftUI / Rust / UniFFI` job green. A local run does not prove hosted CI, and a hosted green job does not prove signing, distribution, deployment, capture, recovery, or release.
