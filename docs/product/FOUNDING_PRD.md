Open Scribe — Founding Product Requirements Document

Status: Founding implementation contractProduct: Open ScribeCanonical domain: open-scribe.appCanonical successor repository: rogu3bear/open-scribeLegacy repository: rogu3bear/speaker-scribeWebsite foundation: rogu3bear/leptos-cloudflare / internal template identity leptos-cfPrimary platform: macOS on Apple SiliconLicense: MIT unless a reviewed dependency or asset requires a different treatmentDistribution: Direct-download, Developer ID–signed and notarized macOS application; public source repositoryAuthority: This PRD is the product and architecture source of truth until superseded by an explicitly approved revision or ADR.

0. Executive decision

Open Scribe is a greenfield, open-source macOS application for recording conversations and preserving evidence-backed meeting memory.

It replaces Speaker Scribe, but it is not a rename, port, or incremental refactor of Speaker Scribe.

The product has two primary modes:

Record — capture microphone and selected application/system audio reliably, then produce a local transcript.

Meeting — record the conversation while optionally observing user-authorized visual context and producing evidence-backed decisions, commitments, questions, and unresolved items.

The implementation architecture is:

SwiftUI for the macOS application surface and Apple-platform integrations.

Rust for durable product state, persistence, evidence, transcription orchestration, diarization, recovery, model policy, exports, and meeting-memory logic.

UniFFI for a deliberately narrow Rust-to-Swift control boundary.

Leptos on Cloudflare Workers, initialized from rogu3bear/leptos-cloudflare, for the public website and interactive demonstrations.

Shared WASM-safe Rust crates for domain types and deterministic semantics that genuinely belong to both the macOS app and website.

The following are explicitly retired from the successor architecture:

Python;

FastAPI;

React;

Tauri;

Electron;

localhost application servers;

upload-first product semantics;

a whole-application jobs.json;

browser-dashboard visual structure;

continuous unbounded screenshot retention;

implicit cloud processing;

AI output treated as primary evidence.

The approved public name is Open Scribe.

Do not reopen naming merely because similar names exist. Reopen it only if a concrete legal, platform, or distribution blocker is found.

1. Product thesis

Open Scribe is not “another AI meeting assistant.”

It is a private Mac conversation instrument.

It should feel like a combination of:

a reliable field recorder;

a calm native Mac utility;

a readable conversation document;

a user-controlled attention system;

an evidence index over what was heard and observed.

The core promise is:

Record what happened. Preserve what mattered. Show where every conclusion came from.

The application must remain useful without any language model enabled.

The language model is an optional interpretation layer over durable local evidence.

2. Product principles and invariants

These are binding product invariants.

2.1 Explicit capture authority

Open Scribe must never begin audio, video, screen, or contextual capture without an explicit user action.

Allowed explicit actions include:

clicking Record;

selecting Start Meeting;

invoking a documented global shortcut;

resuming a paused session.

Calendar detection, app activity, audio activity, or a likely call may make Open Scribe Ready.

They may never silently make it Recording.

2.2 Recording state must be unmistakable

A user must never reasonably ask:

Was that actually recording?

While recording, Open Scribe must provide redundant visible signals:

menu-bar icon state;

advancing timer;

active source labels;

input/output level activity where available;

main-window recording state;

immediate failure indication.

Recording state cannot depend only on color.

2.3 Raw evidence is authoritative

The following are evidence:

recorded audio;

recorded video when enabled;

transcript segments;

timestamps;

explicit user markers;

user-entered participant and topic information;

user-authorized OCR/context events;

source/application/window metadata;

user corrections and adjudications.

The following are derived interpretation:

summaries;

decisions;

commitments;

open loops;

“forgotten” items;

topic labels;

relevance judgments;

visual descriptions;

model-generated titles;

inferred relationships.

Derived interpretation must never silently overwrite evidence.

2.4 Every material AI claim must remain traceable

A derived item must be able to cite one or more evidence references.

Example:

Security review owner remains unresolved.

Evidence:
- transcript 18:39–18:47
- screen context event 18:42

If no supporting evidence is available, the item must be labeled unsupported, speculative, or omitted.

2.5 Local-first is the default

By default:

recording is local;

storage is local;

transcription is local when a local model is installed;

OCR is local;

screen pixels are discarded after local reduction unless the user enables retention;

no conversation content is sent to a remote provider;

no account is required;

no telemetry is required;

recording continues without internet access.

A remote provider requires an explicit provider selection and explicit content-scope authorization.

2.6 Reliability outranks intelligence

A successful session with no AI output is acceptable.

A session with excellent AI output but missing, corrupt, or incomplete audio is a product failure.

The implementation priority is:

capture
→ durability
→ recovery
→ playback
→ transcript
→ diarization
→ context
→ intelligence

2.7 Low distraction during the meeting

Open Scribe may be powerful without becoming visually demanding.

During recording:

no dashboard;

no card wall;

no constant AI interruption;

no required note-taking;

no live transcript forced into view;

no repeated prompts;

no heavy visual framing around watched content.

2.8 User-selected scope

“Watch my screen” must mean:

Watch only the scope I explicitly authorized.

Open Scribe must always let the user inspect, pause, narrow, or revoke the current context scope.

2.9 No hidden heavy writes

During a meeting:

media writes are sequential;

transcript events are append-oriented;

context writes are sparse;

model state checkpoints are bounded;

screenshots are not written continuously by default;

no ever-growing monolithic JSON file is rewritten per event.

2.10 Open-source inspectability

A technically capable user must be able to determine:

what the app can capture;

what it is currently capturing;

where data is stored;

which model ran;

what data left the Mac;

which network endpoints were contacted;

which artifact produced a derived claim;

how to export and delete their data.

3. Product goals

3.1 Primary goals

Reliably record microphone and selected application/system audio.

Preserve audio even when transcription or AI processing fails.

Produce a high-quality local transcript with timestamps.

Support lightweight live provisional transcription.

Support speaker-aware review.

Let a user opt into context observation without continuously recording all screens.

Work naturally across multi-display setups, including four or more displays.

Produce evidence-backed meeting memory.

Surface unresolved items without claiming that a person “forgot” something.

Remain useful with all cloud providers disabled.

Feel intentionally designed for macOS.

Be open source and pleasant to inspect, build, and contribute to.

3.2 Secondary goals

Import existing audio and video recordings.

Export standard audio, transcript, subtitle, JSON, and portable session formats.

Provide an activity/receipt view.

Support optional remote LLM providers.

Support optional Calendar and Contacts context.

Support user markers.

Support search across local sessions.

Support automatic signed updates.

Provide a polished public website and interactive product demonstration.

3.3 Non-goals for initial releases

Meeting bots that join calls.

Automatic recording without explicit user authorization.

Browser extensions.

iOS, Windows, or Linux clients.

Team workspaces.

Cloud transcript hosting.

Collaborative editing.

Automatic email sending.

Automatic calendar mutation.

CRM synchronization.

Autonomous task execution.

Real-time coaching that interrupts the meeting.

Full non-linear audio editing.

Video conferencing.

Hidden or stealth recording.

Continuous whole-screen semantic surveillance.

Automatic recognition of real human names from voice.

A plugin marketplace.

A Mac App Store release in the initial distribution path.

Pixel-identical SwiftUI and web presentation.

4. Target users

4.1 Primary user: demanding individual Mac operator

Characteristics:

works across multiple displays;

uses FaceTime, ChatGPT Voice, Zoom, Meet, Teams, and browser-based calls;

values local-first operation;

wants accurate records and follow-up;

is technically capable;

expects keyboard control;

cares about what the system can see;

wants a polished personal tool rather than an enterprise dashboard.

4.2 Privacy-conscious professional

Needs:

local recording;

no required account;

explicit provider selection;

transparent retention;

normal export formats;

reliable deletion;

no meeting bot;

clear capture scope.

4.3 Researcher, founder, journalist, or analyst

Needs:

long-form conversation preservation;

speaker turns;

timestamps;

markers;

evidence-linked notes;

unresolved references;

searchable history;

defensible source lineage.

4.4 Open-source developer

Needs:

clear repository boundaries;

reproducible builds;

inspectable storage;

documented network behavior;

deterministic tests;

small contribution surfaces;

explicit model and dependency licenses.

5. Jobs to be done

5.1 Record a spontaneous conversation

When a FaceTime, ChatGPT Voice, or similar conversation begins, I want to start reliable recording in one or two actions so I do not lose the discussion.

5.2 Record a scheduled meeting

Before a meeting, I want Open Scribe to help establish who is speaking, what the discussion is about, and what context I want observed, without forcing me through technical configuration.

5.3 Review what happened

After a conversation, I want to read a clean transcript, click text to hear the corresponding audio, rename speakers, search, mark important moments, and export normal files.

5.4 Recover something not resolved

After a meeting, I want Open Scribe to identify questions, commitments, owners, or terms that appeared but were never resolved, with links to the exact evidence.

5.5 Maintain privacy

I want to know which data stayed local, which data was sent to a provider, and what the app is watching right now.

5.6 Use the app with no AI

I want the recorder, transcript, search, and export system to remain useful even if I disable all LLM features.

6. Product modes

6.1 Record mode

Record mode is the simple path.

It must not ask:

who is present;

what the topic is;

how many speakers exist;

which transcription model to use;

which LLM to use;

whether to watch the screen.

Default flow:

Open menu bar
→ Record
→ confirm likely audio source if needed
→ recording begins
→ Stop
→ session is safe immediately
→ transcript finalizes

Record mode can capture:

microphone only;

selected application audio only;

microphone + selected application audio;

microphone + all authorized system audio;

optional screen video.

Record mode may later be converted into a Meeting session.

6.2 Meeting mode

Meeting mode adds structured context.

Preflight should be concise:

Who is talking?
[ James ] [ Tony ] [+ Add]

What is this about?
[ Manufacturing / Open Scribe ]

Want Open Scribe to watch where you are working?
[ Not now ] [ Follow pointer ] [ Choose scope ]

[ Start Meeting ]

All fields except Start are optional.

Meeting mode may use:

Calendar to prefill event title and attendees;

Contacts to resolve names;

active app/window context to suggest source;

selected context scope;

live provisional transcript;

event-driven meeting memory;

final post-meeting review.

Calendar and Contacts permissions are optional and requested only when used.

7. Application state machine

The top-level state machine is:

Idle
→ Ready
→ Recording
→ Paused
→ Finalizing
→ Ready for Review

Failure and interruption may occur from any active state.

7.1 Idle

no capture;

no active meeting candidate;

menu-bar control remains available;

optional upcoming meeting may be shown.

7.2 Ready

Open Scribe has enough context to suggest a conversation:

a calendar event is near;

a meeting application is active;

application audio activity exists;

FaceTime or ChatGPT Voice is active;

the user opened Meeting mode.

Ready is not Recording.

7.3 Recording

capture files are open;

timer advances;

session journal is durable;

current sources are visible;

failure state is monitored.

7.4 Paused

media capture is paused or segmented;

timer behavior is explicit;

context observation is paused;

session remains recoverable.

7.5 Finalizing

source audio is already safe;

mixdown, transcript, diarization, OCR reduction, or model review may continue;

user may close the review window without losing the session;

progress is visible but not blocking.

7.6 Ready for Review

the session is playable;

transcript may be final or show remaining background tasks;

derived memory has a clear status;

exports are available.

7.7 Interrupted

the prior process stopped unexpectedly;

available media is preserved;

session is marked interrupted;

recovery can finalize playable media and transcript;

the app never leaves the session indefinitely “running.”

8. Information architecture

8.1 Menu-bar surface

The menu bar is a remote control, not the full product.

Idle:

Record;

Start Meeting;

likely source;

next calendar event when authorized;

Open Library;

Settings;

Quit.

Recording:

elapsed time;

sources;

pause;

add marker;

context scope summary;

stop;

capture failure warning;

open live window.

Visible labels should remain short.

8.2 Main application window

Use a native macOS two-pane structure with an optional inspector.

Sidebar

Today;

Yesterday;

date groups;

Saved;

Archived;

Imports;

Search results.

Rows should be lightweight:

one title;

one secondary line;

one status icon at most.

Do not wrap each row in a large card.

Detail

The selected conversation document.

Default detail sections:

title and metadata;

playback controls;

thin waveform/timeline;

transcript;

markers;

derived meeting memory;

evidence navigation.

Optional inspector

Closed by default.

Contains:

participants;

sources;

tracks;

model runs;

context scope;

retained snapshots;

exports;

technical metadata;

activity receipts.

8.3 Settings

Dedicated macOS Settings scene.

Categories:

General;

Recording;

Audio;

Transcription;

Meeting Intelligence;

Models;

Providers;

Storage;

Shortcuts;

Privacy;

Updates;

Advanced.

Settings are not a destination in the main content sidebar.

8.4 Recording window

A compact live surface may be opened from the menu bar.

Default content:

recording state;

timer;

source labels;

meters;

marker action;

stop;

expandable live transcript.

It should not require the full library window.

9. Core UX flows

9.1 First launch

Show one concise product explanation.

Do not request every permission immediately.

Explain:

no account;

local-first;

capture begins only after explicit action;

optional models may require download.

Offer:

Try Record;

Open Library;

Review Privacy.

Request Microphone only when microphone capture is selected.

Request screen/system-audio permission only when application/system capture or context observation is selected.

Request Calendar or Contacts only when the user opts into those features.

Show permission status and recovery instructions.

9.2 Quick Record

User invokes menu or shortcut.

Open Scribe selects last valid source or suggests the likely active source.

User can begin immediately.

Capture initializes.

The UI does not report Recording until source files and recovery journal are active.

On Stop, source tracks are sealed first.

Finalization begins.

9.3 Meeting preflight

Identify likely active meeting app.

Prefill calendar title/attendees when authorized.

Ask:

Who is talking?

What is this about?

Watch where you are working?

Show selected microphone and application audio.

Start only after explicit confirmation.

9.4 Follow Pointer

User enables Follow Pointer.

Open Scribe shows a brief scope-confirmation interaction.

The display under the pointer receives a tasteful perimeter glow.

Other eligible displays have very low-opacity availability luminance.

Hovered display grows slightly brighter.

Selected/authorized display settles to a subtle persistent state.

Normal meeting operation removes persistent intrusive effects.

Brief transitions may acknowledge attention changes.

Pointer motion itself is not persisted continuously.

Context capture occurs only after dwell/change/relevance conditions.

9.5 Watch Display

user points to a display;

display perimeter glows;

click or keyboard confirms;

no screenshot-tool rectangle;

the display can be unselected from the menu bar or context settings.

9.6 Watch Window

user points to or chooses a window;

the selected window optically lifts or gains subtle edge luminance;

no permanent box is drawn over content;

app/window identity remains visible in scope summary.

9.7 Watch Region

A precise region is allowed, but it must not create a permanent boxy overlay.

Selection may temporarily use an interaction overlay.

After selection:

normal content is unobstructed;

the region is represented in scope controls;

“show watched areas” briefly reveals its boundary;

the user can rename, pause, or remove it.

9.8 Stop and review

Stop capture.

Confirm source media is safe.

Show the conversation immediately.

Live transcript remains readable.

Final transcript replaces or supersedes the live draft.

Derived meeting memory appears when complete.

Every derived item can navigate to evidence.

9.9 Import

drag audio/video file into library;

use Open panel;

create a normal session with source import;

preserve original file or copy according to user setting;

run transcript and diarization;

no context observation exists unless supplied separately.

9.10 Delete

Deletion must state exactly what will be deleted:

local media;

transcript;

context events;

retained snapshots;

exports;

model-derived state.

Deletion should be recoverable through Trash where practical.

10. Visual and interaction design

10.1 Design character

Open Scribe should feel:

Mac-native;

quiet;

instrument-like;

precise;

typographic;

spatial;

local;

trustworthy;

technically credible.

10.2 State-dependent personality

Idle

Nearly invisible.

Ready

Subtle anticipation.

Recording

Restrained red semantic signal.

Attention selection

White perimeter luminance and spatial depth.

Review

Calm conversation document.

Evidence inspection

Precise technical detail.

10.3 No box-heavy UX

Avoid:

permanent focus rectangles;

crop handles during normal operation;

every transcript turn in a card;

every setting inside a rounded panel;

dashboard-style metric cards;

three-column permanent metadata layouts;

generic glass everywhere.

Internal crop regions are allowed.

They are implementation details, not the primary visual metaphor.

10.4 Glow behavior

Display perimeter glow must be tasteful and bounded.

Recommended states:

State

Visual behavior

Eligible

Almost invisible low-opacity luminance

Hover

Soft white glow expands outward slightly

Selected

Subtle persistent halo

Active attention

Brief increase in luminance

Paused

Reduced intensity

Error

Semantic warning, not decorative red glow

Do not heavily dim non-hovered screens.

The main signal is the focused surface becoming more alive.

10.5 Transcript presentation

no chat bubbles;

no alternating message bubbles;

no card per utterance;

generous readable typography;

speaker identity in margin or lightweight header;

timestamps secondary;

tidy and verbatim views;

text selection actions;

click-to-seek;

waveform-to-transcript synchronization.

10.6 Native macOS requirements

Use standard SwiftUI structures where suitable:

WindowGroup;

MenuBarExtra;

NavigationSplitView;

Settings;

toolbars;

inspectors;

commands;

search;

semantic materials;

system typography.

Use AppKit only for narrow platform gaps such as overlay windows, responder-chain behavior, or specialized display treatment.

10.7 Accessibility

complete keyboard operation;

VoiceOver labels;

no status communicated only by color;

reduced-motion behavior;

high-contrast compatibility;

visible focus;

logical focus order;

semantic headings;

transcript navigation by speaker and timestamp;

non-visual description of watched scope;

scalable semantic typography;

accessible error messages.

Target WCAG 2.2 AA for the website.

11. Capture requirements

11.1 Capture sources

Support:

microphone;

selected application audio;

selected window/application system audio where platform allows;

all authorized system audio;

optional screen video;

imported files.

11.2 Track architecture

Internally capture separate source tracks whenever possible:

microphone
application/system audio
optional screen video

User preference controls whether source tracks are retained after validated mixdown.

Do not discard source tracks before:

mix output exists;

output is playable;

duration is sane;

checksum or equivalent validation succeeds.

11.3 Source-aware speaker identity

When tracks have known identity:

microphone track can be assigned to the local user;

selected application audio can be assigned to remote participants or application identity;

diarization should run only where identity is unknown;

the system must not use diarization to rediscover a distinction already known from capture topology.

11.4 Synchronization

Requirements:

one stable session timebase;

timestamps recorded for every track;

track drift measured;

long-session drift bounded;

source-switch events recorded;

playback and transcript use the same session timeline.

Initial validation target:

no perceptible drift in normal review;

measured cross-track drift no greater than 100 ms over a two-hour test session;

tighter targets may be adopted after implementation evidence.

11.5 Crash-safe media

Media must be written in a format and segmentation strategy that permits recovery after forced termination.

Requirements:

session journal exists before recording is reported active;

files are incrementally durable;

media does not require a clean application exit to become recoverable;

interrupted sessions are detected on next launch;

available audio can be finalized without original process state.

11.6 Device changes

Handle:

microphone disconnect;

AirPods route change;

headphones connect/disconnect;

selected app exit;

screen source disappearance;

audio device sample-rate change;

sleep/wake;

display connect/disconnect;

system permission revocation;

disk-space exhaustion.

Each event must:

be visible;

be written to the activity log;

preserve existing media;

use an explicit fallback or stop dependent capture.

11.7 Feedback and echo

Open Scribe must not route captured system audio back into output.

Capture tests must include:

headphones;

speakers;

FaceTime;

ChatGPT Voice;

Zoom/Meet/Teams where accessible;

system notifications;

multiple applications producing audio.

11.8 Media formats

Implementation may select exact containers after benchmarking.

The contract is:

source tracks are lossless or effectively lossless;

interrupted files are recoverable;

final default export is broadly playable;

lossless export is available;

metadata does not require proprietary software.

Recommended candidates:

CAF or WAV/PCM for source tracks;

M4A/AAC for default mix;

FLAC or WAV for lossless export;

MOV for optional screen video.

12. Transcription requirements

12.1 Provider abstraction

Define a Rust SpeechRecognizer capability.

Initial implementations may include:

local Whisper-compatible native engine;

future system provider;

optional remote provider.

No Python runtime may be introduced.

Native C/C++ or ONNX dependencies are acceptable behind bounded Rust crates when:

licensing is reviewed;

build is reproducible;

no background service is required;

the interface is tested;

the dependency is disclosed.

12.2 Live transcript

Live transcript is provisional.

Requirements:

explicitly labeled Draft;

low-latency;

append-oriented;

tolerant of correction;

optional/collapsible;

never treated as final evidence when a final transcript exists.

Do not retranscribe the entire growing file repeatedly.

Use:

rolling buffers;

VAD/utterance boundaries;

incremental chunk transcription;

explicit reconciliation with final output.

12.3 Final transcript

Requirements:

batch pass over complete source media;

word or segment timestamps;

language identification or user hint;

model identity;

transcript status;

failure recovery;

deterministic normalized schema;

speaker assignment;

evidence references.

12.4 Verbatim and tidy text

Preserve:

immutable or append-only verbatim transcript;

derived tidy text;

user-corrected text.

Do not silently replace verbatim content with cleaned prose.

User edits must be represented as human corrections with history or provenance.

12.5 Speaker handling

Support:

known source channel identity;

diarized unknown speakers;

user rename;

optional remembered local voice identity;

speaker confidence/uncertainty where available.

Never claim a real human name was inferred from arbitrary audio without an explicit enrolled identity.

12.6 Model management

models downloaded on demand;

size and expected quality visible;

cryptographic hash or trusted manifest;

model source and license visible;

partial downloads recoverable;

delete/re-download supported;

recording works without a transcription model;

model download never blocks media capture.

Default distribution should avoid embedding several gigabytes of weights.

A separate “full offline bundle” may be offered later if justified.

13. Diarization requirements

Define a Rust VoiceEmbedder and diarization pipeline.

Required stages:

decode/resample
→ speech activity detection
→ speech windows
→ embeddings
→ clustering
→ turn cleanup
→ word/segment assignment

Requirements:

no Python;

local execution;

single-speaker detection;

bounded maximum speakers;

user-provided minimum/maximum only in advanced settings;

source-aware identity before clustering;

explicit handling of short phantom clusters;

calibrated thresholds based on the selected embedding model;

fixture-based regression tests;

no claim that diarization identifies real names.

Legacy Speaker Scribe behavior may be used as reference evidence, not source architecture.

14. Context observation and attention field

14.1 Context modes

Meeting mode may authorize:

Follow Pointer;

Watch Display;

Watch Window;

Watch Region;

manual Add Current Window;

temporary Pause Context.

14.2 Follow Pointer semantics

Follow Pointer approximates attention.

It does not record literal pointer history.

Pipeline:

pointer enters area
→ movement slows or dwell threshold passes
→ candidate surface identified
→ local frame sample
→ local change detection
→ local OCR/layout extraction
→ semantic context event
→ pixels discarded by default

Fast transit is ignored.

Dock, menu bar, notifications, and transient menus should be filtered where practical.

14.3 Multi-display behavior

derive real display topology from macOS;

do not assume one display or one orientation;

support horizontally and vertically arranged displays;

support laptop display plus external monitors;

handle hot-plug;

use actual display bounds;

never hard-code monitor dimensions.

14.4 Screen selection visual language

Selection must use perimeter luminance and depth rather than a permanent box.

The interaction should communicate:

Open Scribe understands which field is active.

not:

A capture rectangle exists at these coordinates.

14.5 Local reduction before LLM

Default path:

pixels
→ local frame difference
→ local OCR
→ local layout grouping
→ sparse text/context event
→ optional LLM

The LLM must not receive continuous screen video.

14.6 Semantic expansion

Near-pointer text should be expanded into useful structure when possible:

cell + row/column header;

paragraph + heading;

slide group + slide title;

selected control + nearby label;

code/terminal region + context.

The internal crop may be larger than the visible pointer neighborhood.

14.7 Screenshot retention

Default:

raw frame discarded after local reduction;

OCR/context event retained;

source metadata retained;

optional small evidence snapshot disabled.

User options:

retain no pixels;

retain only user-marked snapshots;

retain meaningful snapshots;

retain screen video when explicitly recording video.

14.8 Sensitive-content safeguards

Where technically practical:

avoid secure text fields;

exclude password managers;

exclude notification center;

allow application denylist;

allow private-window denylist;

suspend context on lock screen;

show clear context pause.

No safeguard should be represented as absolute if the platform cannot guarantee it.

14.9 Accessibility permission

Accessibility access must not be required for the base recorder.

Use it only if a specific optional capability requires it and the benefit justifies the permission.

Do not scrape arbitrary UI text merely because the permission exists.

15. Meeting intelligence and LLM policy

15.1 LLM is optional

Open Scribe must support:

Disabled;

Local only;

Remote review only;

Local live + remote review;

custom provider.

Recording and transcript review remain functional when Disabled.

15.2 Two model roles

Live intelligence

Optimized for:

low latency;

small context;

structured extraction;

local operation;

sparse calls.

Responsibilities:

entities;

topic updates;

decisions;

commitments;

open loops;

number/term extraction;

relevance filtering.

Review intelligence

Runs after Stop or by manual command.

Responsibilities:

final summary;

cross-session or full-session reconciliation;

contradictions;

unresolved items;

decision packet;

follow-up draft content;

visual/audio evidence reconciliation.

15.3 Event-driven inference

Do not run the model on every transcript token or screen frame.

Trigger on:

completed utterance batch;

explicit marker;

meaningful OCR delta;

topic transition;

explicit user request;

session finalization.

Implement:

debounce;

batching;

maximum call frequency;

token/context budget;

cancellation;

backpressure.

15.4 Structured memory

Maintain a structured MeetingMemory:

people
topics
facts
decisions
commitments
questions
open_loops
numbers
documents_and_surfaces
uncertainties
contradictions

Each item carries:

stable identifier;

status;

evidence references;

source type;

created/updated timestamps;

producer: human or model;

model run identifier where applicable;

confidence or uncertainty label;

human adjudication state.

15.5 Evidence-grounded statuses

Distinguish:

mentioned;

proposed;

discussed;

agreed;

assigned;

completed;

contradicted;

unresolved;

unknown.

Unknown never becomes false.

Mentioned never becomes agreed.

A name near an action does not automatically become the owner.

15.6 Loose Ends

Open Scribe should produce a dedicated Loose Ends view.

A Loose End is:

Material evidence was introduced, but no later evidence establishes resolution.

It is not:

The model claims the user forgot something.

Every Loose End must show:

concise item;

why it matters;

first evidence;

relevant later evidence;

resolution search result;

status;

confidence/uncertainty.

15.7 Provider selection and data scope

A remote provider configuration must show:

provider;

model;

endpoint;

data categories eligible to send;

whether audio may be sent;

whether transcript may be sent;

whether OCR text may be sent;

whether pixels may be sent;

retention warning;

API key location;

cost/budget controls.

Example:

This review may send:
✓ transcript
✓ user notes
○ OCR context
○ screenshots
○ audio

Selecting a provider does not authorize every category.

15.8 Provider boundary

Define a Rust IntelligenceProvider interface.

The provider returns a proposed structured delta.

The provider may not write storage directly.

Rust must:

validate schema;

attach model-run provenance;

preserve evidence references;

reject malformed output;

prevent provider tool execution;

persist accepted deltas.

Apple-specific system model integration may use a small Swift adapter, but Rust retains policy and storage authority.

15.9 Prompt-injection resistance

Transcript and watched-screen text are untrusted content.

Requirements:

treat observed content as quoted evidence;

never allow it to become system instructions;

no tool execution from observed content;

no shell, email, calendar, file, or network actions;

schema-constrained output;

prompt-template versioning;

adversarial fixtures;

activity receipt for every model run.

16. Evidence model

16.1 Evidence types

AudioRange;

VideoRange;

TranscriptRange;

UserMarker;

UserNote;

ScreenTextEvent;

ScreenSnapshot;

SourceTransition;

ParticipantDeclaration;

CalendarContext;

HumanCorrection;

ImportedDocumentReference.

16.2 Derived claim

A derived claim contains:

claim text;

claim type;

status;

supporting evidence IDs;

contradicting evidence IDs;

model run or human author;

confidence/uncertainty;

creation timestamp;

last adjudication timestamp.

16.3 Evidence navigation

From a claim, the user can:

seek audio;

highlight transcript;

reveal context event;

reveal retained snapshot;

see source app/window;

inspect model run;

mark claim correct/incorrect/uncertain.

16.4 Human adjudication

Human edits do not erase model history.

They create an adjudication event:

accepted;

corrected;

rejected;

unresolved.

17. Data model

The exact schema may evolve, but these concepts are required.

17.1 Session

id
mode
title
created_at
started_at
stopped_at
duration
status
source
topic
language
storage_path
privacy_profile

17.2 Participant

id
session_id
display_name
role
source_identity
voice_identity_optional
declared_by

17.3 Track

id
session_id
kind
source_application
source_device
path
format
sample_rate
channels
start_offset
duration
status
checksum
retention_state

17.4 Transcript segment

id
session_id
track_id_optional
start
end
speaker_id
verbatim_text
clean_text
finality
language
model_run_id
confidence_optional

17.5 Context event

id
session_id
timestamp
scope_type
display_id_optional
application_id_optional
window_title_optional
pointer_position_normalized_optional
ocr_text
layout_structure_optional
snapshot_id_optional
retention_policy

17.6 Marker

id
session_id
timestamp
label_optional
created_by
nearby_excerpt_optional

17.7 Memory item

id
session_id
kind
text
status
owner_optional
due_date_optional
evidence_ids
contradiction_ids
model_run_id_optional
human_state

17.8 Model run

id
session_id
provider
model
model_version_optional
purpose
prompt_template_version
input_scope
input_hash
output_hash
started_at
completed_at
status
network_used
cost_optional

17.9 Activity event

id
session_id_optional
timestamp
category
action
detail
severity

17.10 Settings

Separate:

app preferences;

provider secrets;

model catalog;

privacy profiles;

device preferences;

shortcuts.

Provider secrets belong in macOS Keychain, not SQLite or plaintext configuration.

18. Persistence and filesystem

18.1 Storage architecture

Use:

SQLite with WAL for structured application data;

append-oriented event tables;

filesystem media assets;

per-session recovery journal;

normal exports.

Recommended layout:

~/Library/Application Support/Open Scribe/
├── open-scribe.sqlite3
├── Sessions/
│   └── <session-id>/
│       ├── recovery.jsonl
│       ├── audio/
│       ├── video/
│       ├── context/
│       └── exports/
├── Models/
├── Logs/
└── Cache/

Logs must never contain transcript or OCR content by default.

18.2 Event sourcing

Use append-oriented events for:

session lifecycle;

source transitions;

transcript segments;

context events;

markers;

model runs;

derived memory;

adjudication;

recovery.

Materialized views may optimize reads.

Do not over-engineer a distributed event-sourcing framework.

The requirement is local traceability and recovery.

18.3 Portable session export

Define a documented portable archive format.

Recommended:

<name>.openscribe/
├── manifest.json
├── audio/
├── transcript/
├── evidence/
├── context/
└── exports/

It may be implemented as a macOS package directory or zip-compatible archive.

The format must be versioned.

18.4 Data deletion

Deletion must:

remove structured rows;

remove media;

remove retained snapshots;

remove exports;

remove model-derived state;

leave no hidden cloud copy created by Open Scribe.

Remote provider retention remains subject to the provider and must be disclosed before use.

18.5 Backups

Document:

whether sessions are included in Time Machine;

whether model caches are excluded;

portable export for manual backups;

optional application-level encryption as a future feature.

Do not invent custom cryptography for MVP.

Rely on platform disk encryption and Keychain unless a reviewed design justifies more.

19. Permissions and consent UX

19.1 Permissions

Potential permissions:

Microphone;

Screen & System Audio Recording;

Calendar;

Contacts;

Accessibility, optional;

Files/folders when importing/exporting;

notifications, optional.

19.2 Progressive requests

Request each permission at the point of use.

Do not present a first-launch wall demanding all access.

19.3 Revocation

If a permission is revoked:

stop dependent capability;

preserve current media;

update UI;

write activity event;

explain recovery;

never pretend capture continued.

19.4 Recording consent

Open Scribe is not legal counsel.

The app should:

remind users that recording laws and participant consent vary;

let users configure a pre-recording reminder;

make recording state visible;

never support stealth mode;

provide an optional audible start/stop tone;

not claim that an in-app reminder satisfies legal obligations.

No specific jurisdictional legal claim should be embedded without professional review.

20. Security and privacy

20.1 Threat model

At minimum address:

local data theft;

malicious imported media;

path traversal;

symlink attacks;

malformed media;

model supply-chain compromise;

malicious remote provider;

prompt injection from transcript or screen;

API key exposure;

overbroad logging;

crash-report leakage;

unauthorized context scope;

stale permissions;

model output treated as executable instruction;

unsigned nested binaries;

update-channel compromise.

20.2 Security requirements

Developer ID signing;

hardened runtime;

notarization;

nested-code verification;

strict path handling;

bounded parsers;

media size limits for import;

model hash validation;

signed update feed;

Keychain secrets;

no raw content logs;

no hidden analytics;

no arbitrary plugin execution;

no automatic provider tools;

CSP on website;

dependency review and lockfiles;

security policy and private disclosure channel.

20.3 Network policy

Default network use may include only:

explicit model downloads;

explicit update checks;

explicit remote provider calls;

website access outside the app;

Apple platform trust/notarization behavior.

Recording itself must not require network.

Every remote model run must indicate network use.

20.4 Activity receipts

Provide a user-readable activity surface:

17:03:12 microphone capture started
17:03:12 ChatGPT audio capture started
17:05:43 context event retained
17:05:43 source frame discarded
17:17:02 local model updated meeting memory
17:41:09 recording stopped

Normal users need not stare at this.

It exists for trust and debugging.

21. Technical architecture

21.1 High-level architecture

SwiftUI macOS app
├── scenes and windows
├── menu bar
├── permissions
├── ScreenCaptureKit
├── AVFoundation/CoreAudio
├── Vision OCR
├── display/window overlays
└── narrow Rust bridge
          │
          ▼
Rust core
├── domain
├── session state
├── event store
├── recovery
├── transcription
├── diarization
├── evidence
├── meeting memory
├── provider policy
├── export
└── model management
          │
          ├── SQLite/filesystem
          ├── native ASR/ONNX libraries
          └── optional providers

Shared WASM-safe Rust
          │
          ├── Swift-facing domain types
          └── Leptos website/demo

21.2 Swift ownership

Swift owns:

App/Scene lifecycle;

WindowGroup;

MenuBarExtra;

Settings;

AppKit overlay bridges;

macOS permission requests;

ScreenCaptureKit source selection;

low-level Apple capture adapters;

Vision OCR;

pointer/display/window topology;

UI rendering;

accessibility;

Apple-only model adapter if used.

21.3 Rust ownership

Rust owns:

durable session state;

event schema;

persistence;

recovery rules;

evidence relationships;

transcript normalization;

diarization logic;

ASR provider abstraction;

model catalog;

meeting-memory state;

provider policy;

remote data-scope rules;

exports;

portable archive;

validation;

activity receipts.

21.4 FFI boundary

Use UniFFI for:

control operations;

coarse state queries;

settings;

session summaries;

low-frequency events;

structured transcript/memory updates.

Do not send audio frames, video frames, or pointer samples through ordinary high-level UniFFI callbacks at frame rate.

Recommended hot-path strategy:

Swift captures and writes crash-recoverable media;

control and metadata cross UniFFI;

live-ASR audio uses a bounded native ring buffer, shared memory, or narrow C ABI only after profiling;

event notifications remain coarse.

Required coarse API family:

initialize
get_capabilities
start_session
pause_session
resume_session
stop_session
list_sessions
get_session
delete_session
export_session
set_context_scope
append_marker
subscribe_session_events
configure_provider
run_review

21.5 Rust workspace

Recommended:

crates/
├── open-scribe-types
├── open-scribe-domain
├── open-scribe-evidence
├── open-scribe-store
├── open-scribe-asr
├── open-scribe-diarize
├── open-scribe-memory
├── open-scribe-models
├── open-scribe-core
└── open-scribe-uniffi

WASM-safe crates:

types;

domain;

evidence;

deterministic formatting where useful.

Native-only crates:

store;

ASR;

diarization;

models;

core;

UniFFI.

Native dependencies must not leak into WASM-safe crates.

21.6 Minimum platform

Recommended initial support:

Apple Silicon only;

macOS 15 or later;

capability-gate macOS 26-only features;

baseline performance testing on an M1 Pro with 16 GB;

reference development on current Apple Silicon hardware.

Do not raise the minimum OS merely to use a decorative API.

Document each availability fallback.

22. Website requirements

22.1 Foundation

Use rogu3bear/leptos-cloudflare as the implementation foundation.

Its internal project identity may be leptos-cf.

Use it for:

Leptos 0.8;

SSR;

hydration;

Cloudflare Worker entrypoint;

Worker Assets;

hashed asset pipeline;

CSP generation;

deep-route fallback;

deployment scripts;

agent-first bootstrap.

Place it under the new repository’s web/ directory and integrate it deliberately into the top-level workspace.

Do not blindly preserve the template root layout.

22.2 De-template completely

Run initialization only for wiring.

Then replace:

starter components;

todo domain;

D1 schema;

starter icons;

starter copy;

starter metadata;

starter colors;

starter gradients;

starter glass;

starter cards;

starter typography;

starter spacing tokens;

starter max-width assumptions.

No starter design token survives without explicit review.

22.3 D1

Do not use D1 merely because the template includes it.

Initial website should be stateless unless a concrete requirement exists.

Potential future D1 uses:

support intake;

release metadata;

optional mailing list;

bounded feedback.

Each requires separate privacy and abuse review.

22.4 Canonical domain

Use:

https://open-scribe.app

For:

canonical metadata;

OpenGraph;

documentation;

download;

privacy;

terms;

release references.

22.5 Website pages

Required:

Home;

Product;

Record mode;

Meeting mode;

Privacy;

How it works;

Download;

GitHub;

Documentation;

Terms;

Security.

Optional later:

Changelog;

Architecture;

Model manifest;

FAQ;

Support.

22.6 Interactive product visualization

At least one product concept should be demonstrated.

Preferred:

pointer moving across multi-display topology;

tasteful perimeter glow follows attention;

sparse context event appears;

transcript + context becomes an evidence-backed Loose End.

The demo must not imply that the browser can perform native capture.

It is explanatory.

22.7 Design research gate

Before visual implementation:

inspect current references from:

Refero;

Landbook;

SiteInspire;

Godly;

Mobbin for product UX;

Apple design references.

collect at least 12 relevant examples;

extract specific useful mechanisms;

propose three materially different design directions;

choose one;

save docs/design/DESIGN.md;

implement against that contract;

visually verify at desktop and mobile sizes.

22.8 Anti-template rules

Avoid:

generic AI gradients;

glowing orb hero;

giant centered headline with no composition;

endless rounded cards;

three identical feature columns;

fake dashboard screenshot;

pill overload;

generic Inter-only identity;

stock AI art;

fake testimonials;

fake customer logos;

invented metrics;

every section centered;

decorative glass everywhere;

meaningless grid background;

animated particles with no product meaning.

22.9 Web performance

SSR HTML must be useful before hydration;

interactive demo lazy-loaded;

no unnecessary D1;

no third-party analytics by default;

no autoplay video with audio;

accessible without motion;

strong CSP;

immutable hashed assets;

no-store dynamic HTML;

responsive from narrow mobile to wide desktop.

23. Shared authorities

Maintain one source for:

docs/legal/privacy.md;

docs/legal/terms.md;

SECURITY.md;

product capability definitions;

model manifest;

export-format definitions where practical;

session schema version;

website/app terminology.

The macOS app and website should consume the same legal text.

Do not maintain separately edited copies.

24. Repository transition

24.1 New repository

Create public:

rogu3bear/open-scribe

Do not fork Speaker Scribe.

Do not mutate Speaker Scribe into the new project.

24.2 Legacy preservation

Before archiving Speaker Scribe:

create a final archival branch/tag if useful;

update README with:

archived status;

successor link;

preserved releases;

no promise of new features;

ensure Open Scribe README exists;

ensure Open Scribe repository is usable;

preserve issues and releases;

archive, do not delete.

24.3 Legacy import

Open Scribe should eventually import Speaker Scribe audio files and standard exports.

It does not need to import its internal Python job store unless a real user need exists.

24.4 Legacy knowledge

Review and preserve as documentation or fixtures:

diarization heuristics;

failure cases;

packaging lessons;

code-signing lessons;

offline verification;

legal SSOT;

model observations;

demo-fixture discipline.

Do not copy implementation wholesale.

25. Build and development workflow

25.1 Shell-first development

Normal development must not require manual Xcode GUI interaction.

Create:

./script/build_and_run.sh
./script/check.sh
./script/test_capture.sh
./script/build_web.sh
./script/verify_bundle.sh
./script/release.sh

25.2 build_and_run.sh

Must:

stop prior development instance;

build Rust core;

generate/check UniFFI bindings;

build macOS application;

launch fresh .app;

support:

--verify;

--logs;

--telemetry;

--debug.

25.3 Repository-wide checks

script/check.sh should eventually cover:

rustfmt;

clippy;

Rust tests;

WASM compatibility for shared crates;

dependency boundary checks;

UniFFI generation consistency;

Swift build/tests;

Leptos SSR build;

hydration build;

Worker build;

web route validation;

legal SSOT;

no template remnants;

license and notices;

no secrets;

diff hygiene.

25.4 CI

Required jobs:

Rust native;

Rust WASM-safe crates;

Swift/macOS build;

UniFFI consistency;

website build;

security/dependency audit;

packaging smoke;

release-only notarization workflow;

fixture tests.

Do not expose signing secrets to untrusted pull requests.

26. Distribution and updates

26.1 Initial distribution

GitHub Releases;

canonical download from open-scribe.app;

signed .app;

notarized DMG;

SHA-256;

release notes;

minimum OS/architecture stated.

26.2 Updates

Preferred:

Sparkle 2;

EdDSA-signed appcast;

HTTPS;

manual check;

automatic checks optional;

explicit update activity.

26.3 Packaging

The app should not bundle multiple large models by default.

Release artifacts:

application DMG;

optional future full-offline DMG;

model manifests;

source archive;

SBOM or dependency manifest;

checksums.

26.4 Release proof

Release is not green because source builds.

It is green when the exact distributed artifact:

launches;

has valid nested signatures;

passes Gatekeeper;

has a stapled notarization ticket;

records a fixture;

survives forced termination;

recovers media;

transcribes offline when model is present;

preserves its signature after use;

downloads from canonical public path.

27. Observability and diagnostics

27.1 Unified logging

Use privacy-safe structured logs.

Log:

state transitions;

permission state;

source identity;

model identity;

durations;

error codes;

counts;

hashes where useful.

Do not log:

transcript text;

OCR text;

participant names;

window content;

raw prompts;

provider secrets.

27.2 Local diagnostics bundle

User can export a diagnostics package containing:

app version;

OS version;

architecture;

permission state;

model state;

device/source state;

recent privacy-safe logs;

session IDs and status, not content;

signature status.

27.3 Telemetry

No telemetry by default.

Any future analytics or crash reporting must be:

opt-in;

separately documented;

content-free by default;

revocable;

removable at build time where practical.

28. Performance budgets

Initial targets, subject to measurement:

28.1 Idle

near-zero CPU;

no model loaded unnecessarily;

bounded memory;

no active capture;

no pointer sampling unless context mode is armed.

28.2 Recording without ML

stable for at least four hours;

no dropped audio under supported load;

UI remains responsive;

reasonable energy impact;

sequential media writes.

28.3 Live transcript

processing remains faster than real time on baseline supported hardware;

capture is never blocked by transcription;

backpressure drops provisional intelligence before dropping audio;

model load and memory pressure visible.

28.4 Context observation

no full-frame persistence by default;

frame sampling bounded;

OCR only after attention/change conditions;

no continuous LLM calls;

multi-display overlays remain smooth.

28.5 Finalization

may use more resources;

can be paused/cancelled where safe;

source recording remains playable;

UI remains interactive.

29. Testing strategy

29.1 Unit tests

domain transitions;

evidence relationships;

status semantics;

transcript normalization;

marker behavior;

memory-item validation;

prompt output parsing;

export formatting;

clustering helpers;

path safety;

retention rules.

29.2 Integration tests

Swift/Rust bridge;

SQLite migrations;

event append/read;

session recovery;

ASR provider;

diarization;

model catalog;

context event ingestion;

provider scope enforcement;

portable archive.

29.3 Capture matrix

Test:

built-in microphone;

AirPods;

USB microphone;

ChatGPT Voice;

FaceTime;

browser audio;

Zoom;

Meet;

Teams;

selected app;

all system audio;

source app quit;

device route change;

sleep/wake;

display hot-plug;

permission revocation;

disk full;

forced termination;

two-hour and four-hour runs.

29.4 Multi-monitor matrix

At minimum:

laptop only;

laptop + one external;

two externals;

four-screen mixed orientation;

vertical display;

display removed while watched;

pointer crossing boundaries;

different scale factors;

different refresh rates.

29.5 Context privacy tests

password fields;

notifications;

permission revoked;

excluded app;

lock screen;

screenshots disabled;

meaningful OCR delta;

unchanged content;

fast pointer transit;

dwell threshold;

raw frame deletion.

29.6 LLM safety tests

prompt injection in transcript;

prompt injection in OCR;

malformed structured output;

unsupported claim;

contradicted evidence;

owner inference error;

proposal vs decision;

mentioned vs completed;

remote provider scope violation;

provider timeout;

cost budget exhausted.

29.7 Accessibility tests

keyboard only;

VoiceOver;

reduced motion;

increased contrast;

screen zoom;

no color-only state;

focus restoration;

menu bar labels.

29.8 Website tests

SSR routes;

hydration;

deep links;

404;

CSP;

canonical metadata;

OpenGraph;

responsive layout;

keyboard navigation;

reduced motion;

no template copy;

download path;

GitHub path;

legal SSOT.

29.9 Packaging tests

clean machine;

no developer tools;

no pre-existing model cache;

offline recording;

offline transcription with installed model;

Gatekeeper;

signature before and after run;

notarization;

update feed;

canonical DMG.

30. Success measures

No hidden analytics are required.

Primary dogfood success:

At least 20 real sessions with zero lost recordings.

At least five sessions longer than 60 minutes.

At least one forced-termination recovery.

Start recording in no more than two deliberate interactions from idle.

No ambiguity about active capture source.

Final transcript linked to playback.

Loose Ends produces at least one genuinely useful recovery in real use.

No remote data transfer when configured local-only.

Four-display attention behavior remains understandable and non-intrusive.

The exact public artifact passes release verification.

Engineering measures:

capture startup success rate;

interrupted-session recovery rate;

dropped-frame/audio count;

track drift;

live transcript lag;

final transcript time;

context-event rate;

raw-frame retention count;

model-run provenance completeness;

evidence coverage of derived claims.

These may be shown locally in diagnostics.

31. Milestones

Milestone 0 — repository, identity, design, and architecture

Deliver:

new public repository;

Speaker Scribe archival notice and archive;

Cargo workspace;

SwiftUI shell;

MenuBarExtra;

Settings;

Rust shared crates;

UniFFI proof;

Leptos-CF web foundation;

open-scribe.app identity;

DESIGN.md;

legal SSOT;

build scripts;

CI skeleton.

Do not implement capture or ML.

Acceptance:

one command builds and launches app;

website builds;

shared crates compile for WASM;

no Python/Tauri/FastAPI/React;

no starter visual language remains;

architecture documentation exists.

Milestone 1 — reliable recorder

Deliver:

microphone capture;

selected application/system audio;

separate tracks;

mix;

menu bar controls;

pause/stop;

markers;

recovery journal;

playback;

import;

library;

crash recovery.

Acceptance:

two-hour synchronized recording;

forced termination recovery;

source failure handled;

no transcript required;

no lost audio.

Milestone 2 — transcription and speakers

Deliver:

model manager;

local final transcription;

live provisional transcript;

transcript document;

click-to-seek;

diarization;

source-aware identity;

exports;

search.

Acceptance:

offline transcription with installed model;

clear Draft vs Final;

user rename;

transcript/audio synchronization;

no Python.

Milestone 3 — Meeting mode and attention field

Deliver:

participant/topic preflight;

Follow Pointer;

display/window/region scope;

perimeter glow;

local change detection;

Vision OCR;

sparse context events;

scope inspector;

context pause;

no pixel retention default.

Acceptance:

four-display test;

unchanged screen creates no event;

fast pointer transit ignored;

permission revocation stops context;

user can always inspect scope.

Milestone 4 — meeting memory

Deliver:

provider abstraction;

local live intelligence;

optional remote review;

structured memory;

decisions;

commitments;

open loops;

Loose Ends;

evidence navigation;

model receipts;

human adjudication.

Acceptance:

no unsupported material claim;

every material item cites evidence;

prompt-injection fixtures pass;

provider scope enforced;

app useful with LLM disabled.

Milestone 5 — public release

Deliver:

polished app UX;

website;

documentation;

security policy;

third-party notices;

signed updates;

notarized DMG;

release verification;

downloadable artifact;

canonical domain deployment.

Acceptance:

exact artifact passes all release proof;

website claims match implementation;

no fake features;

no unresolved P0 failures.

32. Priority classes

P0 — must never fail silently

explicit capture authority;

recording state truth;

media durability;

recovery;

source identity;

local-only network policy;

provider scope;

evidence/interpretation separation;

deletion;

permission revocation;

security of secrets;

no transcript/OCR in logs.

P1 — required for useful release

menu bar;

library;

playback;

local transcript;

import/export;

speaker rename;

search;

context scope UI;

activity receipts;

signed/notarized distribution.

P2 — valuable after foundation

live intelligence;

remote review providers;

remembered voice identity;

Calendar/Contacts enrichment;

portable session package;

rich interactive web demo;

automatic updates;

optional full offline bundle.

33. Product risks and mitigations

33.1 Long-session capture failure

Mitigation:

segmented durable media;

recovery journal;

fault injection;

long-run tests;

capture isolated from ML backpressure.

33.2 Multi-monitor UX becomes intrusive

Mitigation:

perimeter glow only;

short confirmation;

low opacity;

no permanent boxes;

reduced-motion path;

easy pause.

33.3 Context observation feels like surveillance

Mitigation:

explicit scope;

local OCR;

discard pixels;

current-scope display;

activity receipts;

no background activation;

application denylist.

33.4 LLM invents commitments

Mitigation:

structured statuses;

evidence requirement;

proposal/agreement distinction;

human adjudication;

unsupported claims omitted.

33.5 Prompt injection from watched content

Mitigation:

observed content treated as data;

no tools;

schema output;

adversarial tests;

provider sandbox.

33.6 Swift/Rust bridge complexity

Mitigation:

coarse UniFFI;

no frame-rate callbacks;

hot path through bounded native buffer only if needed;

contract fixtures;

generated bindings checked in or deterministically generated.

33.7 Model licensing

Mitigation:

manifest;

source/license per weight;

no undisclosed bundled weights;

third-party notices;

legal review before release.

33.8 Website dictates app architecture

Mitigation:

share semantics only;

separate UI;

no cloud backend dependency;

shared crates remain platform neutral.

33.9 Open-source support burden

Mitigation:

narrow supported platform;

strong diagnostics;

documented build;

issue templates;

no plugin API initially;

clear experimental labels.

33.10 Recording-law exposure

Mitigation:

explicit user reminder;

visible recording state;

no stealth;

legal terms;

no claim of jurisdictional compliance.

34. Documentation requirements

Required at repository bootstrap:

README.md;

ARCHITECTURE.md;

CONTRIBUTING.md;

SECURITY.md;

LICENSE;

THIRD_PARTY_NOTICES.md;

docs/legal/privacy.md;

docs/legal/terms.md;

docs/design/DESIGN.md;

docs/architecture/;

docs/models/;

docs/release/;

docs/data-format/;

docs/threat-model.md;

AGENTS.md.

Required ADRs should cover:

SwiftUI + Rust + Leptos;

UniFFI boundary;

capture ownership;

persistence model;

model engine;

diarization model;

minimum macOS;

update mechanism;

sandbox decision;

remote-provider policy.

35. Agent execution contract

An implementation agent working from this PRD must:

Inspect relevant source before mutation.

Preserve a clean evidence trail.

Separate observed facts, decisions, and unknowns.

Avoid secrets in prompts, logs, source, and child tasks.

Avoid broadening scope beyond the active milestone.

Keep one mutator per working tree.

Preserve unrelated work.

Do not archive Speaker Scribe before the successor repository is usable.

Do not deploy or mutate Cloudflare without explicit authority.

Use cfctl for live Cloudflare account reads/plans/applies where available.

Do not claim deployment from a build result.

Do not claim recording support from mocked capture.

Do not claim local-only behavior without a network-denial test.

Do not claim recovery without forced-termination proof.

Do not claim evidence grounding if derived claims cannot navigate to sources.

Do not introduce Python, Tauri, Electron, FastAPI, or a localhost app server.

Stop on a material architecture conflict rather than hiding it.

36. Stop conditions

Stop and report rather than silently changing the product if:

reliable separate-track capture cannot be achieved with the selected platform path;

the FFI design requires frame-rate object serialization;

the shared domain layer requires native-only dependencies;

the website becomes required for app functionality;

recording requires cloud access;

a model license is incompatible with distribution;

capture permission cannot be represented honestly;

the application cannot recover media after forced termination;

a remote provider receives data outside authorized scope;

context observation retains raw pixels despite the configured discard policy;

derived claims cannot retain evidence references;

the exact distributed artifact cannot pass signing/notarization verification;

the design remains visibly template-derived;

public website claims exceed implemented behavior.

37. Required final report for each milestone

Report:

exact repository and commit;

files changed;

architecture decisions;

tests run;

build artifact;

runtime proof;

screenshots or visual proof where relevant;

permission state;

network behavior;

release state;

known failures;

residual unknowns;

next milestone;

explicit statement of anything not completed.

38. Founding acceptance statement

Open Scribe is ready for its first public release only when all of the following are true:

a user can start recording quickly;

active capture is unmistakable;

microphone and selected application/system audio are preserved;

a forced termination does not destroy the recording;

a local transcript can be produced;

the app works without an account;

no conversation content leaves the Mac in local-only mode;

optional context scope is explicit and inspectable;

raw frames are discarded by default;

meeting-memory claims point to evidence;

the app is usable with all LLMs disabled;

the UI does not look like a generated SaaS template;

the macOS artifact is signed, notarized, verified, and downloadable;

the website is deployed at open-scribe.app;

the public claims match demonstrated capability;

Speaker Scribe remains preserved as the archived predecessor.

39. Immediate bootstrap instruction

The first implementation task is Milestone 0 only.

Do not implement capture, transcription, diarization, OCR, context watching, or LLMs during bootstrap.

Bootstrap must create:

rogu3bear/open-scribe;

top-level Cargo workspace;

WASM-safe domain/type/evidence crates;

native Rust core placeholder;

narrow UniFFI proof;

SwiftUI app with primary window, MenuBarExtra, and Settings;

Leptos website initialized from rogu3bear/leptos-cloudflare;

fully replaced starter visual system;

shared legal documents;

architecture and design documents;

canonical shell build/check scripts;

CI boundary checks;

Speaker Scribe archival pointer only after the new repository is usable.

The bootstrap is complete when:

./script/build_and_run.sh --verify launches the macOS application;

./script/check.sh passes;

shared crates compile for wasm32-unknown-unknown;

Swift can render real state returned by Rust;

the Leptos site renders product identity and a distinctive product concept;

no native dependency leaks into shared crates;

no retired stack remains;

no template-facing design remains;

all unresolved decisions are listed explicitly.