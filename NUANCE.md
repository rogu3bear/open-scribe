# Open Scribe Nuance

> **Budget:** 500 words plus compact proven entries.

Nuance records counterexamples to plausible interpretations, not requirements
or current capability certification. Support is labeled by proof plane.
Historical investigations remain in [Testing](docs/TESTING.md).

### An existing host proc macro need not be loadable

**Experimentally reproduced, exact retained artifacts:** the cold-web-before
`rustversion` dylib exists with its expected hash, but `dlopen` rejects its
misaligned LINKEDIT string pool. The hash-bound cold-web-after control loads.
`ruby script/check_nuance.rb --proc-macro` checks both. This establishes an
existence-versus-loadability counterexample on this host; it does not reproduce
a fresh cold build or prove that every compiler/SDK combination has the fault.
The release build-dependency strip policy is current configuration, not loader
proof. Build history: [candidate infrastructure](docs/TESTING.md#september-29-2026--candidate-build-infrastructure).

### Releasing reserve space does not prove replacement allocation

**Statically established:** `storage_reserve.rs` validates the owned allocation,
unlinks it, closes its descriptor, then syncs the directory. These steps precede
journal replacement; they do not establish that replacement-file creation will
succeed. `journal_replacement.rs` retries only create-new ENOSPC, with 50 waits
of 20 ms and a final attempt. Persistent exhaustion remains an error; this is
one second of requested waiting, not a wall-clock completion guarantee.
Existing tests cover transient success, the strict attempt bound, and unrelated
errors. None qualifies full-volume native journaling. Earlier truncation and
retired fallback investigations remain in [APFS history](docs/TESTING.md#september-29-2026--apfs-exhaustion-and-scene-launch-repair);
the dedicated-volume test remains explicitly ignored by default. It was not
rerun in this audit.

### Segment generation and capture identity have different lifetimes

**Statically established:** `SegmentedCAFWriter` advances authorization when it
opens a successor segment. `LiveMicrophoneRecordingController` accepts health
observations against the identity bound when capture starts plus an increasing
observation sequence, rather than the writer's current segment generation.
Comparing a route-loss observation with the successor's generation would discard
an observation from the same capture. The existing
`RecorderPauseResumeTests.testRouteInterruptionAfterRotationDegradesMicrophoneCapture`
tests that specific counterexample. Its source was inspected; it was not
executed in this audit, and does not establish every route/format change or
real-device continuation.

### Zero sampled sockets does not establish zero connection attempts

**Experimentally reproduced, isolated timing fixture:** samples at 0, 1, and
2 seconds miss a socket present only from 0.2 to 0.3 seconds. Run
`ruby script/check_nuance.rb --sampling`. The local-only harness samples sockets
once per second; its sandbox refusal and static networking checks are separate
evidence. Sampling establishes only absence at the sampled instants, not an
attempt count. The older universal claim about unprivileged denial logs is
removed: a current empty-process log query cannot establish denial behavior.

The checker reports **PASS** when its bounded counterexample is established,
**FAIL** when contradicted, and **STALE** when required artifact identity or
observation is unavailable. Missing or changed evidence never becomes PASS.
