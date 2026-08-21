# ADR 0008 — Local ASR and Model Supply Chain

- Status: Accepted for Milestone 2 implementation
- Date: 2026-08-20
- Owner/approver: repository operator, through the explicit Milestone 2 Evidence Ledger instruction
- Founding clauses refined: PRD 2.5–2.6, 12, 18.1, 21.3–21.5, 23, 31 Milestone 2, 33.4, 33.7, and 39
- Supersedes: nothing

## Context and evidence

Milestone 2 needs offline transcription without Python, accounts, services, or a model bundled into every app download. Engine code and model weights are separate licensed artifacts. Capture and recovery must remain functional when a model is absent, disabled, corrupt, removed, or too slow.

Primary-source review establishes: whisper.cpp and OpenAI Whisper are MIT-licensed; whisper.cpp supports Apple Silicon through Accelerate and Metal and consumes converted GGML weights; Silero VAD is MIT-licensed and publishes ONNX models; WeSpeaker code is Apache-2.0, while its pretrained-model documentation says each weight follows its training dataset’s license.

## Decision

### Engine and formats

- `open-scribe-asr` implements the Rust `SpeechRecognizer` capability through a narrow C wrapper around a pinned whisper.cpp release/commit. Build the C/C++ engine in-process; no executable, daemon, localhost service, Python runtime, shell command, or dynamically downloaded code is allowed.
- Use Metal and Accelerate on Apple Silicon. Core ML is deferred: its conversion toolchain introduces Python and its current whisper.cpp guidance recommends newer macOS behavior than the accepted macOS 13 floor.
- Accepted ASR artifacts are manifest-pinned whisper.cpp GGML files: unquantized/f16 and reviewed `q5_1` variants. Do not accept PyTorch pickle, arbitrary GGUF, Core ML packages, or user-supplied executable model code in Milestone 2.
- Initial profiles are `balanced-en` (`small.en`, q5_1) and `balanced-multilingual` (`small`, q5_1). The user chooses English-only or multilingual before download. The same installed model may serve bounded provisional and final passes; transcription remains Unavailable until a compatible verified model exists.
- `open-scribe-diarize` uses a pinned ONNX Runtime build through Rust for Silero VAD and WeSpeaker ECAPA512 embeddings. ONNX graphs are data-only inputs from the canonical manifest; custom operators are forbidden.

### License and redistribution policy

- The application bundle contains engine code and license notices, but no multi-hundred-megabyte ASR, VAD, or embedding weights by default.
- Every downloadable artifact has a canonical manifest record containing: artifact/model ID, purpose, semantic version, engine compatibility, format/opset, exact byte length, SHA-256, canonical HTTPS URL, upstream URL, upstream revision, author/publisher, license SPDX identifier, complete license/attribution resource, languages, quality posture, and removal group.
- Canonical mirroring or offline bundling is permitted only for artifacts whose exact weight license grants redistribution. MIT, Apache-2.0, BSD, and CC BY artifacts may be admitted with required notices/attribution. Unknown, research-only, noncommercial, no-derivatives, field-of-use, authenticated/gated, or source-ambiguous weights are ineligible.
- WeSpeaker code’s Apache license does not license every weight. The initial ECAPA512 ONNX candidate is admitted only with its exact VoxCeleb-derived CC BY 4.0 attribution and hash. If that chain cannot be reproduced at release review, diarization stays Unavailable rather than substituting an unreviewed model.
- `THIRD_PARTY_NOTICES.md` and an in-app model detail view expose engine and installed-weight licenses separately. Legal review remains a release gate; this ADR is not legal advice or final clearance.

### Download, verification, storage, and removal

- A checked-in, release-signed model manifest is the sole catalog authority. Runtime never trusts a remote catalog to add or alter a model.
- Download to `<model>.part` in the managed Models staging directory. Resume only when URL, ETag/Last-Modified, expected length, and manifest identity still agree; otherwise discard the partial.
- Stream SHA-256 while downloading, then independently hash the completed bytes. Verify exact length, hash, model header/ONNX graph constraints, engine compatibility, and a one-second known-answer inference before installation.
- Synchronize the completed file and directory, then atomically rename into `Models/<model-id>/<version>/`. Only the final verified path is loadable. Never execute or memory-map a partial/unverified artifact.
- Persist installation receipt, verification time, manifest version, hash, license, and self-test result in Rust storage. Reverify before first use after app/model migration and after filesystem metadata indicates change.
- Removal first blocks new runs, waits for or explicitly cancels active runs, unloads the model, then moves the version directory to Trash where practical. Partial downloads and corrupt quarantine files may be purged directly after an explicit user action. Recording never waits for removal.

### Resource isolation

- Model download, verification, ASR, VAD, embeddings, diarization, indexing, and export run below capture/media priority with bounded concurrency and memory budgets.
- Media capture never waits on an inference queue, model lock, download, progress callback, or database read transaction. Under pressure, drop provisional work first; pause final processing second; never drop captured media.
- The model manager exposes `Unavailable`, `Downloading`, `Verifying`, `Installed`, `Failed`, and `Removing`. Model state never changes session lifecycle or media durability.

## Alternatives

PyTorch/OpenAI’s Python runtime violates the product boundary. Apple Speech would weaken offline determinism and model identity. Core ML-only weights complicate macOS 13 and reproducible conversion. Bundling several models inflates every download. Arbitrary user models make parsers, licenses, compatibility, and support unbounded. Treating repository license as weight license is legally unsafe.

## Security and privacy

Inference is in-process and offline. Models are untrusted binary data: downloads are length-bounded, hashed, format-validated, quarantined until verified, and never receive filesystem/network capabilities. Runtime download networking is isolated from recording and disabled during the network-denial proof after installation.

## Migration and rollback

Manifest and model-store schemas are versioned. Engine upgrades declare compatible model revisions and rerun known-answer tests. Rollback may retain verified older engine/model pairs side-by-side; it never silently loads a model under an incompatible engine. Disabling this ADR leaves recording/playback intact and transcript state Unavailable.

## Proof

Acceptance requires clean-install download/resume/hash mismatch/size mismatch/truncated file/wrong model/header failure/known-answer failure/removal/re-download cases; offline final transcription under network denial; codesigned artifact loading; memory/thermal pressure while recording; and proof that missing, failed, disabled, or removed models do not affect capture, durability, recovery, or playback. Release proof must bind every shipped or mirrored byte to its manifest, hash, source, license, and notice.

## Primary references

- whisper.cpp repository and model format: https://github.com/ggml-org/whisper.cpp
- whisper.cpp MIT license: https://github.com/ggml-org/whisper.cpp/blob/master/LICENSE
- OpenAI Whisper MIT license: https://github.com/openai/whisper/blob/main/LICENSE
- Silero VAD MIT license: https://github.com/snakers4/silero-vad/blob/master/LICENSE
- WeSpeaker Apache-2.0 license: https://github.com/wenet-e2e/wespeaker/blob/master/LICENSE
- WeSpeaker pretrained-model licensing: https://github.com/wenet-e2e/wespeaker/blob/master/docs/pretrained.md
- ONNX Runtime MIT-licensed repository: https://github.com/microsoft/onnxruntime
