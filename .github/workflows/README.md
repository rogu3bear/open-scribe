# CI Skeleton

No executable GitHub Actions workflow is installed yet.

The first workflow must run `./script/check.sh --scaffold` and identify itself as scaffold validation only. Product CI must later add distinct required jobs for native Rust, WASM-safe Rust, Swift/macOS, UniFFI consistency, Leptos SSR/hydration/Worker builds, security/dependency audit, fixture tests, packaging smoke, and release-only notarization.

Action revisions, runner image, permissions, fork behavior, secret boundaries, and signing isolation must be explicitly selected and pinned before enabling CI. A missing job may not be represented as green.
