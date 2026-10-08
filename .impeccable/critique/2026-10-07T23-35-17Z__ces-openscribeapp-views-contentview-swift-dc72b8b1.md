---
target: Open Scribe native capture truth and control journey
total_score: 25
max_score: 40
na_heuristics:
p0_count: 0
p1_count: 1
target_identity: "file:/Users/star/dev/open-scribe/apps/macos/Sources/OpenScribeApp/Views/ContentView.swift"
target_fingerprint: "sha256:9eba7d20a431c90c191d2d5affb60c6201de1c2d03519a69bb4a6f4e66716d84"
target_path: /Users/star/dev/open-scribe/apps/macos/Sources/OpenScribeApp/Views/ContentView.swift
timestamp: 2026-10-07T23-35-17Z
slug: ces-openscribeapp-views-contentview-swift-dc72b8b1
---
Method: dual-agent (A: /root/assessment_a · B: /root/explore_ui); parent native inspection and synthesis.

STATE: Open Scribe capture truth/control journey, Operate mode, HEAD a1661fe31bcfe00fb75b56ad24d35d28c3334991, tree 42ee77b3e313927996c16c5c85e48cbd073c991b. The incumbent Field Instrument / Evidence Ledger direction fits the product. The smallest first repair is harden for production accessibility transition announcements and paused-state glyph consistency.

DONE: Candidate source/tree and all seven manifest-listed artifact SHA256 values verified. Two assessments remained independent, source-only, and read-only. The parent launched the verified existing artifact, inspected native screenshots and accessibility-tree evidence, opened Sources without changing selection, and observed keyboard focus in transcript search. No capture, permission changes, builds, or implementation edits occurred.

Native evidence: an existing interrupted session clearly exposes Recording interrupted, 00:00:00, two named Failed sources, and the preservation warning. Inspected light/dark and increased contrast, with Reduce Transparency already on. Preferred screenshot size was 2080×1440 pixels; minimum resizing stopped at 1520×1144 pixels. At the apparent 2× scale these correspond to 1040×720 and 760×572 points; 760×520 was not demonstrated. Active Recording, Paused, Starting, long event lists, crowded menu-bar operation, VoiceOver speech and supported-OS fallback behavior remain unobserved. The parent restored original Dark/Increase Contrast off settings, preserved Reduce Transparency on, restored preferred window size, and verified both review-only apps exited.

Design specificity: authored for this product. Capture authority, named independent sources, durable-evidence warnings, and chronological events provide specificity. Quiet native controls and semantic system typography suit Operate mode.

## Source-provisional design score

| Heuristic | Score / 4 | Basis |
|---|---:|---|
| Visibility of system status | 2 | Strong readable facts; announcement wiring and paused glyph gap |
| Match with real world | 3 | Familiar actions; some technical recovery language |
| User control and freedom | 3 | Explicit controls and phase gates; active overflow reachability unobserved |
| Consistency and standards | 2 | Shared native controls; divergent paused cues |
| Error prevention | 3 | Capture/import and source-change gates |
| Recognition rather than recall | 3 | Named states and sources |
| Flexibility and efficiency | 3 | Shortcuts and menu alternatives; complete keyboard traversal unobserved |
| Aesthetic and minimalist design | 2 | Quiet hierarchy; inline history/context growth |
| Error recovery | 2 | Preservation facts; limited next-action guidance |
| Help and documentation | 2 | Contextual help; recovery guidance incomplete |
| Total | 25/40 | Provisional source assessment; no runtime acceptance |

Native audit: accessibility 2/4, performance 3/4, appearance/theming 3/4, platform conformance 3/4, adaptation 3/4; total 14/20, source-provisional. Static checks and the inspected interrupted state do not qualify the remaining native matrix.

## Priority issues

1. P1 — Production lifecycle transitions lack explicit announcement wiring. Source: Stores/FixtureSessionStore.swift:288–323 updates RuntimeLibraryStore; only fixture calls at 407 and 415 invoke AccessibilityAnnouncer.post. CompactLiveView.swift:32–33 and MenuBarContent.swift:169–170 expose current labels but do not connect transition notification delivery. Design contract: docs/design/DESIGN.md:313–318. Impact: a VoiceOver operator focused elsewhere has no source-backed guarantee of hearing Recording, Paused, Degraded, permission loss, or Recovery required. Acceptance: one announcement per material transition; failed source plus continuation named; no timer/poll repetition; Recording only follows durable-state truth. Verify focused-elsewhere delivery on the repaired exact artifact. Suggested command: harden.

2. P2 — Live historical detail has no bounded scroll/disclosure structure. Source: CompactLiveView.swift:19–80 inserts context at 64–65 and all events at 68; RecorderControls.swift:80–91 renders every event; ContentView.swift:214–240 supplies no enclosing scroll boundary. Impact: growing evidence and long source/context text compete with present capture truth. Overflow is a structural risk, not a reproduced long-list failure. The resize observation also leaves the promised 760×520 window unqualified; content-versus-outer-window sizing needs reconciliation. Acceptance: true supported minimum and preferred size with long labels, active context, and at least 30 events; status/timer/source health remain visible, capture and scope controls remain reachable, history is inspectable with keyboard/VoiceOver, and the minimum is not silently raised. Suggested command: layout, after native reproduction.

3. P2 — Paused glyphs disagree across surfaces. Source: CompactLiveView.swift:98–106 uses record.circle for ordinary paused sessions; MenuBarContent.swift:30–32 uses exclamationmark.circle for any non-recording current session; MenuBarContent.swift:217–220 uses waveform for a paused current session, while its controller-only paused branch at 228–229 uses pause.circle. Design contract: docs/design/DESIGN.md:290,307. Impact: intentional pause can look like ready, failure, or unspecified audio activity. Acceptance: consistent approved pause presentation across live detail, opened menu, and menu label, including session-backed/controller-only paths; preserve distinct degradation/interruption truth and macOS 13 fallback behavior. Suggested command: harden.

Strengths: truthful interrupted status is visibly redundant and present in the AX tree; shared recorder controls preserve native interaction patterns; failed snapshots clear the current session instead of retaining a stale Recording claim.

Persona implications: accessibility-dependent operators need timely transition delivery; frequent operators need capture truth to remain easy to scan as events accumulate; first-time operators need one consistent meaning for pause.

NEXT: Harden only native presentation announcements and paused cues first. Reproduce dense-live layout before selecting a layout repair. Polish the repaired bounded journey afterward. Implementation changes and any capture/permission-based verification require their own authorized scope; this review does not perform them.

Questions skipped: user supplied priorities, read-only scope, and explicitly requested parent selection of the next repair command; no consequential missing design intent was found.
