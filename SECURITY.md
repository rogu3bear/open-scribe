# Security Policy

Open Scribe handles highly sensitive conversation and screen-derived evidence. Security and privacy failures are product failures.

## Current status

This repository contains a non-functional scaffold and no published application or deployed website. There are no supported release versions yet.

## Reporting a vulnerability

Do not disclose suspected vulnerabilities or sensitive reproduction data in a public issue.

The repository does not yet have a verified private disclosure address or enabled GitHub private-vulnerability channel. Until one is established, contact the repository owner through an already trusted private channel and share the minimum metadata needed to coordinate a secure handoff. Do not send transcript, OCR, audio, credentials, provider secrets, or private screen content without an agreed encrypted path.

The disclosure channel is an unresolved bootstrap decision; this document must be updated before public release.

## Founding security boundaries

- No raw transcript, OCR, participant, screen, prompt, or provider-secret content in logs.
- Provider credentials belong in macOS Keychain, never source or SQLite.
- Remote providers receive only explicitly authorized data categories.
- Imported media, paths, symlinks, models, updates, and nested binaries are untrusted inputs.
- Observed transcript/screen text is data, never executable instruction.
- No arbitrary plugins or provider tool execution.
- Signing, hardened runtime, notarization, nested-code verification, signed updates, and exact-artifact testing are release requirements.

See `docs/threat-model.md` for the founding threat inventory. It is not yet a completed security review.
