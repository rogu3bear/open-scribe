# ADR 0001 — Milestone 0 Native Shell and UniFFI Lifecycle

- Status: Accepted for Milestone 0 only
- Date: 2026-08-20
- Owner/approver: repository operator, through the explicit M0 native-proof implementation instruction
- Founding clauses refined: PRD 21.1–21.4, 25.1–25.3, 31 Milestone 0, 34, and 39
- Supersedes: nothing

## Context and evidence

Milestone 0 requires a primary SwiftUI window, `MenuBarExtra`, Settings, and Swift rendering real Rust state through coarse UniFFI. The repository had only reserved roots and placeholder crates. Distribution identity, sandboxing, signing, capture, persistence, providers, and ML remain unresolved and outside this decision.

## Decision

- Use a SwiftPM macOS 13 executable with explicit primary, menu-bar, and Settings scenes.
- Keep all presentation in Swift. Expose one immutable Rust `NativeStatus` record through one synchronous `native_status` query.
- Generate Swift bindings in UniFFI library mode from the built Rust static library, then deterministically normalize the Swift and C sources with toolchain formatters. Keep generated Swift/C files as checked source and verify regeneration byte-for-byte.
- Assemble an unsigned development `.app` with bundle identifier `app.open-scribe.dev`. This is not the future distribution identifier.
- Use no entitlements or sandbox profile because M0 accesses no protected resource.
- Prove the boundary with Rust tests, a Swift test that calls generated bindings, binding-consistency comparison, Swift build, exact development-app process observation, and low-frequency local scene logs for the primary window, menu-bar label, and Settings scene. A debug-only argument opens Settings through SwiftUI for proof and is absent from release builds.

## Alternatives

- An Xcode project would add project-file generation before it earns value.
- An XCFramework would better fit distribution, but M0 needs only the host architecture and no release artifact.
- Handwritten C bindings would not prove the required UniFFI boundary.
- A dynamic library would add runtime embedding and signing work to a static M0 proof.

## Consequences

The development build is shell-first and reproducible on the current Apple-Silicon host. The checked generated files make boundary drift visible. This does not decide universal binaries, release packaging, the permanent bundle identifier, sandboxing, entitlements, signing, or notarization.

## Security and privacy

The exported record contains only product/build capability posture. No user data, media, filesystem path, credential, network operation, or observation crosses the boundary.

## Migration and rollback

Later ADRs may replace SwiftPM packaging, the development identifier, or binding packaging. The Rust API can remain while generated/build artifacts change. Rollback removes this ADR and the M0-only Swift/UniFFI implementation; no stored or external state exists.

## Proof

`./script/check.sh --m0-native` must run the focused Rust test, regenerate and compare bindings, run Swift tests, assemble the development app, launch its exact staged executable, and observe primary-window, menu-bar, and Settings scene logs from that process. Passing proof is local L5 development evidence only, not signing, distribution, capture, or release evidence.
