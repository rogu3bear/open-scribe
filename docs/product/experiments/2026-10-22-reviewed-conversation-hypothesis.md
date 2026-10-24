---
artifact: hypothesis
version: "1.0"
created: 2026-10-22
status: draft
---

# Hypothesis: Easier conversation review earns voluntary reuse

## Hypothesis Statement

**We believe that** offering one local workflow to find an agreement, verify it
against source audio, correct a transcript phrase, find the correction again,
and export the reviewed record with its evidence

**for** individual Mac operators who already review important conversations
and have another real review task during the following seven days

**will** reduce active review effort compared with their existing method and
lead them to choose Open Scribe voluntarily for a second real task

**as measured by** at least **3 of 5 operators returning within seven days**,
alongside **at least 20% median paired reduction in active review time**,
with **zero preservation, evidence-target, or capture-truth
violations**.

Hypothesis ID: **H-001**. Confidence: **Low**. This is the behavioral hypothesis
for [PU-001, the Conversation Reviewer][persona]. The [existing experiment][trial]
owns the investment thresholds and execution prerequisites. This draft makes
the claim explicit and proposes counting and timing definitions where that
experiment is less specific; it does not revise the founding contract,
declare a capability available, or start the trial.

## Background & Rationale

### Problem Context

The [founding PRD][prd], sections 4 and 5.3, names an individual Mac operator
who wants to revisit conversations, navigate between transcript and audio,
correct speaker information, search, and export. PU-001 proposes that the
important problem is the effort of turning a saved conversation into a
verified, reusable record. The prevalence and severity of that problem remain
unmeasured.

The decision is whether to continue focused investment in this complete review
flow. Reliability remains mandatory whatever the result. This hypothesis does
not require adding Meeting, context observation, or intelligence features.

### Supporting Evidence

- **Declared intent:** the PRD establishes the audience and desired local
  conversation workflow. Its projections and PU-001 do not constitute
  independent customer evidence.
- **Recorded component result:** the 2026-10-16 experiment reports that Open
  Scribe and a competent SQLite reference both preserved corrected work and
  resumed an unfinished operation after process termination. The result was
  a tie, so that scenario demonstrated no recovery advantage.
- **Recorded feasibility evidence:** the same document reports a synthetic
  local recognition, correction, reopening, search, and export component
  workflow. It excludes native human use, long real conversations, and release
  qualification; it does not measure usability or customer value.
- **Behavioral evidence gap:** the current experiment record says the human
  trial is unrun, with 0 of 5 operators and no invitations or observations.
  Repeat use, review effort, total task duration, and willingness to pay remain
  unknown. The technical tests were not rerun to author this hypothesis.

### Alternative Hypotheses Considered

- **The existing method is sufficient.** Operators can already verify and reuse
  a conversation with comparable effort, so a dependable local implementation
  will not produce enough benefit to change their choice.
- **Another bottleneck dominates.** Recognition quality, model setup, importing,
  or obtaining usable source audio matters more than the review interaction.
  Separating setup and recognition from review measures this distinction
  without asserting that faster review makes the entire task faster.
- **Return use reflects novelty or help.** Operators return because of researcher
  attention, familiarity with the project, or assistance rather than sustained
  workflow value. Observe voluntary real tasks and retain assistance records.

The trial evaluates the workflow as a whole. It cannot establish which feature
caused an outcome or that time saved caused the decision to return.

## Target User Segment

### Definition

The intended segment is PU-001: a technically capable individual using a Mac
to review conversations they are entitled to supply, personally responsible
for checking and reusing the resulting record. They have an existing review
method that can serve as a competent comparison.

For this bounded study, screen for a genuine second review opportunity within
seven days. That is a proposed study eligibility criterion, not an observed
property of all target users. Include recording-led and import-led users who
share this job; record that distinction rather than claiming both segments
have already been validated. Enterprise purchasing, team collaboration, and
autonomous follow-up are outside this hypothesis.

### Segment Size

Population size and prevalence are unknown; no market-size estimate is
supported. The existing study calls for **five operators: the project operator
and four similar individual Mac users**. That is a convenience sample for a
bounded product decision, not the size of the market.

### Current Behavior

Each person's actual tools, review sequence, active effort, and assistance
needs must be observed using their existing method. Manual notes, a transcript
tool, and audio replay are plausible alternatives, not established behavior.
Zero completed study participants is an unmeasured baseline, not 0% retention
or zero review time.

## Success Metrics

### Primary Metric

| Metric | Current Baseline | Target | Minimum Detectable Effect |
| --- | --- | --- | --- |
| Verified voluntary reuse for a second real task within seven days of the initial paired session | Not measured; the study has not started | At least 3 of the fixed 5 operators, or 60% | Not estimated; this small study has no statistical power or MDE claim |

Proposed counting definition: a return is a self-initiated use of Open Scribe
on a distinct real review task, confirmed through an agreed follow-up or
observation. A request to try it again, a scheduled study task, stated intent,
or merely opening the app does not count. No automatic telemetry or reminder
system is introduced. Keep the denominator at five; missing follow-up is
unknown and never counted as a return.

### Secondary Metrics

| Metric | Current Baseline | Expected Direction |
| --- | --- | --- |
| Median paired percentage reduction in active review time | Measure each operator's matched task using their existing method | Decrease in effort; at least 20% reduction is a required companion gate, not an optional positive signal |
| Completed steps and usable export linked to the intended audio | Observe the same task sequence in the existing method | More independent completion; preserve incomplete and abandoned outcomes |
| Assistance and repeated review or correction work | Unmeasured; collect in both conditions | Fewer interventions and less repeated work; descriptive, without an invented numeric threshold |
| Setup, recognition, waiting, and total elapsed task time | Unmeasured; report separately for both methods | Identify costs that could offset active review savings; no claim of overall speed from active time alone |

**Proposed timing definition.** For each operator with a comparable completed
task in both methods, let `B_i` be baseline active review time and `O_i` be
Open Scribe active review time, starting from equivalent available materials
and ending when the reviewed export is verified. Include search, checking,
correction, retries, and manual repair. Record assistance alongside the time;
do not label an assisted task independently completed.

Calculate `r_i = 100 * (B_i - O_i) / B_i`, then take the median of the five
paired reductions. The gate is `median(r_i) >= 20%`, with positive baseline
times. Normalizing within each pair accommodates different existing workflows.
The existing experiment specifies the 20% threshold but not this aggregation;
this is the draft's explicit proposed interpretation, to be fixed before
observations rather than selected after seeing results.

Do not treat an abandoned task's short elapsed time as a successful fast task.
Retain its completed steps, elapsed effort, assistance, and failure reason.
If a comparable completion time is unavailable, the five-pair timing gate is
unestablished; do not compute a passing result by dropping that operator.

### Guardrail Metrics

| Metric | Current Value | Acceptable Range |
| --- | --- | --- |
| Loss or silent displacement of source material or reviewed work | Human-use rate unknown; the dated component scenario passed for both subjects | 0 incidents |
| Export or review evidence resolving to the wrong source or interval | Human-use rate unknown | 0 incidents |
| Misleading capture state encountered in the qualified trial flow | Human-use rate unknown | 0 incidents |

Any observed guardrail violation stops expansion regardless of time saved or
return count. The founding authorization and privacy requirements also apply:
use deliberately supplied material, preserve source content, and keep
conversation content out of the results record. If the trial uses imports
only, absence of a capture-state incident provides no live-capture proof.

## Validation Approach

### Method

Use the existing **within-person matched-task comparison followed by a
seven-day voluntary-use window**. Each person performs the same five-step
review job on matched, deliberately supplied recordings using Open Scribe and
their competent existing method. Follow the experiment's equivalent-materials
rule, including comparable transcript availability when measuring review.

Keep its existing order allocation: Open Scribe first for two operators,
existing method first for three. Record all assistance, repeated work,
abandonment, failures, and evidence resolution. Use agreed observations and
content-free result notes; no new telemetry infrastructure is needed.

Before use, the study owner must bind a qualified artifact and its remaining
platform limits, isolated libraries, and the deliberate inputs and model
setup authority required by the existing experiment. Source-component proof
does not satisfy native workflow qualification. This document frames the
claim and measures; the linked experiment remains the execution owner.

### Sample Size & Duration

- **Sample size:** five operators, each exposed to both methods; five paired
  comparisons rather than two independent groups of five.
- **Duration:** initial paired sessions within a proposed three-day window,
  followed by seven days from each operator's initial session. Allow two
  further days for analysis and the product decision.
- **Traffic allocation:** no production traffic or randomized online A/B test;
  all five use both methods, with the existing 2/3 order allocation.
- **Statistical requirements:** report individual paired results, the median,
  the return count, and every failure. No significance claim, powered MDE,
  population retention estimate, or broad market validation follows from
  this sample. Interpret thresholds as an early investment rule.

### Pass/Fail Criteria

Apply guardrails first, then evaluate the two required outcome thresholds.
Here, "validated" means supported enough for one focused next investment.

- **Validated if:** the five matched comparisons are interpretable, at least
  3 of 5 operators demonstrably return voluntarily within their seven-day
  windows, median paired active review reduction is at least 20%, and no
  guardrail violation is observed. Missing return data cannot supply a positive
  count. Assistance and task failures remain visible in the decision.
- **Invalidated if:** a guardrail violation occurs, or interpretable outcome
  evidence establishes either fewer than three voluntary returns or less than
  20% median paired active review reduction. Faster review alone, or repeat
  use alone, fails the combined prediction. Repair a guardrail failure through
  its owner; if preservation holds but usefulness fails, reduce the flow to
  its useful part or revisit the audience, as the existing rule specifies.
- **Inconclusive if:** required readiness is missing, fewer than five usable
  matched comparisons are available, follow-up uncertainty prevents deciding
  the return threshold, or materially unequal inputs, assistance, or task
  conditions prevent interpretation. An abandonment that prevents comparable
  timing stays a recorded task failure; it cannot support a passing median.
  If another observed result already invalidates the claim, report that
  failure rather than using missing data to obscure it. An inconclusive result
  does not justify expansion; identify the exact unresolved comparison.

## Risks & Assumptions

### Key Assumptions

- The proposed review job occurs often enough for an eligible operator to have
  a second real task within seven days; eligibility limits generalization to
  less frequent reviewers.
- A qualified native artifact supports the exercised flow and each person's
  comparison method is competent. Neither condition is established by the
  persona or the dated component tests.
- Matched recordings and starting transcripts are comparable enough to
  separate review effort from recognition quality and content familiarity.
- The proposed return definition and paired timing calculation can be fixed
  and applied consistently before observing outcomes.

### Risks

- The project operator's familiarity and the small convenience sample can
  inflate results. Report that operator separately alongside all five results;
  do not remove an inconvenient result or claim population validity.
- Learning, novelty, and researcher help can explain apparent gains. Preserve
  task order and assistance records, and distinguish a prompted retry from a
  voluntary real task.
- Setup and waiting may overwhelm active review savings. Report those costs
  separately and avoid inferring end-to-end speed, correction quality, or
  willingness to pay from the primary result.
- Easy or unusually clean recordings may hide the actual friction. Record
  task conditions without retaining conversation content in results, and
  retain failures and negative cases.
- Technical preservation may be necessary but offer no differentiation, as
  the recorded recovery tie illustrates. A positive human-use result would
  concern this workflow and sample, not superiority at every failure boundary.

## Timeline

Use the persona's proposed **2026-10-28 review checkpoint** to assess study
readiness. The study has not been scheduled or started. `D0` is the first
paired session after prerequisites are met, not the date of this document;
the calendar date of `D0` is unknown. Durations below are planning estimates.

| Phase | Dates | Duration |
| --- | --- | --- |
| Setup & instrumentation | Review readiness by 2026-10-28; before D0, bind artifact, inputs, comparison methods, and proposed measurement definitions | Estimated 2 working days once prerequisites are available; no new telemetry |
| Test running | D0-D2 initial paired sessions; each seven-day return window closes by D9 | Up to 10 calendar days, with no extra scheduled return task |
| Analysis | D10, after all return windows close | 1 day |
| Decision | D11 | 1 decision point: continue focused work, reduce/revisit, or name the unresolved evidence |

The Open Scribe product owner retains the investment decision and should name
a study operator before execution. If readiness is unmet at the checkpoint,
record the unmet condition and keep the trial unstarted. This draft initiates
no recruitment, recording access, installation, or external communication.

[persona]: ../PERSONA_PU_001.md
[prd]: ../FOUNDING_PRD.md
[trial]: 2026-10-16-reviewed-conversation-validation.md
