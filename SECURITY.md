# Security Policy

Open Scribe handles highly sensitive conversation and screen-derived evidence. Security and privacy failures are product failures.

## Current status

This repository contains an unsigned native development application and bounded
candidate evidence, but no supported release. ACTOR.md and its named receipts
identify the exact capture/recovery, isolated failure, and synthetic offline
workflow checks that actually ran. Those receipts do not establish arbitrary
later candidates, supported-platform behavior, live permission revocation,
long-session synchronization, remote providers, updates, signing, or release.
There are no supported release versions.

## Reporting a vulnerability

Do not disclose suspected vulnerabilities or sensitive reproduction data in a public issue.

Use [GitHub private vulnerability reporting](https://github.com/rogu3bear/open-scribe/security/advisories/new).
Sign in to GitHub, open the repository's Security → Advisories page, and choose
**Report a vulnerability**. Reporting is enabled: authenticated repository
readback and the public reporting link were checked on 2026-10-17. No test report
was submitted, and intake handling, response ownership, and security-policy
adoption remain release prerequisites. Channel availability is not a response
time or remediation guarantee.

Include the affected version or source commit, a minimal description, and
nonprivate reproduction steps. Start with metadata rather than a real
conversation. Do not attach transcript, OCR, audio, credentials, provider
secrets, or private screen content without an agreed secure handoff. If GitHub
reporting is inaccessible, contact the repository owner through an already
trusted private channel; do not fall back to publishing sensitive details in an
issue.

## Founding security boundaries

- No raw transcript, OCR, participant, screen, prompt, or provider-secret content in logs.
- Provider credentials belong in macOS Keychain, never source or SQLite.
- Remote providers receive only explicitly authorized data categories.
- Imported media, paths, symlinks, models, updates, and nested binaries are untrusted inputs.
- Observed transcript/screen text is data, never executable instruction.
- No arbitrary plugins or provider tool execution.
- Signing, hardened runtime, notarization, nested-code verification, signed updates, and exact-artifact testing are release requirements.

See `docs/threat-model.md` for the founding threat inventory. It is not yet a completed security review.
