# Product Authority

`FOUNDING_PRD.md` is the imported founding product and architecture contract supplied on 2026-08-10. Its exact imported SHA-256 is recorded in `FOUNDING_PRD.sha256`.

`NORTH_STAR.md`, `ANCHOR.md`, `ARCHITECTURE.md`, and future ADRs are compact projections or explicitly approved changes. They do not silently replace the founding contract.

When an approved revision supersedes the founding PRD, preserve immutable history and identify the successor, approver, effective scope, and affected clauses.

`FIRST_CLASS_ACCEPTANCE_CRITERIA.md` is the working Given/When/Then test
projection for the complete local conversation loop. It is subordinate to the
founding PRD and approved ADRs; it creates no parallel product authority and
does not prove that any criterion currently passes.

[Imported recording review criteria](IMPORTED_RECORDING_REVIEW_ACCEPTANCE_CRITERIA.md)
refine that contract for verifying, correcting, reopening, finding, and
exporting a supplied recording. The draft includes failure and preservation
scenarios with traceability to existing requirements; it records no executed
native result and leaves the separate user-value trial unchanged.

[The Conversation Reviewer (PU-001)](PERSONA_PU_001.md) is a provisional Product
persona for the founding individual Mac audience. It separates declared intent
from behavioral hypotheses and links to the existing repeat-use experiment.
It has Low behavioral confidence, is not customer-validated, and does not
change the product contract, capability status, or experiment decision rule.

[H-001: Easier conversation review earns voluntary reuse](experiments/2026-10-22-reviewed-conversation-hypothesis.md)
frames the persona's central behavioral claim. It preserves the existing
trial's investment thresholds and identifies proposed measurement definitions,
failure conditions, and a relative timeline. The linked experiment remains
the execution owner; the hypothesis is a draft, not a completed user study.

[Review-workflow prototype plan](experiments/2026-10-22-reviewed-conversation-prototype-plan.md)
selects a seven-panel local HTML specification, role coverage, a Five-Act
interview script, trial-run gates, and an unconfirmed participant tracker.
It tests interaction understanding; prototype observations cannot establish
H-001's native reliability, active-time advantage, or voluntary reuse claims.

[Foundation Sprint readiness](experiments/2026-10-22-foundation-sprint-readiness.md)
assesses whether a two-day strategy workshop would help this initiative.
Its advisory Wait verdict identifies the missing customer-workflow evidence,
unconfirmed participation, prerequisite owners, and reassessment conditions.
It does not change the hypothesis, prototype specification, or native trial.

[Explicit microphone restore edge cases](MICROPHONE_RESTORE_EDGE_CASES.md)
catalog the failure surface for restoring a retired microphone inside the same
session: sealed audio, a visible gap, continued other audio, and an explicit
device and permission check. The draft records current retirement behavior
where it differs. It does not change the founding contract, the acceptance
criteria, or the user-value trial.

[Explicit microphone restore acceptance criteria](MICROPHONE_RESTORE_ACCEPTANCE_CRITERIA.md)
are the story-scoped Given/When/Then checks for that same slice. They are
subordinate to the first-class loop criteria. The store tests named there
passed; the Swift criteria were not host-executed, and a live headphone pull
was not run. They leave the user-value trial unchanged.
