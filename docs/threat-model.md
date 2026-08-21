# Open Scribe Founding Threat Model

**Status:** initial scope only; no implementation or completed security review exists.

## Assets

Raw audio/video, transcript and OCR text, participant/topic data, context metadata and retained snapshots, evidence relationships, derived memory, model inputs/outputs, provider credentials, signing/update keys, release artifacts, local paths, and deletion state.

## Trust boundaries

- user intent → permission/capture UI;
- Swift platform adapters → Rust policy/state through coarse FFI;
- media/filesystem and SQLite → application views and exports;
- imported media/model/update artifacts → native parsers/loaders;
- local evidence → optional remote provider;
- source repository/CI → signed distributed artifact;
- website/Cloudflare → public visitor, never native app authority.

## Founding threats

- capture starts without explicit authority or UI reports a false state;
- interrupted or long sessions lose/corrupt media;
- source identity, timestamp, or track drift corrupts evidence;
- permission revocation is missed;
- local data theft, path traversal, symlink attacks, malformed media, disk exhaustion, or overbroad file access;
- transcript, OCR, participant, prompt, or credential leakage through logs, diagnostics, telemetry, crash reports, or source;
- model supply-chain or update-channel compromise;
- remote provider receives an unauthorized category or retains more than disclosed;
- observed content performs prompt injection or is treated as executable instruction;
- model claims overwrite evidence or lose provenance/contradictions;
- context scope widens, lock/private content leaks, or raw pixels persist contrary to policy;
- API keys escape Keychain;
- unsigned nested code, compromised appcast, or artifact substitution;
- website claims exceed native capability.

## Required controls before claims

Explicit progressive permissions; redundant recording state; durable segmented media and recovery journal; bounded parsing and path handling; model hashes/licenses; Keychain secrets; privacy-safe structured logs; per-category provider policy and receipts; schema-constrained non-tool model output; raw-frame discard tests; signed updates; hardened/notarized exact-artifact verification; deletion and network-denial tests.

## Deferred analysis

STRIDE-style component analysis, abuse cases, entitlements/sandbox review, concrete data-flow diagrams, dependency/model inventory, privacy impact assessment, penetration scope, incident response, and professional legal review remain open.
