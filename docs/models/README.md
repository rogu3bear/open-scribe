# Model Authority

No model runtime or model weight is implemented, downloaded, bundled, or
approved. ADRs 0008 and 0014 select intended engines and accepted artifact
formats; exact weights remain unavailable until their supply-chain and runtime
proof passes.

ADR 0017 assigns the future machine-readable authority to
`docs/models/manifest.v1.json`. It must record for every model:

- stable identifier and purpose;
- upstream source, revision, file hashes, and size;
- code and weight licenses;
- supported architectures and minimum resources;
- local or remote execution;
- provenance and prompt-template compatibility;
- download, partial-resume, verification, deletion, and cache behavior;
- whether the model may be included in a distributed artifact.

Recording must work without a model. No weight may enter the repository or release until its license and distribution treatment are reviewed.
