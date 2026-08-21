# ADR 0014 — Intelligence Providers, Scope Receipts, and Injection Defense

- Status: Accepted for Milestone 4 implementation
- Date: 2026-08-20
- Owner/approver: repository operator, through the explicit Milestone 4 Intelligence-as-Annotation instruction
- Founding clauses refined: PRD 2.5–2.10, 15.1–15.3, 15.7–15.9, 17.8–17.10, 20.1–20.4, 21.3–21.4, 29.6, 31 Milestone 4, 33.5, and 39; DESIGN sections 5, 11–12, and 14
- Supersedes: ADR 0007 only by admitting the outbound-network client entitlement for explicitly authorized Milestone 4 remote review; its capture and network-denial boundaries remain

## Context and evidence

Provider configuration is not permission to disclose a conversation. Transcript, context, notes, declarations, and corrections have different sensitivity, while remote endpoints and model output are untrusted. Prompt injection cannot be solved by asking a model to ignore hostile text; the effective defense is capability denial, explicit data envelopes, constrained output, deterministic validation, and auditable network scope.

Current llama.cpp supports Apple Silicon acceleration, GGUF model files, and grammar/JSON-schema constrained generation. That makes it a suitable in-process local engine boundary, but not a license for arbitrary weights, a localhost server, tool calling, or trust in generated JSON.

## Decision

### Provider interface and execution modes

- Native Rust owns a sealed `IntelligenceProvider` interface: report capabilities, validate configuration, execute one bounded authorized request, cancel, and return a `ProposedDeltaEnvelope`. It receives neither SQLite/storage handles nor generic callbacks. Swift receives coarse progress and receipt projections only.
- The initial local provider embeds a manifest-pinned llama.cpp library in process, using Metal/Accelerate and reviewed data-only GGUF artifacts. Open Scribe does not start `llama-server`, a localhost service, a CLI child process, or an arbitrary model/plugin loader. Exact model weights remain Unavailable until their source, license, redistribution terms, byte length, SHA-256, tokenizer/chat template, engine compatibility, structured-output conformance, Apple-Silicon performance, and evidence-grounding evaluation are accepted in the model manifest.
- Local live intelligence is optional, event-driven, debounce/budget limited, and uses a latest-batch queue bounded independently of capture. It may drop or defer derived work under pressure. Local review runs after Stop or by explicit command.
- Remote intelligence is review-only in Milestone 4 and runs after Stop or by explicit user command. A future live remote mode requires a new approved scope and latency/privacy proof. Every remote adapter uses the same Rust request/delta contract.
- Apple-only system models may later use a narrow Swift adapter, but Rust still constructs the authorized evidence envelope, validates the returned delta, and owns persistence. Availability never changes evidence or authorization semantics.

### Provider configuration versus content authorization

- Configuring provider, model, endpoint, credential, or budget sends no session content and grants no content category. The UI says `Provider configured — no conversation content authorized` until a run authorization exists.
- Every invocation requires an `IntelligenceRunAuthorization` binding session, provider/model, local or remote execution, purpose, prompt-template/schema versions, endpoint origin when remote, expiry, call/token/cost ceilings, exact evidence manifest, and individually granted categories.
- Categories are `FinalTranscript`, `DraftTranscript`, `ContextText`, `UserNotes`, `ParticipantTopic`, `HumanCorrections`, and `ExistingDerivedClaims`. Each is independently off until selected. `ContextText` never includes pixels; transcript permission never includes context; Final never includes Draft; and correction permission is distinct from transcript text.
- `Audio` and `Snapshots` are known but structurally unavailable to Milestone 4 intelligence providers. Enabling them later requires a new ADR, UI disclosure, transport/retention proof, and explicit authorization; a provider capability flag cannot activate them.
- Local execution also receives an explicit session scope, although `network_used` remains false. A user may save a local privacy profile. Remote grants are confirmed per review run and never inferred from a local profile, previous session, configured provider, or API key.
- The canonical request builder materializes only authorized records into a bounded content envelope. It records category, evidence/reference IDs and revisions, byte/token counts, redactions, and SHA-256 for every included part. Providers cannot request more evidence during a run.

### Remote transport and secrets

- Milestone 4 adds only the App Sandbox outbound-network client entitlement. There is no listening/server entitlement. With remote intelligence disabled or unauthorized, the app opens no provider connections; capture, storage, playback, transcription, OCR, local review, and export remain network-independent.
- Built-in adapters pin declared HTTPS origins and reject cross-origin redirects. A custom provider requires an explicit HTTPS origin with no embedded credentials; changing origin invalidates the authorization. Private, loopback, link-local, non-HTTPS, proxy, and custom-CA endpoints remain unavailable in the initial release rather than weakening transport policy.
- Provider secrets live in macOS Keychain. Swift retrieves a named secret only for an authorized run and passes bounded request-scoped bytes over the coarse native boundary; neither side converts it to user-visible text, stores it in SQLite, or logs it. Copies are released and best-effort cleared immediately after request construction. Receipts contain credential identity/fingerprint metadata, never the secret.
- A remote transport may contact only the authorized provider origin. It does not follow model-supplied URLs, fetch citations, resolve attachments, or make secondary tool calls. Timeouts, cancellation, response-size limits, token/cost ceilings, and retry policy are fixed by the adapter and receipt. Automatic retries reuse the same idempotency/run ID and scope; expanded scope requires a new authorization.

### Model receipts

- Every local or remote attempt appends a user-readable `ModelRunReceipt` before execution and finalizes it after cancellation, failure, rejection, partial acceptance, or success. A crash leaves an explicit Interrupted receipt.
- The receipt records run/session/provider/model/engine IDs and hashes, local/remote mode, purpose, authorization ID, exact category manifest and evidence digests, prompt-template/schema/validator versions and hashes, endpoint origin, start/end, request/response byte hashes and sizes, network used, token/cost/budget values when known, status, timeout/retry count, accepted/rejected operation counts, and stable validation codes.
- Receipts do not duplicate raw prompt, transcript, OCR, response prose, credentials, or secrets. The exact input can be reconstructed only while its authorized evidence remains available and matching; otherwise the receipt states why replay is unavailable.

### Prompt-injection and untrusted-output boundary

- Transcript, OCR/context, notes, imported text, model output, and remote error bodies are untrusted data. The request builder serializes them as typed, length-bounded evidence records outside the immutable instruction template; content cannot add or replace system policy, schemas, categories, or capabilities.
- No provider is offered tools or function calls. Open Scribe has no model-accessible shell, files, email, calendar, contacts, arbitrary network, capture controls, storage API, or command dispatcher. Tool-call-shaped output is rejected as malformed data even if a remote API returns it.
- Local generation is constrained to the delta JSON Schema/grammar. Remote adapters request provider-native structured output when available, but all output is still parsed by a bounded Rust decoder and validated under ADR 0013. Unknown fields, excessive depth/count/length, invalid UTF-8/numbers, fabricated IDs, unauthorized evidence, unexpected URL/executable-action fields, and stale revisions are rejected.
- The prompt template, output schema, tokenizer/chat template, and validator are versioned and hashed. Model-supplied text never becomes a later instruction template. Output URLs remain inert text. There is no autonomous repair loop that feeds validation errors back with broader data or permissions.
- Adversarial fixtures include direct and indirect instructions in transcript/OCR, delimiter and JSON closure attempts, fake system messages, fabricated evidence IDs, tool-call objects, shell/file/email/calendar requests, URLs, scope-expansion requests, and instructions to delete or overwrite evidence. Passing means no capability invocation, no unauthorized category in the request, and no durable write except a valid evidence-backed delta plus receipt.

## Alternatives

A generic OpenAI-compatible client alone does not express authorization or evidence lineage. Per-provider storage writers make validation optional. Treating local execution as implicitly authorized hides scope. Tool calling creates an unnecessary capability channel. A localhost llama.cpp server violates the product architecture and expands attack surface. Prompt prose without capability isolation cannot defend against hostile observed content. Packet capture alone cannot reveal encrypted application categories, while an application receipt alone cannot prove the network destination.

## Consequences

Remote review has deliberate preflight friction and cannot send audio or pixels in Milestone 4. Provider adapters remain small because policy, envelope construction, schemas, and validation are shared. Some compatible endpoints are intentionally unsupported initially. Exact local weights remain a separately proven supply-chain choice, so the architecture may be accepted while local intelligence truthfully remains Unavailable.

## Security and privacy

The trust boundaries are evidence store → authorized envelope → provider and untrusted provider response → validator → proposed/accepted memory. Least privilege is enforced by absence of tools, category-specific grants, bounded parsing, endpoint confinement, Keychain secrets, content-free receipts/logs, and no direct persistence. These controls reduce prompt-injection impact without claiming that model behavior itself is trustworthy.

## Migration and rollback

Provider, authorization, envelope, prompt, receipt, and delta schemas version independently. Adapter upgrades cannot reuse an incompatible authorization. Rollback disables the adapter/network entitlement path, marks affected models Unavailable, and preserves evidence, claims, adjudications, and receipts. Removing a provider deletes its credentials/configuration only through explicit user action and never deletes evidence.

## Proof

Acceptance requires local review under network denial; provider-disabled operation; timeout, cancellation, malformed/oversized response, cost exhaustion, and interrupted-run receipts; and the complete injection fixture corpus with tool/network/storage probes proving no unauthorized action or write. Every accepted model operation must validate against real authorized evidence, and unsupported or fabricated material claims must be rejected or visibly isolated from canonical memory.

Provider-scope proof combines three planes: the canonical request manifest and body capture identify exact categories/bytes/digests; a controlled HTTPS test provider independently records the received body hash and categories; and packet capture proves the only external connection was to the authorized origin with matching timing/byte envelope. Tests cover every category alone and in combination, configured-but-unauthorized provider, local authorization reused against remote, redirects, endpoint changes, retries, and deletion/revocation during a run. No TLS weakening is accepted for production.

Human acceptance/correction/rejection must survive provider/model changes and reprocessing. Deleting model state/provider configuration must leave evidence intact. A real artifact with every intelligence provider disabled must still pass the recorder, recovery, playback, transcript/context review, search, correction, and export journey. Unit tests alone do not close the provider, network, injection, accessibility, or disabled-mode gates.

## Primary references

- llama.cpp repository and Apple-Silicon/GGUF runtime: https://github.com/ggml-org/llama.cpp
- llama.cpp grammar-constrained generation: https://github.com/ggml-org/llama.cpp/blob/master/grammars/README.md
- NIST AI 600-1, Generative AI Profile: https://nvlpubs.nist.gov/nistpubs/ai/NIST.AI.600-1.pdf
