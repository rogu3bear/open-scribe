# Design Sprint Thursday Planning Artifact: Verify and reuse a conversation

**Status:** planning specification selected on 2026-10-22; prototype unbuilt,
roles not staffed, interviews not scheduled, and no confirmations recorded.

**Decision basis:** the user delegated the open storyboard, medium, and role
planning choices with "your call" after the missing inputs were identified.
This plan selects one seven-panel storyboard and a local HTML click-through
from [H-001][hypothesis], [PU-001][persona], and the existing [design direction][design].
There was no observed Wednesday workshop, sketch vote, or earlier signed
storyboard. The panel specification below is the selected planning input;
this record does not invent those events or a human signature.

**Learning boundary:** test whether the proposed review flow is understandable
and navigable. A staged prototype and think-aloud interview cannot establish
durability, native accessibility, the 20% active-time advantage, or seven-day
voluntary reuse. Those claims remain with the [qualified native trial][trial].
Friday prototype participants and prototype task times do not count toward
that trial's five paired comparisons or its return-use threshold.

**Clock:** T means the eventual prototype build day and F the interview day.
All times below are proposed in **America/Chicago**; neither day has a booked
calendar date. The hypothesis's 2026-10-28 readiness checkpoint remains intact.

**Medium decision:** use one self-contained HTML file with inline styles and
script, an embedded synthetic clip, and no server or external dependencies.
Keynote was not found in the standard application locations or Spotlight on
2026-10-22, so the plan avoids requiring its installation. The HTML preview
tools are available; no prototype file has been built or exercised yet.

## Prototype Role Plan

Use three human seats with explicit role coverage. A seat is a staffing
requirement, not a person who has accepted work. No agent or human has been
dispatched by this plan.

| Role | Owner | Day allocation | Notes |
| --- | --- | --- | --- |
| Maker | Seat A: design/build owner; person unassigned | T 10:00-12:30 and 13:00-14:00; 3.5 h | Builds P1-P7 surfaces from the selected storyboard, using the existing native document hierarchy. Joins the 16:00-17:00 trial. |
| Stitcher | Seat A, same person as Maker | T 14:00-16:00; 2 h | Connects routes, clip playback, fixture search and correction states, back paths, and reset; owns the runnable local prototype. Shares the same 16:00-17:00 trial hour. |
| Writer | Seat B: content owner; person unassigned | T 11:00-12:30 and 13:00-13:30; 2 h | Writes screen copy, state labels, fictional transcript and correction, and export-preview content; Interviewer reviews task consistency. |
| Asset Collector | Seat B, same person as Writer | T 10:00-11:00 and 13:30-14:00; 1.5 h | Collects or prepares permitted synthetic assets and verifies transcript/audio alignment, provenance, and local availability. |
| Interviewer | Seat C: dedicated research owner; person unassigned | T 10:00-12:30, 14:00-15:00, and 15:30-17:00; 5 h | Owns script, participant-status reconciliation, mock-run, consent and observation setup, and the complete trial run. |

**Doubling-up notes:** A covers Maker plus Stitcher; B covers Writer plus Asset
Collector; C remains a dedicated Interviewer. No person holds three canonical
roles. A's total is 6.5 hours including the one shared trial hour; B's is 3.5;
C's is 5, excluding the shared 90-minute planning review. The same person's
allocations do not overlap. The Interviewer's 14:00 mock-run uses the script
and panel previews while Stitcher completes the prototype; the 16:00 trial uses
the finished click-through.

The product owner retains the Decider role; a facilitator must be named for
the T 08:30-10:00 planning review. Reserve an additional target-profile
rehearsal partner for the mock-run and trial, preferably someone who did not
author the prototype. That person is a teammate for rehearsal and is not a Friday
participant. Actual people, availability, and the Decider's attendance remain
unconfirmed. If these seats cannot be filled, replan staffing and dates before
starting the build; do not silently make the Interviewer a third builder.

## Prototype Brief

**What to build:** one local HTML click-through of P1-P7 below: find a saved
conversation, locate an agreement, check its audio, correct a phrase, return
to the corrected passage, choose ordinary exports, and inspect a mock handoff.
Use the existing library sidebar, chronological conversation document, and
optional evidence detail. The target is an imported, already-transcribed
conversation; no capture preflight is needed for this interaction question.

**Fidelity bar:** each panel has a legible frame and meaningful controls. Embed
a permitted synthetic audio excerpt and make its text, speaker labels, and
timestamp consistent. Show final-ish copy and distinct machine-final versus
human-corrected states. Search operates only over the three fictional records;
the correction field updates their in-memory presentation. The participant
uses these controls directly, without an Interviewer advancing the happy path.
Refresh or Reset clears prototype state. Export is a labeled mock preview,
with no real file write. Disclose these limits, record all facilitation, and
make no durable saving, recovery, or installed-app claim. This is enough to
test comprehension and discovery; no pixel-perfect polish is required.

**Time allocation per role:** use the role plan. Synthetic source content and
asset specification are due at 11:00; screen copy is due at 12:30; all assets
must be locally verified by 14:00. Stitcher connects the flow by 16:00. Protect
the 16:00-17:00 trial-run window; a failed gate postpones interviews until
repair and another full trial pass. Local-file behavior, embedded playback,
and input handling must pass on the actual interview device; tool availability
alone does not establish those behaviors.

**Explicitly NOT being built:**

- Live capture, permissions flows, source-loss or crash-recovery demonstrations,
  transcription engines, or model installation.
- Production persistence, search outside the fictional records, real export
  writes, new export formats, or a native application build.
- Meeting intelligence, summaries, visual context, providers, or collaboration.
- Other library branches, settings, onboarding, decorative animation, or
  exhaustive accessibility and keyboard behavior; record needs the medium
  cannot test and return them to native verification.
- A hosted prototype, account flow, telemetry, participant recording service,
  or integration with real private conversation libraries.

**Sprint questions selected from H-001:**

1. **Q1 — Find and verify:** can the person locate the agreement and use its
   corresponding audio without an instruction naming the control?
2. **Q2 — Understand a correction:** can the person correct the phrase and
   explain which text changed and what original evidence remains?
3. **Q3 — Revisit and hand off:** can the person find the reviewed phrase again
   and identify what a recipient would need to check the exported record?

**Storyboard specification — P1-P7.** These are the selected panels for this
plan. Builders may refine copy and spacing, but changes to the task logic or
evidence meaning require a recorded scope decision before propagation.

| Panel | What the customer sees | What the customer does | Prototype response | Build and learning notes |
| --- | --- | --- | --- | --- |
| P1 — Find the conversation | Library with three fictional conversations; one titled "Cedar planning call", labeled as imported, with no active recording indicator | Opens the conversation relevant to the task | Opens its chronological document | One setup panel. Use a readable sidebar and top-aligned document; do not open the correct item for the participant. |
| P2 — Locate the agreement | Timestamped machine-final transcript with fictional Riley and Morgan speaker labels; the handoff phrase reads "Thursday at noon" | Searches or scans to find the handoff discussion | Reveals the passage at 00:42-00:50 and its audio affordance | Q1. Search is limited to fictional records; browsing remains available. No Interviewer navigation assist is required. |
| P3 — Check source evidence | The passage, timestamp, and visible playback control | Plays and checks the relevant excerpt | Embedded synthetic audio says "The revised handoff is Friday at noon. Morgan owns the draft." | Q1. Exact text-to-audio consistency is a build requirement; no such clip is claimed to exist yet. Replay and return remain available. |
| P4 — Correct the phrase | An editable phrase after the person finds the correction affordance | Changes Thursday to Friday and confirms the correction | Shows human-corrected text while leaving the machine wording and source audio distinguishable | Q2. Text input changes in-memory prototype state only. Do not manufacture a durable-save or verified-storage receipt. |
| P5 — Revisit reviewed text | Return to the library and the same conversation's updated search/document state | Finds the reviewed handoff phrase again | Displays the participant's correction and its unchanged source interval | Q2/Q3. Expected correct phrase is Friday at noon; never silently fix a participant's wrong edit. This revisit does not establish restart persistence. |
| P6 — Choose exports | Ordinary transcript-format and source-audio options, modeled on existing [format owners][formats] | Chooses a readable transcript and identifies how to include the source for checking | Opens the prepared Markdown transcript and separate source-audio previews | Q3. One supported demonstration path; no new combined format, fake JSON schema, or real export operation. |
| P7 — Inspect the handoff | Mock output preview with the participant's current corrected phrase, speaker label, and 00:42-00:50 source reference; source clip remains inspectable | Checks what the recipient receives and where the statement came from | Shows exactly the same reviewed wording and source passage as P3-P5 | One outcome panel. Do not substitute a canned correct answer. Distinguish a prototype source link from an exported link that works in a real library. |

**Asset specification:** all named conversations, people, and dialogue above
are fictional fixtures. Seat B must supply the short synthetic or explicitly
permitted source clip, its exact transcript, the intentionally wrong machine
phrase, the corrected phrase, and mock output text. Each asset gets its origin,
permission or license, panel usage, and local file reference recorded in the
build handoff. Use existing system typography and simple native-style shapes;
no customer screenshots, personal audio, downloaded stock portraits, or new
brand system are needed. These are asset requirements, not completed assets.

## Interview Script (Five-Act)

Target 60 minutes: Welcome 5, Context 8, Intro 5, Tasks 27, Debrief 10, plus
5 minutes of transition buffer. Observe silently; record actions and quotes
separately from interpretations. All task-performance findings are about the
prototype and its disclosed constraints.

For each task, note the panel reached, action attempted, exact quoted reaction,
assistance, prototype limitation, and outcome: unassisted, assisted, failed,
or not attempted. Keep the observer's explanation separate from what the
participant actually did. This is a manual observation record, not telemetry.

### Act 1: Welcome (5 min)

"Thanks for joining. I work with the Open Scribe team. We are exploring how
people return to important conversations and use what they find. Today we are
testing an early design, and difficulties help us understand what to change.
You can skip a question or stop at any time. We will use a fictional example,
so please do not open or share a private conversation."

State the Interviewer's actual name and introduce any observers by role.
Explain the agreed note-taking arrangement. Default to consented manual notes
without session recording. If recording has separately been agreed, identify
what is recorded, storage, access, retention, and the option to decline before
starting it; no cloud recorder or transcription service is assumed.

"Does that setup work for you, and may we proceed?"

### Act 2: Context (5-10 min)

1. "Tell me about the last time you went back to a conversation to check
   something. What were you trying to establish?"
2. "Walk me through what you did, using the tools you normally use. You do not
   need to show the conversation or identify the people involved."
3. "How did you decide the information was accurate enough to use?"
4. "What did you do with the result? Where, if anywhere, did you need extra
   work or help?"

Ask about a concrete past event. Do not introduce privacy, correction loss,
or AI summaries as presumed frustrations before the participant mentions them.

### Act 3: Intro (5 min)

"This is an early click-through design using fictional conversations. The
prototype does not capture audio or save changes to a real conversation. Search and edits work
only within the example, changes disappear when we reset, and the exported
files are previews. A sample audio passage will play when you choose it.
Please think aloud about what you see, what you expect, and what you are
trying to do. You do not need to be polite about the design."

Give control of the prototype to the participant using the agreed local or remote
input setup. Show only P1. Do not demonstrate the successful route, reveal the
wrong phrase, or teach the correction and export controls before the tasks.

### Act 4: Tasks (20-30 min)

1. **Find and verify — P1-P3; about 10 minutes.** "You need to confirm the
   revised handoff time from the Cedar planning call. Use what is here to
   decide what you would tell a colleague and how sure you are."
2. **Correct and revisit — P4-P5; about 9 minutes.** "Prepare the record so it
   reflects what you think was said. Then imagine you are returning to it
   later: find the passage you would rely on and show me why."
3. **Prepare a handoff — P6-P7; about 8 minutes.** "A colleague needs a readable
   record and a way to check that statement. Show me what you would give them
   and what they could verify from it."

**Interviewer probing notes:** use "What are you looking for?", "What did you
expect to happen?", "What tells you that?", or "What would you try next?"
After the person commits to an interpretation, ask "What, if anything, changed
in the original recording?" and "Which parts of this result would you still
want to check?" Avoid "Did you find that easy?" and avoid naming the control
they have not found.

If the participant does not notice the transcript/audio mismatch, record that
before revealing the discrepancy solely to continue the later task. If a
hint or rescue is necessary, record the exact intervention and mark subsequent
steps as assisted. For unsupported actions or navigation, distinguish
prototype limits from a misunderstanding of the design. Do not silently route
the participant to the desired state or record a staged transition as success.

### Act 5: Debrief (5-10 min)

1. "What is your overall reaction to what you tried?"
2. "What worked as you expected? What did not?"
3. "How does that compare with the last real review task you described?"
4. "What, if anything, would still prevent you from using the result?"
5. "If you could change one thing in this flow, what would it be? Anything
   else you want to share?"

Do not add a pricing question: willingness to pay is outside this sprint's
learning question, and the mock-up does not establish product value. Do not
ask the participant to promise a second use or count enthusiasm as H-001
retention evidence.

Close with: "Thank you. This helps us see what needs to change." Mention an
honorarium only if an actual arrangement exists, using its confirmed method
and timing; this plan establishes no payment or reimbursement commitment.

## Trial-Run Checklist

Run with the rehearsal partner on T 16:00-17:00. The Interviewer leads and
the Maker/Stitcher observes. Record **Yes** only after observing the behavior;
an unchecked item is **unverified**, not a pass. The full trial must fit the
reserved 60 minutes. The template's broader 55-65-minute tolerance must not
silently extend this plan's one-hour booking.

- [ ] **Maker/Stitcher:** the local HTML file, embedded audio, and participant
  input operate on the actual interview device without a server, network
  fetch, account, external font, or third-party script.
- [ ] **Maker/Stitcher:** every P1-P7 route, replay, return, and reset works;
  clicks outside controls do not skip ahead to answers.
- [ ] **Writer + Interviewer:** final screen copy contains no authoring notes,
  lorem ipsum, or unresolved placeholder labels; task prompts do not reveal
  control names or the correct handoff time.
- [ ] **Asset Collector + Stitcher:** the clip says Friday at noon and original
  machine text says Thursday. Correction, search, and mock export reflect the
  participant's actual edit, including a deliberately wrong rehearsal edit;
  timestamp, speaker, and original audio stay consistent. Reset restores the
  fixture without carrying one participant's edits into the next session.
- [ ] **Asset Collector:** asset origins and permissions are recorded; all
  displayed content is fictional or explicitly permitted, with no real
  customer material or private application screenshot.
- [ ] **Interviewer:** the full Five-Act rehearsal finishes within the planned
  hour, with all three task attempts and debrief preserved.
- [ ] **Interviewer:** the partner can make observable choices without being
  walked through the controls; every rescue or scripted transition is logged.
- [ ] **Interviewer:** consent wording, note-taking, observer presence, and any
  separately chosen recording arrangement match the actual session setup;
  there is no implicit cloud transcription or recording.
- [ ] **Interviewer:** observer access is tested and silent; participant input
  control works. A remote session's access link and audio are tested only if
  that session mode is actually selected.
- [ ] **Interviewer:** output interpretation can distinguish original audio,
  machine wording, corrected text, and the mock handoff without suggesting a
  native persistence or export guarantee.
- [ ] **Research owner:** all five participant slots and the reserve have
  current confirmation evidence, including actual time, time zone, access,
  device/input setup, and any consent or compensation arrangement. If a
  cancellation leaves four, explicitly record that exception and the actual
  cohort; do not mark five confirmations or waive the prototype gates.
- [ ] **Facilitator:** actual staff and the Decider's review availability are
  confirmed, and there is time to synthesize after the final interview.

If a gate fails, record the exact failure, owner, affected panels, and next
rehearsal. Repair and rerun the affected interactions plus the complete timed
interview before using the prototype with participants. Do not silently drop
a task, bypass a broken panel, or proceed because the artifact looks polished.

## Participant Confirmation Tracker (Thursday Morning)

**Observed status:** no participant roster or confirmations were supplied or
found in the inspected repository and bounded project-thread search. The
existing H-001 trial is also recorded as unstarted, but this is a separate
prototype-interview tracker. All rows below are proposed slots, not invitations
or real customer identities. A study ID is assigned only after an actual person
is enrolled; contact details stay in the chosen private recruitment channel.

| Slot | Customer (anonymized) | Status as of Thursday 09:30 | Recruiter action |
| --- | --- | --- | --- |
| F 09:00-10:00 | Unassigned | No confirmation evidence | Research owner must identify an eligible reviewer and record an actual confirmation before scheduling. |
| F 10:30-11:30 | Unassigned | No confirmation evidence | Same; verify Mac workflow and that the person performs real conversation review. |
| F 12:00-13:00 | Unassigned | No confirmation evidence | Same; agree access and observation arrangements. |
| F 14:00-15:00 | Unassigned | No confirmation evidence | Same; confirm availability for the full hour. |
| F 15:30-16:30 | Unassigned | No confirmation evidence | Same; protect the subsequent synthesis window. |
| F 07:30-08:30 reserve | Unassigned | Reserve not recruited or confirmed | Identify a willing reserve and agree a replacement slot; do not promise a sixth interview. |

The reserve is deliberately before the main schedule, with a 30-minute reset
before 09:00, so an extra late interview cannot run past the decision window. Activate it
for a known cancellation only after agreeing an available replacement time
with the person. The 07:30 option cannot rescue a cancellation discovered
after that time; seek an explicitly agreed later slot and move the review if
necessary, or record the reduced cohort. This is a scheduling proposal, not
authorization to message anyone.

**Risk assessment for Friday: High.** There are zero recorded confirmations,
unfilled research ownership, and no booked date or interview setup. Reconcile
the tracker at T 09:30 and before the trial run. A message sent is not a
confirmation. For a cancellation, offer the reserve an actual open slot and
record their response before marking it filled.

Target five interviews. If four remain after cancellation, use the recorded
four-person exception and report the smaller evidence base explicitly. If
fewer than four remain, the selected default is to postpone; the skill permits
a reduced-evidence alternative only through an explicit cohort decision.
Do not use teammates, fabricate confirmations, or count rehearsal as customer
evidence to fill the cohort. These choices never reduce H-001's five-operator
requirement; its trial remains separate.

## Decider Checkpoint

**Planning decisions are made under the user's "your call" delegation.** The
skill's checkpoint separates those decisions from real staffing, attendance,
and participant consent. No further approval request is needed to author this
specification; the unchecked items below remain execution conditions.

- [x] Select the seven-panel P1-P7 storyboard and one local HTML prototype,
  preserving the existing evidence-first native design direction.
- [x] Set the three-seat role coverage: A = Maker/Stitcher, B = Writer/Asset
  Collector, C = dedicated Interviewer; no triple assignment.
- [ ] Fill all seats with actual names and confirm availability; role coverage
  on paper does not establish a staffed build.
- [x] Select the fidelity bar and limit build work to the stated learning
  questions and scripted paths.
- [x] Set the Five-Act Tasks wording and the trial-run gate criteria; a trial
  pass is still required before interviews.
- [ ] Record real participant and reserve confirmations and separately covered
  recruiter actions; this plan has sent no invitations or reminders.
- [ ] Confirm the product owner's F 14:00-17:30 observation/review availability,
  with synthesis after 16:30 and the decision by 17:30. Move the review if a
  replacement interview moves later; do not silently overlap them.

**Decision record:** planning choices selected by Codex on 2026-10-22 under
the user's explicit delegation. Human signature and attendance: not supplied.
This record covers the planning specification, not a completed Wednesday
workshop, an accepted build, a trial-run pass, or authorization for outreach.

After the interview-day decision, stop prototype polishing. Preserve the prototype
and observation notes under the agreed retention policy; the skill's
disposable-prototype language is not authority to delete evidence. Record
findings by Q1-Q3 and send relevant interaction failures to their existing
product owner. Use the native trial for H-001's quantitative and repeat-use
claims when its own prerequisites are met.

**Source and method notes:** this bundle follows
`pm-skills:tool-design-sprint-prototype-plan` version 1.0.0 and its canonical
five-section template plus Decider Checkpoint. Its referenced
`design-sprint-skills-contract.md` was absent from the installed package after
bounded lookup; no extra family rules are claimed. The prerequisite skill's
5-15-panel guidance informed the seven-panel specification, but no missing
workshop or vote was simulated. Product claims remain governed by the
[founding PRD][prd], the [design contract][design], and the [format owners][formats].

[persona]: ../PERSONA_PU_001.md
[hypothesis]: 2026-10-22-reviewed-conversation-hypothesis.md
[trial]: 2026-10-16-reviewed-conversation-validation.md
[design]: ../../design/DESIGN.md
[formats]: ../../data-format/README.md
[prd]: ../FOUNDING_PRD.md
