# Milestone 0 CI

`m0-native.yml` runs the complete bounded native proof on pull requests and on
`main`. It has read-only repository permission, receives no secrets, pins its
only action by commit, and invokes `./script/check.sh --m0-native`.

The M0 gate includes scaffold, native Rust, WASM-safe Rust, Swift/macOS, UniFFI
consistency, exact development-process, and all-three-scene checks. It explicitly
excludes the website, protected product capabilities, packaging, signing,
notarization, deployment, and release.

Later milestones must add separate jobs for Leptos SSR/hydration/Worker builds,
security/dependency audit, fixtures, packaging smoke, and release-only
notarization. Signing material may never enter the untrusted pull-request job. A
missing job may not be represented as green.
