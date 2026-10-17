---
artifact: experiment-design-and-component-result
version: "1.0"
created: 2026-10-16
status: component-comparison-complete-human-use-unrun
---

# Reviewed conversation: reliability first, usefulness next

The next product decision is whether Open Scribe makes reviewing a saved
conversation easier enough that an individual Mac operator chooses it again.
The founding preservation requirements remain mandatory regardless of that
answer. Optional Meeting, context, and intelligence work stays in place; this
experiment does not expand it or change any public capability status.

## The smallest recovery comparison

The proposed distinction was preserving the user's intended operation and
reviewed effective document through interruption. The predeclared case was:

1. Track A has a selected Final revision and a human correction. Track B has
   complete compatible hypotheses, but failed before finalization.
2. Accept a manual ResumeIncomplete request. An external parent kills the
   owned child with SIGKILL after durable admission, before finalization.
3. Reopen with automatic work disabled and no recognizer. Resume the durable
   request using retained output.

The comparator is a test-only SQLite reference using ordinary durable manual
jobs, immutable revisions and corrections, retained hypotheses, transactions,
and expected-selection checks. It does not call Open Scribe's scheduling,
planning, or selection code. It represents this logical storage case, not a
second full recorder, recognizer, or commercial application.

Both subjects must preserve A's selection and epoch, correction IDs, effective
text, search result, run count, revision count, and source-audio hashes. B must
become Final without a recognizer or repeated user action. Its earlier failure
must remain recorded. One violated assertion rejects that subject for this case.
A matching comparator falsifies a claimed advantage on this case; it does not
establish equivalence across other failure boundaries or products.

**Observed result: tie.** Both subjects passed. Each resumed one unfinished
track, recognized zero chunks after restart, and needed no repeated user action.
Open Scribe's production components passed the preservation requirements, but
this experiment demonstrated no advantage over the competent baseline. It
measured no latency, ASR accuracy, UI performance, or market outcome.

The executable owner is
`crates/open-scribe-core/src/workflow_recovery_tests.rs`, with the independent
reference in `workflow_recovery_baseline.rs`. Reproduce on a Unix host using:

```sh
cargo test --offline --locked -p open-scribe-core \
  paired_sigkill_preserves_review_and_manual_retry_without_recognition -- --nocapture
```

The helper child is ignored in ordinary test enumeration and invoked only by
the parent with a fresh owned root. The parent observes the durable-admission
checkpoint, kills and waits for its own child, verifies signal 9, then reopens
the same data. An orderly close/reopen is not substituted for process death.

## Real recognition, without installation

`speech_tests::verified_file_import_review_export_preserves_original_evidence`
passed with the already-staged synthetic speech CAF and pinned English model.
It fully verifies the supplied model against the canonical manifest before
loading it read-only. It imports into a temporary production store, obtains a
verified playback lease, transcribes locally, corrects and reopens the document,
searches the correction, resolves original evidence, exports transcript JSON,
copies source audio with the same digest, and renders a WAV. No model bytes
are installed, staged, or downloaded by this test.

```sh
OPEN_SCRIBE_WHISPER_MODEL="/absolute/path/ggml-small.en-q5_1.bin" \
OPEN_SCRIBE_WHISPER_SPEECH_CAF="/absolute/path/speech48.caf" \
cargo test --offline --locked -p open-scribe-core \
  verified_file_import_review_export_preserves_original_evidence -- --nocapture
```

Absent inputs print `IMPORTED_REVIEW_WORKFLOW_SKIPPED`; an ordinary green test
summary alone does not prove real recognition. The explicit input run must
print `IMPORTED_REVIEW_WORKFLOW_GREEN`. The supplied synthetic CAF produced
one segment. Its SHA-256 was
`872f1df49d51851b23881c1fa709564d6f8d190c325a813364c83cd3266605c6`;
the model matched manifest SHA-256
`bfdff4894dcb76bbf647d56263ea2a96645423f1669176f4844a1bf8e478ad30`.

Two initial test assumptions failed and were corrected: normal imports use
the ordinary playback lease rather than the recovered-capture list, and
exports omit the advisory resolver hint while preserving evidence identity.
Neither was a product repair. These component results do not prove native
workflow use, audible playback, an installed model, macOS 13 runtime, signing,
distribution, a permissions matrix, or a long real conversation.

## The next decision: a five-operator repeat-use trial

**Status: not started, 0 of 5 operators. No invitations or observations.**
This is a small decision aid, not statistical market validation. The operator
and four similar individual Mac users are the intended audience. Their
existing review tool is the comparison; do not choose a deliberately weak
baseline. Recruit or contact nobody as a side effect of this document.

Before use, bind the exact qualified artifact and its remaining platform
limits. Obtain deliberate selection of recordings and explicit authority for
any model setup, distribution, or installation the trial needs. Use isolated
libraries. The source-component tests above do not waive those prerequisites.

For each person, prepare two matched tasks on deliberately supplied recordings:
find an agreement, verify it against source audio, correct a transcript phrase,
find the correction again, and export the reviewed result with its evidence.
Use Open Scribe first for two participants and the existing tool first for
three. Supply equivalent starting materials, including transcripts where the
question is review effort. Record recognition/setup time separately rather
than quietly charging it to only one side.

With the person's agreement, record active task time, completed steps,
assistance, repeated work, correction/search/export failures, and whether the
export resolves to the intended audio. Keep source content out of the results
table. Record abandoned tasks and all assistance; exclude neither from the
decision. Do not add telemetry, a server, or a reminder system.

Predeclare the next investment rule:

- Any lost or silently displaced reviewed work, incorrect evidence target, or
  misleading capture state stops expansion and returns work to its owner.
- Continue a focused review-workflow investment only if at least three of five
  people voluntarily use it for a second real task within seven days, and
  median active review time is at least 20% below their matched comparison.
- If preservation holds but that usefulness threshold fails, reduce the flow
  to its demonstrated useful part or revisit the audience. Add no intelligence
  feature merely to compensate for a failed review task.

The thresholds are an explicit early product decision, not a powered estimate
of population effect. Repeat use, task-time advantage, and willingness to pay
remain unknown until actually observed. The journal-format decision and
public release qualifications remain with their existing owners.
