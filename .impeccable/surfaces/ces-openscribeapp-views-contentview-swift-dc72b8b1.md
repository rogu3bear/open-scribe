---
version: 1
slug: "ces-openscribeapp-views-contentview-swift-dc72b8b1"
primary_target: "apps/macos/Sources/OpenScribeApp/Views/ContentView.swift"
related_targets: ["apps/macos/Sources/OpenScribeApp/Views/MenuBarContent.swift"]
---

# Open Scribe main window and menu bar

Scope: the native macOS main window (library sidebar, conversation document,
live recording), the menu-bar recorder, and the Copy output. Mode: Operate.

Audience and job: one Mac user on back-to-back calls who wants every
conversation from any microphone and any app kept, readable while it happens,
named, titled, and pasted into ChatGPT or similar in one click.

Constraints: native controls and navigation; SwiftUI with narrow AppKit only
where SwiftUI cannot; Rust owns durable state and text formats; on-device
Apple speech and Apple Intelligence only (never Private Cloud Compute);
macOS 13 floor with newer features gated; full keyboard and VoiceOver; state
never by color alone.

Unresolved: diarization of several remote voices on one computer-audio track;
calendar-based titles (needs a Calendar permission the user has not asked for).

## Direction contract

THESIS: Every conversation is typeset like a published interview the moment
it is spoken, so reading, checking, and copying are one surface. It refuses
the category default of chat bubbles under an AI-summary card, and the
forensic evidence-log look the previous design drifted into.

OWN-WORLD: Apple's New York serif for title and transcript at a 68-character
measure on paper white (#FBFBF8, dark #1C1C1B); speaker names as bold SF
small caps run in before each turn; timestamps hang in the left shoulder as
small monospaced digits; one ink blue (#1F3A93, dark #8FA8F0) for the
primary action, the playing passage, and links; secondary #6E6E73; no
cards, no gradients, no badges; system sidebar and toolbar.

STORY: The user presses Record, watches the interview fill in line by line,
presses Stop, and finds a titled conversation with names already suggested.
They press Copy and paste the interview, names and all, into another app.

FIRST VIEWPORT: Sidebar of conversations grouped Today / Yesterday / earlier,
each a real title over date and length. The document column, centered: a
30-point New York title, a one-line meta row (date, time, length, people),
an action row with Copy as the prominent button, then Play and More; a quiet
name-suggestion line when one exists; then the interview itself. While
recording, the same column shows a live timer and sources in the meta row
and new lines arrive at the end, settling from secondary gray to ink.

FORM: The Interview Page (magazine Q&A typesetting), first on the ordered
grounded list, chosen by the user as the pick card; seed key 5c45929b.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
