# ADR 0015 — Capability-True Website and Shared Content

- Status: Accepted for Milestone 5 implementation, gated on Milestones 1–4 runtime proof
- Date: 2026-08-20
- Owner/approver: repository operator, through the explicit Milestone 5 public-release instruction
- Founding clauses refined: PRD 2.10, 10, 22–23, 25.3–25.4, 29.8, 31 Milestone 5, 33.8, and 39; DESIGN sections 5, 7, 10–12, and 14
- Supersedes: ADR 0003 only where it intentionally stopped the final website visual direction and demonstration; its selective-import, stateless, local-build, and no-implicit-deployment decisions remain

## Context and evidence

The M0 website deliberately says that no public product exists. A release website must become polished without becoming a parallel capability authority or a generic product-marketing layer. Its claims must follow the exact distributed binary; privacy, terms, and security text must not fork; the demonstration must explain native behavior without pretending the browser captures anything; and SSR/no-script users must receive the complete meaning.

Cloudflare currently recommends Workers Static Assets for new static/full-stack sites and requires Worker-generated SSR responses to attach their own headers rather than relying on `_headers`. Open Scribe already has a stateless Leptos Worker/Assets foundation, so Milestone 5 extends that boundary without adding D1, accounts, analytics, or application backend state.

## Decision

### Capability and content authorities

- `docs/capabilities/manifest.v1.json`, validated by `open-scribe.capabilities/v1`, becomes the checked capability-claim authority. Each entry contains stable ID, maturity (`Unavailable`, `Fixture`, or `Available`), platform/minimum OS, permissions, local/network behavior, accepted inputs/outputs, user-facing terminology, and the exact proof-receipt class required before `Available`.
- The Rust core owns a compile-time implementation registry. A release build emits `capabilities.runtime.json` from actual registered code. Release verification rejects missing, extra, weaker, or differently scoped runtime entries and binds the agreed manifest hash into the app bundle and release manifest.
- The website compiles the exact verified release capability manifest, not the branch's aspirational prose. A page content block that describes a capability names its required capability IDs and permitted maturity; the build fails if its claim exceeds the release manifest. Unavailable capabilities are omitted or explicitly described as unavailable.
- `docs/legal/privacy.md`, `docs/legal/terms.md`, and `SECURITY.md` remain byte authorities. The app and website use deterministic renderers over the exact files and expose their versions/hashes. Release requires adopted status, effective/revision date, responsible approver, and a verified private security-disclosure channel. The current drafts and unresolved disclosure channel block release.
- Documentation, terminology, export schemas, model manifests, third-party notices, and release metadata remain checked sources. The website may link or render them but may not maintain rewritten factual copies.

### Routes and composition

- Required SSR routes are `/`, `/product`, `/record`, `/meeting`, `/privacy`, `/how-it-works`, `/download`, `/documentation`, `/terms`, and `/security`; GitHub remains an external canonical repository link. Deep links and a truthful 404 render through SSR before hydration.
- Primary navigation is Product, How It Works, Privacy, Documentation, and Download. Record and Meeting are explicit Product destinations. Terms, Security, GitHub, checksums, model manifest, and notices live in the document footer or relevant page, not a crowded primary bar.
- Home establishes the private Mac field-instrument/evidence-ledger thesis, then Record, Meeting, privacy/local-first behavior, the explanatory demo, and the verified download. Record leads with capture truth, durability, recovery, local transcript, and source identity. Meeting leads with explicit scope, sparse context, evidence lineage, and optional interpretation. Neither page shows an unavailable feature as a functioning screenshot.
- How It Works is chronological: authorize → establish durable capture → review evidence → optionally add context/intelligence. Download renders only a verified release manifest: version/build, Apple Silicon/macOS floor, artifact size/SHA-256, release notes, model-not-bundled posture, and verification help. Without that manifest it says `No public release is available` and exposes no dummy button.
- Privacy and Terms render the exact adopted legal source with a generated table of contents. Security renders the exact policy and verified disclosure route. Documentation is an index over checked repository/user documents and never a second product specification.

### Final visual system

- Use the exact DESIGN palette: light `#F7F7F5/#FFFFFF/#171714/#5C5C57/#0057B8` and dark `#11110F/#1B1B18/#F5F5F0/#B8B8B0/#6FB1FF`, plus only the approved semantic recording/warning/failure/success/divider roles. There is no gradient, ornamental accent, glass, grid, or AI glow.
- Use `-apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif`; no downloaded font. Body and evidence text target 60–85 characters per line. Type scale, weight, and whitespace establish hierarchy.
- Use the shared 4-point spacing scale. Website buttons/inputs use 6 px radii; grouped screenshots/demonstrations use 8 px; fully rounded shapes are only real tags/statuses. Sections are document composition, not a card wall.
- Narrow is one reading column; medium may pair text/media while preserving source order; wide caps reading measure and uses extra width for evidence relationships. Navigation becomes a standard disclosed menu without hiding Privacy, Download, GitHub, or Documentation. The complete route matrix must reflow at 200% and 400% zoom.

### Static-first explanatory demonstration

- SSR emits the complete four-step explanation as semantic heading, ordered list, named displays, context event, transcript range, and evidence-linked Loose End. A `<noscript>` user loses no content or evidence relationship.
- Hydration lazily adds an explicitly labeled `Explanatory demonstration — not browser capture` interaction after user intent or near-viewport idle loading. It simulates pointer dwell only inside its illustration and calls no capture, display, microphone, media, provider, storage, or analytics API.
- Keyboard controls select Previous/Next step; focus and screen-reader order remain the SSR order. Pointer motion is never announced. Reduced Motion removes pointer travel/glow rise and switches among complete static frames. Failure to load WASM leaves the static explanation intact.

### CSP, caching, privacy, and performance

- Worker SSR responses set: `default-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'; object-src 'none'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self'; img-src 'self' data:; connect-src 'self'; font-src 'none'; media-src 'none'; manifest-src 'self'; upgrade-insecure-requests`. There is no `unsafe-inline`, arbitrary third-party origin, form endpoint, or CSP reporting service carrying paths/content.
- Responses also set `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin`, `Cross-Origin-Opener-Policy: same-origin`, `Cross-Origin-Resource-Policy: same-origin`, and a Permissions Policy denying camera, microphone, display capture, geolocation, and other unused sensors. Preview/workers.dev hosts add `X-Robots-Tag: noindex`.
- Fingerprinted JS/WASM/CSS/images use `public, max-age=31536000, immutable`. SSR HTML, 404s, `/download/latest`, and current release pointers use `no-store`. Versioned release manifests/checksums are immutable; the signed appcast uses `no-cache, must-revalidate` plus ETag. Worker-generated responses attach their own headers; `_headers` covers only static assets.
- No D1, cookies, forms, account, third-party analytics, telemetry, remote fonts, autoplay media, or third-party scripts are admitted. The Worker stores no request-scoped mutable module state and performs no background calls.
- Per-route budgets are 64 KiB uncompressed useful SSR HTML, 24 KiB Brotli CSS, and 250 KiB Brotli combined initial JS/WASM; the optional demo/media budget is lazy and separately reported. Acceptance targets LCP ≤2.5 s, INP ≤200 ms, and CLS ≤0.1 under the recorded mobile profile, while source review and a single synthetic score remain insufficient.

## Alternatives

Hand-authored marketing copy drifts from the binary. A CMS/database creates a needless privacy and abuse surface. Client-only rendering breaks first response and no-script truth. A fake product video or browser capture demo overclaims capability. Third-party fonts/analytics weaken performance and local-first posture. A release button without a verified manifest turns intention into a public artifact claim.

## Consequences

Release packaging must finish before final website copy can become Available, so the public site is the last consumer rather than the roadmap driver. Content blocks carry capability dependencies and legal pages may look less promotional. The hydration bundle accepts a narrowly scoped WASM CSP exception, while every meaningful page and demonstration remains complete without it.

## Security and privacy

The site accepts no user content and stores no personal data beyond unavoidable Cloudflare request processing governed by the adopted notice. Capability, legal, model, and release hashes make public drift detectable. The demo has no native/browser capture power. CSP, permissions policy, same-origin resources, no forms/analytics, and stateless execution keep the edge surface narrow.

## Migration and rollback

M0 truthful routes remain until a verified release manifest exists. Migration adds the capability schema/consumer and route composition before changing public claims. Rollback deploys the preceding content-addressed site bundle and its matching release manifest; it never points a previous site at a newer unverified binary. Legal rollback is a new versioned adoption, not an unrecorded text replacement.

## Proof

Acceptance requires exact SSR route, deep-link, 404, hydration-failure, no-script, keyboard, screen-reader, reduced-motion, 200%/400% reflow, CSP, cache, canonical/OG metadata, content budget, Core Web Vitals profile, and no-template/no-fake-feature tests. Every factual capability sentence must resolve to an `Available` release-manifest entry whose runtime registry and proof receipt match the distributed app hash.

The complete DESIGN rendered website matrix is mandatory. Privacy, Terms, and Security bytes/hashes must equal the adopted sources in the app bundle and website response. Download remains unavailable until exact artifact proof. Deployment and canonical readback are owned by ADR 0017 and require separate explicit authorization.

## Primary references

- Cloudflare Workers best practices: https://developers.cloudflare.com/workers/best-practices/workers-best-practices/
- Cloudflare Workers Static Assets headers: https://developers.cloudflare.com/workers/static-assets/headers/
