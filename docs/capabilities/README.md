# Capability Claim Authority

`manifest.v1.json` is the checked claim vocabulary defined by ADR 0015. It is
truthful about the present candidate: the native shell, short microphone plus
all-authorized system-audio capture, and atomic two-track forced-termination
recovery are development `Fixture` capabilities. Source-loss continuation,
transcription, conversation management, context, and intelligence remain
`Unavailable`.

This manifest is not runtime proof. A future release build must emit
`capabilities.runtime.json` from a Rust compile-time implementation registry and
the release verifier must reject missing, extra, stronger, or differently
scoped entries. That registry and equality proof do not exist yet.
