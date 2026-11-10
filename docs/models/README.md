# Model Authority

ADR 0017 assigns machine-readable authority to
`docs/models/manifest.v1.json`, compiled into `open-scribe-models` as the only
runtime catalog. It records the two ADR 0008 ASR profiles, `balanced-en`
(`whisper-small.en-q5_1`) and `balanced-multilingual` (`whisper-small-q5_1`),
with their pinned upstream revision, exact byte length, SHA-256, GGML header,
license, and download origin. Both have `review_state: Pending`; neither is
bundled, mirrored, or approved for release.

`open-scribe-models` implements catalog validation, the staging `.part` path,
staging from a user-chosen file, the ADR 0008 resume rule, verification of
length, header, engine compatibility, and digest, atomic installation of the
exact verified file, and quarantine of an installed version. It never
downloads, maps, loads, or executes a model. `open-scribe-core` plans an
explicit download into that partial and installs either the partial or a
chosen file only after verification and a one-second decode self-test in the
whisper.cpp 1.8.3 engine. It reverifies the installed bytes before every load.
The app's Download button fetches one catalog origin into the partial. No
validator is stored yet, so a new download restarts instead of appending.
Install from File still accepts a file the user already has. The self-test
decodes silence rather than a speech known answer. Both catalog entries stay
`review_state: Pending`, and the manifest capability stays Unavailable until
release proof exists. Recording does not download a model.

Each admitted entry must record:

- stable identifier and purpose;
- upstream source, revision, file hashes, and size;
- code and weight licenses;
- supported architectures and minimum resources;
- local or remote execution;
- provenance and prompt-template compatibility;
- download, partial-resume, verification, deletion, and cache behavior;
- whether the model may be included in a distributed artifact.

Recording must work without a model. No weight may enter the repository or release until its license and distribution treatment are reviewed.
