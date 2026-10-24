# The Conversation Reviewer - Demanding Individual Mac Operator

**An individual Mac operator needs to turn an important conversation into a record they can verify, correct, and reuse while controlling what is captured and what leaves the Mac.**

| Field | Value |
| --- | --- |
| Persona ID | PU-001 |
| Mode | Product; selected from the repository's product context because no other mode was specified |
| Type | Primary; follows the founding audience in PRD section 4.1 |
| Product scope | The individual conversation loop: deliberate recording or import, preservation, playback, transcript review, correction, search, and export |
| Valid for | A technically capable Mac operator personally responsible for reviewing important conversations; especially when source verification and control of data matter. Organization size is not established. |
| Not valid for | Enterprise procurement, shared team workspaces, collaborative editing, autonomous follow-up, non-Mac workflows, or a claim of fitness for regulated or legal use. An occupation alone does not establish fit. |
| Confidence | Low overall: a provisional persona grounded in declared product intent, with no customer interviews or observed human-use results in the inspected sources |
| Last validated | Not customer-validated. Repository sources reviewed on 2026-10-21 at commit `25c9d251952cc3325d5ad71fee2cdd55c1b37ac4`. |
| Owner | Open Scribe product owner; research maintainer remains unassigned |

**Quick orientation.** Use the Persona Card in design reviews and sections 1-11
to examine workflow assumptions and tradeoffs. Evidence & Confidence identifies
what the sources actually establish and how this persona should be revised.

**Reading rule.** *Declared* means an authored product requirement or intended
audience; *recorded result* means a dated component experiment; *hypothesis*
means behavior that still needs observation. The persona describes an intended
user and desired experience, not current product capability. It is subordinate
to the founding PRD and approved ADRs, and does not change milestones or the
existing experiment's decision rule. Sources E1-E5 are linked below.

## Persona Card

**The Conversation Reviewer - Demanding Individual Mac Operator**

The intended user personally captures or imports important conversations and
returns to them to establish what was said. The working hypothesis is that a
dependable path from a question to source audio, a reviewed correction, and a
usable export matters enough to earn repeated use. [E1] [E4]

**Key quote.** No participant quotation is available. The founding user story
states: "After a conversation, I want to read a clean transcript, click text to
hear the corresponding audio, rename speakers, search, mark important moments,
and export normal files." This is authored intent, not interview evidence.
[E1, section 5.3][E1]

**Goals.** Preserve the conversation; verify consequential details against
audio; keep reviewed corrections; reuse the result outside the app.

**Frustrations.** Hypothesized friction includes hunting for the relevant audio,
redoing corrections, uncertainty about capture or provider scope, and exports
that require repair before use.

**Design rules - always.** Make capture and processing state legible; preserve
source material and human decisions; keep review and export useful with LLM
features disabled. [E1] [E3] [E5]

**Design rules - never.** Imply capture or content-sharing authorization;
silently displace reviewed work; present an unsupported interpretation as an
established fact. [E1] [E3] [E5]

## 1. Demographics & Identity

| Attribute | Detail |
| --- | --- |
| Age | Unknown; not a supported segmentation criterion |
| Location | Unknown; geography and jurisdiction are not inferred |
| Education | Unknown; a degree is not a prerequisite for this workflow |
| Role | Individual conversation reviewer. Researcher, founder, journalist, and analyst are examples in the PRD, not validated subsegments. |
| Company size | Unknown; the unit of use is one operator rather than a shared organization |
| Team | One person controls this local workflow; collaborator count and composition are unresearched |
| Reports to | Unknown; reporting structure is not needed to define the review task |
| Stakeholders | The operator and people who rely on their resulting notes or follow-up; recipient relationships are a hypothesis |
| Purchasing role | Intended end user; budget and purchasing authority are unknown |
| Accessibility | Keyboard operation is a declared expectation. VoiceOver, visible focus, non-color status, reduced motion, and readable text are product requirements; no personal disability is inferred. |

**Career stage and trajectory.** Career stage is unknown. Recruit by whether
someone must return to and verify real conversations, rather than by age,
seniority, or an assumed professional biography. [E1, sections 4 and 10.7][E1]

**Organizational leverage.** The hypothesis is that the operator's record helps
other people act on an agreement or resolve uncertainty. A wrong attribution
could therefore create rework beyond the operator, but neither its frequency
nor its organizational cost has been measured.

## 2. Technology & Environment Context

| Tool | Role |
| --- | --- |
| Apple Silicon Mac | Declared primary platform; specific devices and customer hardware distribution are unknown |
| FaceTime, ChatGPT Voice, Zoom, Meet, Teams, browser calls | Conversation sources named in the PRD; these are intended contexts, not observed adoption or a compatibility claim |
| Multiple displays and keyboard controls | Declared work environment and interaction expectation; prevalence within the audience is unmeasured |
| Local recording, playback, and transcript tools | Candidate components of the person's existing comparison workflow; identify their actual tools during research |
| Documents and ordinary exported files | Intended destination for reviewed work; specific editors and recipient requirements remain unknown |

**Digital fluency level.** The PRD specifies a technically capable operator who
cares what the system can see. That supports inspectable settings and clear
state, while its quick-record requirement still calls for a short ordinary
path; it does not establish willingness to debug models or repair storage.
[E1, sections 4.1, 5.1, and 9][E1]

**Adoption and abandonment patterns.** A working hypothesis is that the person
tries a tool on one important conversation and keeps it when returning to that
record requires less work. No adoption history or abandonment threshold has
been observed; the existing repeat-use trial is designed to test this. [E4]

**Work environment.** The declared setting includes several displays and
several possible call applications. Divided attention between conversation and
other work is a reasonable hypothesis, so controls should expose source and
recording state without requiring sustained attention to the library window.
[E1, sections 4.1 and 8][E1]

## 3. Jobs to Be Done

**Functional.** After a consequential conversation, the intended user needs to
find an agreement, hear the relevant passage, correct the record, and carry a
usable result into subsequent work. The existing experiment makes those steps
observable, including finding the correction again and resolving exported
evidence to the intended audio. [E1, section 5.3][E1] [E4]

**Emotional.** The hypothesis is that the person wants confidence that the
conversation and their review work remain available. If that holds, visible
preservation and recovery state should reduce the need to repeatedly check
whether the app has lost or changed their work.

**Social.** The hypothesis is that they want to represent other people's words
and commitments accurately. A record that can be checked may help them answer
a challenge without relying on memory or asking others to trust a summary.

**Underlying.** The proposed deeper job is preserving the value of attention
already spent: listening, reviewing, correcting, and deciding what is reliable.
Whether preserving that work creates a practical advantage over the person's
current method remains the central product question. [E4]

## 4. Goals & Motivations

**Life goal.** No life aspiration is established by the evidence. The useful
working motivation is doing consequential work with a dependable personal
record; research should test that motivation without inventing a broader
identity for the operator.

**Return to an intact conversation.** The intended outcome is a recording that
can still be found and reviewed after interruption or processing failure. This
requires preservation and honest state before optional derived work. [E1,
sections 2 and 7][E1] [E5]

**Resolve a consequential detail.** The operator should be able to establish
what was said and distinguish it from an inference or correction. The product
implication is navigable source evidence and visible provenance, including
contradicting evidence where it exists. [E1, sections 2.3 and 16][E1]

**Reuse reviewed work.** The intended outcome is a usable record outside the
app without repeating the review. Export, search, and later reopening must
respect the selected text and human corrections rather than silently choosing
a different result. [E3] [E4]

**Remain present during the conversation.** The desired experience is a short,
deliberate start followed by clear status. Frequent technical decisions during
capture would conflict with that authored goal. [E1, sections 5.1 and 6.1][E1]

**Understand uncertainty.** Draft, final, corrected, interrupted, and unsupported
states should be understandable when they matter. The operator should not need
to infer completeness from polished typography. [E1, sections 7 and 12][E1]

**Keep control of exposure.** Capture sources and optional remote data sharing
must remain inspectable and revocable. A provider configuration alone cannot
stand in for authorization to send conversation content. [E1] [E5]

## 5. Behavioral Patterns & Mental Models

**Core mental model.** A proposed mental model is a conversation record with
layers: source audio, a navigable transcript, deliberate human corrections, and
optional interpretations. The transcript helps the person locate and review
the recording. Corrections express work they have already done, so a new model
result should not silently displace them. This model follows the product's
evidence rules, but users have not yet demonstrated that they conceptualize
the workflow this way. [E1, sections 2.3 and 12.4][E1] [E4]

**Primary work pattern.** The intended workflow alternates a time-sensitive
capture moment with later retrieval and focused review. Actual review cadence,
session length, and the balance of live recordings to imports are unknown, so
neither entry path should be treated as the observed dominant one. [E1,
sections 5 and 9.9][E1]

**Accuracy and quality approach.** The behavioral hypothesis is selective
verification: names, amounts, decisions, and commitments receive closer audio
review than incidental wording. The product must make that checking possible;
whether people actually do it, and how much assistance they need, belongs in
the matched-task observation. [E4]

**Tolerance thresholds.** Starting in one or two actions is an authored product
goal, not a measured customer patience threshold. Acceptable transcription
wait, correction effort, and export friction remain unknown. [E1, section 5.1][E1]

## 6. Decision-Making & Trust Patterns

**How trust is built and broken.** The hypothesis is that trust grows when the
same reviewed record survives reopening and yields the correct source audio.
Silent loss, an incorrect evidence target, or misleading capture state are
explicit stop conditions in the existing experiment; no frequency of failures
or number of successful sessions needed to earn trust has been measured. [E4]

**Adoption filter.** Proposed evaluation questions are whether the conversation
is safe, whether a disputed phrase can be checked, whether corrections persist,
and whether the result can be taken elsewhere. Local operation and clear data
scope are declared requirements, but the ranking of these concerns against
convenience still needs observation. [E1, sections 4-5][E1]

**Risk profile.** The product contract protects source material, human
adjudication, and deliberate authorization. A corresponding hypothesis is
that the user will experiment with optional interpretations when the original
record and reviewed decisions remain recoverable; their actual willingness is
unmeasured. [E1] [E5]

**Feature discovery behavior.** There is no discovery research. A testable
design assumption is that correction, evidence navigation, and export should
be discoverable at the relevant review step without requiring a tutorial tour.

## 7. Workflow & Collaboration Context

**Work rhythm.** The authored jobs include spontaneous conversations, scheduled
meetings, and later review. The persona therefore needs a quick entry and a
resumable review path, while the frequency of interruptions and available
review time remain hypotheses. [E1, section 5][E1]

**Collaboration model.** The intended operator owns a personal record and may
share an exported result with someone who needs it. Initial team workspaces
and collaborative editing are outside the PRD's scope, so recipient needs
should inform portable output without presuming a shared application account.
[E1, sections 3.2-3.3][E1]

**Key collaboration friction.** The hypothesis is that a recipient may receive
a conclusion without the exact passage, correction state, or context needed
to assess it. The potential cost is clarification work or a repeated review;
research must establish which recipients and exports actually encounter this.

**Dependencies.** The workflow depends on available source audio, the selected
capture sources and permissions, and any model needed for the chosen derived
work. The product requirements call for honest failure and preserved media
when a dependency fails; the persona does not establish that these behaviors
currently pass all native acceptance gates. [E3] [E5]

## 8. Current Alternatives & Workarounds

**Primary alternative.** The actual current method is unknown. A plausible
comparison is the person's existing recording or transcript tool plus manual
notes and audio replay, but the study must use their competent real workflow
and document why they keep it. [E4]

**Where the product enters.** Open Scribe's intended entry is deliberate capture
or import, followed by the same review-and-export loop. The inspected experiment
records zero human-use participants, so there is no established adoption role
or evidence that it has replaced a person's existing tool. [E1] [E4]

**The firing trigger.** A hypothesized trigger is having to redo reviewed work
or discovering that a supposedly verified result points to the wrong source.
Capture ambiguity and unexpected content exposure would also violate declared
expectations; their actual effect on abandonment has not been observed. [E1] [E4]

## 9. Pain Points & Unmet Needs

These are source-grounded problem hypotheses, not observed customer incidents
or claims that the current implementation contains each defect.

**Finding the passage becomes a second task.** When a transcript, notes, and
audio lack usable connections, verifying one statement requires searching
across them. The expected cost is review effort and uncertainty about whether
the correct moment was found; the trial measures that cost. [E1, section 5.3][E1] [E4]

**Corrections do not reliably travel forward.** If reopening, retrying, or
exporting substitutes another transcript state, the person must notice and
repeat their correction. The component comparison exercised a preservation
case and tied its baseline; it establishes no customer prevalence or practical
advantage from this pain. [E4]

**Capture status demands interpretation.** If an indicator implies recording
before the selected sources are durably active, the person cannot know whether
the conversation is being preserved. The potential loss is irreplaceable
content, which explains the product's truthful-state requirement. [E3, AC-3
and AC-4][E3]

**Data scope is difficult to judge.** If the person cannot tell which sources
are watched or which categories leave the Mac, they cannot make an informed
authorization decision. The declared remedy is visible, bounded scope; how
often this concern blocks use remains unmeasured. [E1, section 5.5][E1] [E5]

**A usable record ends at the application boundary.** If an export omits the
reviewed text or its evidence relationship, the operator may need to reconstruct
the result for a recipient. The hypothesis is that ordinary portable output
will reduce that work; required formats and actual recipient behavior still
need observation. [E3, AC-13][E3] [E4]

## 10. Success Definition & Quality Bar

**Accuracy standard.** The declared quality bar is faithful preservation,
traceable corrections, correct evidence targets, and explicit uncertainty.
It does not assume perfect recognition; consequential wording must remain
checkable against the source. [E1] [E3]

**Timeliness standard.** The PRD calls for a one- or two-action recording start
and source media safe before derived processing completes. The user-level
question is whether the full review task saves active effort; recognition and
setup time must be reported separately, as the existing trial specifies.
[E1, sections 5.1 and 9.8][E1] [E4]

**Self-sufficiency standard.** The intended user can find the agreement, verify
it, correct a phrase, find that correction again, and export a result linked
to the intended source. Record assistance, failures, and abandoned tasks;
completion with hidden help does not establish independent use. [E4]

**Quality bar by context.** During capture, the priority is truthful state and
durable media; live text may remain visibly provisional. During review and
export, selected corrections and evidence identity must survive. Optional
derived conclusions must expose support, contradiction, and uncertainty while
leaving human judgment intact. [E1] [E3]

**Evidence needed for continued investment.** The existing trial's gate is at
least three of five people voluntarily returning for a second real task within
seven days, with median active review time at least 20% below their matched
comparison and no preservation or evidence-target violation. These are
predeclared decision thresholds, not achieved results, population estimates,
or independently editable persona rules; [E4] remains their owner.

## 11. Design Principles & Tradeoff Heuristics

**Protect the saved record first.** When derived processing competes with
preservation, preserve the conversation and the user's reviewed decisions.
The implementation order and failure behavior are governed by the existing
PRD and anchors. [E1] [E5]

**Make verification direct.** When convenience features compete for space in
the review flow, keep the relevant passage, playback, correction state, and
evidence navigation easy to reach. Whether that arrangement reduces effort
must be tested against the person's actual method. [E1] [E4]

**Give human review durable effect.** New recognition or interpretation should
preserve the distinction between machine output and deliberate corrections.
Showing a newer output is useful only if it does not silently displace the
work the person selected. [E1, section 12.4][E1] [E4]

**Keep ordinary use short and inspection available.** Present the information
needed for the current action, with source, model, and processing details
available when relevant. Technical capability does not justify making every
recording depend on technical configuration. [E1, sections 5.1-5.2 and 9][E1]

**Keep authorization specific.** A convenience improvement must preserve
deliberate capture and separate authorization for remote content categories.
The intended user should be able to understand the scope of an action before
it changes what is captured or shared. [E1] [E5]

**Let observed workflow value determine expansion.** Use the existing review
trial to decide the next focused investment. The recovery-baseline tie rules
out claiming an advantage for that scenario; it does not resolve user value.
Revisit the flow or audience if the human-use threshold fails, without using
additional intelligence features to compensate for an unproven review job. [E4]

## Evidence & Confidence

| Source | Type | Detail |
| --- | --- | --- |
| [E1: Founding PRD][E1] | Founding product contract | Supplied 2026-08-10; sections 2-5, 7-10, 12, and 16 define intent, audience, workflow, and invariants. SHA-256 matched `FOUNDING_PRD.sha256` on 2026-10-21. No customer sample or interview method is reported. |
| [E2: North Star][E2] | Product-intent projection | Mission, personal Mac scope, non-goals, and intended outcomes; inspected 2026-10-21. Derived from E1, so it is not independent customer corroboration. |
| [E3: First-Class Acceptance Criteria][E3] | Working acceptance projection | Created 2026-08-27. Defines observable review, correction, capture-state, and export criteria; does not assert that they all pass. No human-use sample. |
| [E4: Reviewed-conversation experiment][E4] | Experiment design and dated component report | Created 2026-10-16. Records one paired recovery scenario with a tie and one synthetic recognition workflow; human trial is explicitly unrun, 0 of 5 operators, with no invitations or observations. Component tests were not rerun for this persona. |
| [E5: Anchors][E5] | Product-invariant projection | Inspected 2026-10-21. Defines capture truth, evidence priority, local-first defaults, reliability, and bounded scope; derives from E1 and is not additional behavioral research. |

**Confidence.** Low overall for the behavioral persona: there are no participant
interviews, observed human workflows, or repeat-use results in the inspected
product and design sources. Confidence is High that this document represents
the declared primary audience and product constraints because those were
checked against the founding source and its checksum. That is confidence in
intent, not evidence of demand or segment prevalence.

**Validated.** Repository inspection confirms the declared audience, jobs,
non-goals, and the experiment's recorded status. The dated component report
supports preservation in its stated scenario and explicitly reports no
advantage over its competent baseline. No behavioral section has converging
customer validation; the PRD and its projections are one source of product
intent, not multiple independent observations.

**Assumed.** Emotional and social motivations, selective verification habits,
adoption and abandonment triggers, actual alternatives, recipient friction,
and the proposed mental model remain hypotheses. Demographics, job seniority,
company size, purchasing authority, review frequency, and willingness to pay
are unknown. Validate behavior through observed tasks and actual return use;
do not turn an authored user story into a participant quote or infer customer
behavior from passing technical tests.

**Open questions.**

1. In the person's current workflow, which step consumes effort or causes
   errors: finding a passage, checking audio, making a correction, finding it
   again, or producing a usable export?
2. After matched tasks on deliberately supplied recordings, who voluntarily
   returns for a second real task within seven days, and what observable
   difference explains that choice?
3. Do capture-heavy users and import-heavy users share this review job and
   quality bar, or do their behaviors justify separate personas?

**Governance.** Recommended review checkpoint: 2026-10-28, or before this
persona is used to justify scope expansion, whichever comes first. This is a
proposed checkpoint, not a scheduled event or a claim that research has begun.
The product owner should assign a research maintainer and advance the existing
five-operator study once its qualified-artifact and deliberate-input
prerequisites are satisfied; E4 remains the study owner. This persona task
initiates no recruitment, installation, recording access, or telemetry.

Update the persona after the first observed workflow and after the repeat-use
window, retaining counterexamples and assistance records. Narrow, split, or
retire it if observed users lack the review job, do not value the proposed
tradeoffs, or consistently choose their existing method without a relevant
bottleneck. Revise behavioral hypotheses from evidence; changes to founding
invariants still follow the repository's product-authority process.

[E1]: FOUNDING_PRD.md
[E2]: ../../NORTH_STAR.md
[E3]: FIRST_CLASS_ACCEPTANCE_CRITERIA.md
[E4]: experiments/2026-10-16-reviewed-conversation-validation.md
[E5]: ../../ANCHOR.md
