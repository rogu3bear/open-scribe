# Open Scribe Website

**Status:** functional Milestone 0 source and local build proof; not deployed.

This directory contains the stateless Leptos 0.8 and Cloudflare Worker
foundation. It renders useful product identity and honest development status in
SSR HTML, builds the hydration bundle, fingerprints client assets, and compiles
the Worker entrypoint. Routes, navigation, the Content Security Policy, and
response headers follow ADR 0015; hydration starts from a hashed same-origin
boot module, so release SSR admits no inline script. It contains no database, intake form, user session,
native bridge, media path, or browser recording demonstration.

Run the repository-owned build from the repository root:

```bash
./script/build_web.sh
```

The receipt is `WEB_BUILD_GREEN`. Generated local output includes:

- `target/web-ssr/index.html`, a useful no-hydration SSR snapshot;
- `target/site/`, the hashed hydration, boot, and stylesheet assets;
- `web/build/`, the Worker bundle and static-asset routing shim.

The command does not invoke Wrangler or access Cloudflare. A build is not a
deployment, a public route, or proof of any native capability. ADR 0003 owns the
selective import, upstream-sync policy, toolchain pins, and rollback.
