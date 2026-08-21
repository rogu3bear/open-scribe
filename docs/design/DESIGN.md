# Open Scribe Design Contract

**Status:** design strategy and implementation assumptions decided; product implementation and rendered verification pending.

**Decision date:** 2026-08-20

**Authority:** presentation and interaction projection of `docs/product/FOUNDING_PRD.md`; it does not supersede product purpose, architecture, milestone scope, or the state machine.

**Selected direction:** Field Instrument / Evidence Ledger.

## 1. Scope and proof boundary

The current native interface is a developer-facing Milestone 0 proof. Preserve it as a small, honest diagnostic composition whose only jobs are to show that:

1. SwiftUI is alive;
2. the Rust core is connected; and
3. product capabilities are not implemented.

Do not add a recorder, timer, source picker, timeline, transcript, future settings, branded visual system, or disabled product controls to the M0 proof. Product UI replaces that composition in a later authorized milestone; it does not accumulate around it.

This document selects a direction for intended product and website work. It does not prove capture, durability, recovery, accessibility, a built website, signing, release, or any rendered product state.

### Evidence labels

- **OBSERVED:** directly present in repository authority, implementation, a referenced page, or the one successful rendered gallery inspection.
- **INFERRED:** a design conclusion constrained by observed evidence.
- **UNKNOWN:** requires implementation, runtime inspection, licensing review, or user research.

## Strategy kernel

### Diagnosis — the crux

Open Scribe is a chain-link product: capture authority → durable media → recovery → truthful state → readable evidence → derived interpretation. The weakest unbuilt link is the contract between durable Rust state and what SwiftUI is allowed to say. A polished recorder, website, transcript, or brand system created before that link is proven would amplify the most damaging possible failure: presenting Ready or Starting as Recording, hiding a failed source, or making derived output look more authoritative than evidence. The current M0 shell is honest precisely because it refuses those claims. This diagnosis is wrong if a deterministic coarse state contract cannot drive the menu bar, compact live surface, recovery presentation, and review status without frame-rate media data or speculative UI state.

### Guiding policy

Concentrate design and the first authorized product implementation on one end-to-end truth chain: durable Rust lifecycle and conditions → coarse UniFFI state → redundant native menu/live presentation → transition and recovery proof. Use native platform defaults everywhere that is not part of this chain, because Open Scribe's specific advantage is inspectable local evidence and capture authority—not an AI aesthetic, cloud collaboration, or visual novelty.

Therefore Open Scribe will not:

- grow product UI around the M0 diagnostic shell;
- implement the website visual direction in parallel with the first native truth tranche;
- use custom native fonts, a decorative native palette, recording red as branding, or motion as status;
- make transcript, AI memory, evidence graphs, or context observation the first product surface;
- send frame-rate meters, waveforms, pointer samples, or media through the ordinary UniFFI state contract;
- claim Recording, recovery, accessibility, website behavior, release, or deployment from a lower proof plane.

### Sources of power

- **Chain-link discipline:** repair the truth-contract link before investing in later presentation links.
- **Design-type coordination:** Rust state, UniFFI payload, SwiftUI semantics, accessibility announcements, and failure tests are designed as one matched system.
- **Focus:** over-invest in unmistakable capture authority while better-funded meeting products compete on summaries, bots, collaboration, and visual abundance.
- **Leverage:** one correct coarse state contract governs every native truth surface and prevents entire classes of copy, icon, timing, and recovery defects.

### Proximate objective

In the first operator-authorized post-M0 implementation tranche, produce one deterministic, non-media state fixture consumed by SwiftUI that covers Idle, Ready, Starting, Recording, Paused, Finalizing, Ready for Review, Degraded, Permission revoked, and Recovery required. It is done only when automated Rust/UniFFI tests prove that Recording is impossible before durable journal and media preconditions, and the native menu and compact live surface render every fixture with label, symbol, sources, timer behavior, accessibility value, and recovery action. The first tranche does not implement transcript, AI, context observation, website visuals, signing, or release.

### Coherent actions

| Sequence | Action | Owner and resources | Start | Done-test | Reinforces |
|---:|---|---|---|---|---|
| 0 | Lock the decisions in this contract. | Repository design authority; this document and current research only. | Now. | Direction, state meanings, window target, symbols, typography, web palette, meter cadence, overlay values, no-list, and revision triggers are explicit. | Every later action uses one contract. |
| 1 | Define the coarse lifecycle/condition payload and deterministic fixtures. | Rust core owner plus macOS integration owner; one bounded Rust/UniFFI tranche and contract tests. | First two weeks after explicit post-M0 authorization. | Every state/condition fixture round-trips; Recording requires durable preconditions; no frame-rate or media payload crosses the contract. | Makes actions 2 and 3 testable without fake capture. |
| 2 | Build the two truth surfaces from the same fixture. | macOS UI owner; one bounded SwiftUI tranche using native components. | Immediately after action 1. | Menu bar and compact live surface render the full matrix; Ready/Starting cannot be mistaken for Recording under keyboard and VoiceOver inspection. | Exposes contract drift before real capture raises the stakes. |
| 3 | Prove real transitions, failure, and recovery against the surfaces. | Capture/recovery integration owner with macOS UI owner; one joint runtime-proof tranche. | Only after capture implementation is explicitly authorized. | Starting → Recording occurs only after durable media/journal state; pause, source failure, permission revocation, forced termination, and recovery receipts match visible state. | Converts fixture truth into artifact truth. |
| 4 | Unlock review and website presentation only after the truth chain passes. | Repository operator; no preallocated implementation lane. | After action 3's exact-head receipt. | A reviewed decision authorizes the next milestone; otherwise those lanes remain stopped. | Preserves concentration and prevents design debt built on false state. |

### Review trigger

Re-test this diagnosis when the first exact native artifact completes the state matrix, or earlier if action 1 shows that one coarse contract cannot serve both menu and live surfaces. Revise decisions from observed failures; do not reopen them because an untested alternative is fashionable.

## 2. Repository design evidence

### OBSERVED — upstream constraints

- Open Scribe is a private Mac conversation instrument, not an AI meeting dashboard.
- Capture authority is explicit. Ready is never Recording.
- Recording requires redundant visible signals: state label, timer, active sources, menu-bar state, and immediate failure indication.
- Raw evidence is authoritative; derived interpretation remains visibly secondary and traceable.
- Reliability and recoverability precede transcript and intelligence.
- During recording, the product avoids dashboards, card walls, forced live transcript, and repeated AI interruption.
- The main app uses a native two-pane conversation library and document detail with an optional inspector.
- The menu bar is a remote control, not the product.
- The compact live recording window is the focused capture truth surface and opens without requiring the library.
- Review reads as a conversation document: no chat bubbles and no card per utterance.
- Context attention uses bounded perimeter luminance and depth, not persistent crop-box framing.
- SwiftUI owns native UI; AppKit is limited to narrow platform gaps.
- The website explains native behavior but must not imply browser capture.

### OBSERVED — current implementation

- `ContentView.swift`, `MenuBarContent.swift`, and `SettingsView.swift` use native SwiftUI structures and truthful M0 copy.
- No product state model, capture surface, transcript surface, custom palette, or visual token system exists.
- The M0 proof has a 600 × 360 minimum content frame and a 680 × 440 default window. Those dimensions belong to the proof, not to the future product window.

### INFERRED — design thesis

The interface should earn trust through state precision, durable-document hierarchy, and native behavior. Decoration must never carry authority that the state contract cannot prove.

## 3. Reference research

Research was performed on 2026-08-20. Apple pages are current platform guidance. Gallery examples are mechanism references, not authorities and not palettes to copy. Where a gallery exposed only metadata, the current product or documentation page supplied the behavior observation.

### Apple platform guidance

| Reference | Mechanism extracted | Contract effect |
|---|---|---|
| [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/) | Resizable windows, large-display information density, menu commands, keyboard workflows, and user control are native expectations. | Use standard windows, commands, shortcuts, adjustable panes, and hideable secondary detail. |
| [Windows](https://developer.apple.com/design/human-interface-guidelines/windows) | System appearances and foreground/background distinctions carry window state. | Avoid custom window chrome and opaque surface inventions that defeat system state. |
| [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars) | Sidebars expose a broad, flat hierarchy and should be hideable when content needs space. | The conversation library uses a standard hideable sidebar; it is not a decorative rail. |
| [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) | Toolbars orient and act on current content; overflow should be deliberate. | Keep session-level actions few, contextual, and overflow-safe. |
| [Menus](https://developer.apple.com/design/human-interface-guidelines/menus) | Menus are space-efficient command surfaces with familiar labeling and state behavior. | Keep the menu-bar surface short and command-oriented, with full commands also available from the app menu. |
| [Typography](https://developer.apple.com/design/human-interface-guidelines/typography) | macOS system typography has semantic roles; hierarchy must survive scaling and remain legible. | Native UI uses semantic system styles and weights; timer digits are tabular. No custom native font is approved. |
| [Color](https://developer.apple.com/design/human-interface-guidelines/color) | Dynamic semantic colors adapt to appearance and contrast settings; color cannot be the sole signal. | Native color roles map to system colors. Recording red has one semantic meaning and always has text plus glyph support. |
| [Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode) | System backgrounds preserve elevation and desktop tinting across appearances. | Prefer system backgrounds and materials; custom surfaces require a demonstrated hierarchy need. |
| [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility/) | Interfaces must be perceivable through more than one channel, support larger text, meet contrast guidance, and be audited with Accessibility Inspector. | Every state has label, glyph, and accessibility value; product acceptance includes assistive-technology runtime proof. |
| [Motion](https://developer.apple.com/design/human-interface-guidelines/motion) | Motion must be purposeful, optional, and never the only feedback. | No pulsing recording ornament or perpetual ambient motion; reduced-motion behavior is specified below. |
| [Playing audio](https://developer.apple.com/design/human-interface-guidelines/playing-audio) | Audio controls keep conventional meaning and must respond honestly to interruptions. | Record/play controls are not repurposed; interruption and route changes surface as explicit state or condition. |

### Fifteen product and presentation examples

| Surface | Example | Exact mechanism learned | Adopt, adapt, or reject |
|---|---|---|---|
| Refero | [Grain](https://styles.refero.design/style/04793c2a-ca1a-4edd-a661-56c965e42aec) | Spacious document-like surfaces, hairline structure, and one rationed accent can create hierarchy without heavy containers. | **Adapt:** use restrained separation and color rationing. **Reject:** floating screenshot cards as the native product metaphor. |
| Refero | [Granola](https://styles.refero.design/style/d6c2a911-45ed-4860-a992-43df22793c2a) | Editorial hierarchy makes notes read as a document; hairline rules can separate content without turning every unit into a card. | **Adapt:** transcript and review hierarchy. **Reject:** importing its parchment palette, pill language, or custom type identity. |
| Refero | [Paste](https://styles.refero.design/style/742b500d-3e10-4daa-bb89-d0d26272e5f6) | A system-font stack reinforces the product as an operating-system extension. | **Adopt for native:** platform typography and behavior lead identity. **Reject:** feature-category color as product-state language. |
| Landbook | [Granola](https://land-book.com/websites/98149-granola-the-ai-notepad-for-back-to-back-meetings) | A meeting product can lead with a notepad/document identity instead of a control-room or bot metaphor. | **Adapt for web:** explain review as authored memory. Keep evidence lineage more prominent than AI polish. |
| Landbook | [Amie](https://land-book.com/websites/33414-amie-joyful-productivity) | A product story can be distributed across focused page types instead of forcing every capability into one landing composition. | **Adapt for web IA:** give Record, Meeting, Privacy, and How It Works distinct narrative jobs. **Reject:** playful productivity tone for recording authority. |
| Landbook | [Otter.ai](https://land-book.com/websites/37953-otter-ai-sign-up-for-real-time-and-shareable-meeting-notes) | Signup and pricing surfaces can overtake the product explanation when account conversion is the primary frame. | **Reject as a product model:** Open Scribe leads with local capability, source truth, and download; no account is required. |
| SiteInspire | [Milanote](https://www.siteinspire.com/websites/category/mobile-and-web-applications/page/4) plus [current product](https://milanote.com/product/note-taking) | An infinite visual board helps people discover spatial relationships before finalizing a document. | **Reject:** conversation evidence is chronological. No spatial evidence explorer belongs to the selected implementation sequence; a future proposal requires a separate authorization and must not replace the transcript. |
| SiteInspire | [Craft CMS](https://www.siteinspire.com/website/6473-craft-cms) plus [Live Preview](https://craftcms.com/docs/getting-started-tutorial/build/preview.html) | A split view can keep source edits and their realized result visible together. | **Adapt:** evidence inspection may keep the cited transcript range beside a derived claim; the inspector stays optional. |
| SiteInspire | [Toggl](https://www.siteinspire.com/website/8024-toggl) plus [current timer model](https://docs.toggl.com/time-tracking-in-toggl-2-0) | A running timer is glanceable above a chronological log, with starting and review available from the same mental model. | **Adapt for compact live surface:** state and timer first. **Reject for library:** the timer must not dominate completed conversations. |
| Godly | [Notion](https://godly.website/website/notion-1013) | A document can reveal structured blocks and secondary tools without losing the page as the dominant object. | **Adapt:** conversation document first, optional evidence tools second. **Reject:** generic block-editor behavior for immutable evidence. |
| Godly | [Paste](https://godly.website/website/paste-977) | A desktop product can be explained on the web through recognizable app behavior and OS context. | **Adapt for web:** show platform-specific moments rather than a fake browser dashboard. **Reject:** bento-grid accumulation and decorative feature color. |
| Godly | [Limitless directory reference](https://godly.website/?types=%5B%22ai%22%5D) | Ambient-capture products often present intelligence as the dominant promise. | **Reject:** Open Scribe must show explicit capture authority and evidence preservation before interpretation. |
| Mobbin | [N26 pattern summarized by Mobbin](https://mobbin.com/mcp) | Regulated flows use visible step progress before a sensitive capture step. | **Adapt:** permission and provider authorization use short, explicit preflight progression when multiple decisions are unavoidable. |
| Mobbin | [Monzo pattern summarized by Mobbin](https://mobbin.com/mcp) | A pre-capture explanation states what will happen and why before opening a sensitive system surface. | **Adopt:** explain the selected source and data consequence immediately before the platform permission request. |
| Mobbin | [Qantas pattern summarized by Mobbin](https://mobbin.com/mcp) | Trust language is placed inline at the decision, including what is and is not retained. | **Adopt:** local/remote scope and retention truth stay adjacent to authorization controls, not hidden in generic privacy copy. |

### Research limitations

- One Refero page was inspected successfully as a rendered Safari surface. The next Computer Use navigation failed and then timed out, so the GUI attempt stopped instead of being looped.
- Refero provided detailed current visual-system descriptions for three examples.
- Landbook, SiteInspire, and Godly public pages provided current gallery metadata; current product/docs pages supplied behavior where gallery detail was sparse.
- Mobbin's public MCP page exposed named pattern summaries, not full authenticated product flows.
- Therefore the examples are adequate for mechanism selection, but they are not a substitute for the rendered product matrix in section 12.

## 4. Structural directions considered

### Direction A — Field Instrument / Evidence Ledger — selected

**Structure:** native conversation library → chronological conversation document → optional evidence inspector; compact live recorder and menu-bar remote remain separate surfaces.

**Visual center:** the recorded conversation and its lineage. Controls are quiet until an explicit action or condition requires attention.

**Strengths:** directly realizes the founding IA; preserves evidence over interpretation; separates capture-time urgency from review-time reading; scales from no-AI use to evidence-backed derived memory; fits native macOS structures.

**Risks:** can become visually austere or make derived value hard to discover. Mitigate with strong document headings, evidence links, progressive disclosure, and excellent empty states—not cards or decoration.

**Accessibility effect:** predictable reading order, semantic headings, keyboard navigation, and optional inspector reduce traversal burden. State remains redundant and explicit.

### Direction B — Recording Console — rejected

**Structure:** persistent transport, large meters, waveform, source channels, and session timeline dominate the main window; review appears as a secondary tab.

**Useful idea retained:** the compact live window may borrow console clarity: state, timer, sources, meters, marker, stop.

**Reason rejected:** it makes a transient capture phase define the whole product, competes with the conversation document, and encourages decorative “live” treatment even when capture is absent. It also makes the M0-to-product transition particularly vulnerable to false recording semantics.

**Accessibility cost:** continuously moving meters and dense transport controls increase cognitive load and make the document harder to reach.

### Direction C — Meeting Workspace / Evidence Graph — rejected

**Structure:** participants, decisions, commitments, topics, sources, and context events become peer cards or spatial nodes around a session dashboard.

**Useful idea retained:** the optional inspector may group sources, tracks, model runs, exports, and receipts; a future bounded evidence explorer may visualize relationships.

**Reason rejected:** it elevates interpretation and metadata above raw chronology, resembles the retired browser dashboard, and encourages card-per-concept density. It performs poorly before intelligence exists and weakens no-AI usefulness.

**Accessibility cost:** spatial relationships and card traversal create ambiguous reading and focus order unless duplicated linearly.

### Create-destroy result

The selected direction was attacked on three plausible grounds and survives narrowly:

- **“It is too quiet to feel differentiated.”** The asymmetry is visible capture authority and evidence lineage. Adding visual novelty would not strengthen that advantage; the website palette and composition carry recognition without changing native state semantics.
- **“A recorder should lead with meters and waveform.”** That is true only during active capture, so those mechanisms remain in the compact live surface. Making them permanent would organize years of review around a temporary state.
- **“AI memory is the marketable value and should lead.”** That would make the interface least useful when AI is disabled and would invert the evidence hierarchy. Derived memory remains discoverable but subordinate and cited.

Reopen the structural direction only if matched usability evidence shows that users cannot find capture controls, cannot distinguish state, or cannot navigate evidence in the selected structure after the specified native hierarchy is correctly implemented.

## 5. Selected direction: Field Instrument / Evidence Ledger

### Design sentence

Open Scribe is a calm native instrument while capture is active and a readable evidence ledger when the conversation is reviewed.

### Hierarchy

1. **Truth now:** current lifecycle label, elapsed time when applicable, active sources, durability/recovery condition.
2. **Evidence:** playback, waveform/timeline, transcript, markers, source events, human corrections.
3. **Interpretation:** decisions, commitments, Loose Ends, summaries, and model status, each with evidence links.
4. **Technical detail:** tracks, models, context scope, exports, receipts, and storage metadata in the optional inspector.

### Native surface roles

| Surface | Role | Must contain | Must not become |
|---|---|---|---|
| Menu bar | Remote control and glanceable capture truth | short state, timer when active, sources, pause/resume, marker, stop, failure/recovery signal, open commands | library, transcript reader, setup wizard, or dashboard |
| Main window | Conversation library and evidence review | hideable sidebar, selected conversation document, playback/timeline, transcript, evidence-linked derived memory, optional inspector | persistent recorder console or card wall |
| Compact live window | Focused capture surface | state, timer, sources, meters where real, marker, stop, optional provisional transcript disclosure | full library or forced live transcript |
| Settings | Durable user preferences | only implemented, persistent configuration grouped by native categories | roadmap, disabled future controls, or permission-status substitute |
| Context overlay | Inspectable watched scope | selected surface identity, bounded perimeter signal, pause/revoke affordance through the controlling UI | crop editor, ambient decoration, or retained screen recording implication |

### Evidence-linked interpretation contract

- Derived memory remains under Interpretation, after chronological Evidence. It never edits transcript, context, markers, corrections, or media in place.
- Every material Decision, Commitment, Open Loop, Loose End, fact, or factual summary statement shows a textual kind and status plus `Evidence (n)`. When contrary evidence exists it also shows `Contradictions (n)`; neither relationship is communicated by color alone.
- Selecting evidence preserves the originating claim and navigates to the exact audio/transcript/context revision and range. Wide layouts may keep claim and source side by side; narrow layouts use an ordered destination plus a `Return to claim` action that restores focus.
- `Unsupported — needs evidence` is permitted only in an explicitly human-authored review queue. Unsupported model material is rejected from canonical memory. `Contradicted` always exposes both supporting and contradicting evidence.
- Human actions are `Accept`, `Correct…`, `Reject`, and `Mark unresolved`. They append adjudication rather than erasing model history. VoiceOver reads kind, status, evidence and contradiction counts, and human state before these actions.
- Provider configuration says `Provider configured — no conversation content authorized`. Every remote review preflight lists transcript, context text, notes, participant/topic, corrections, and existing derived claims as separate unchecked categories. Audio and snapshots are unavailable to Milestone 4 providers.
- With intelligence disabled, the evidence document, playback, transcript/context review, search, correction, and export remain complete. Interpretation is absent or says `Intelligence off`; it is not an upsell and contains no synthetic placeholder items.

### Web surface role

The website explains the product through evidence, privacy, and native behavior. It includes one interactive explanation of pointer-following attention → sparse context event → evidence-linked Loose End, with the same information available as static ordered steps before hydration. The demonstration is visibly labeled explanatory and never implies browser recording.

The website and native app share terminology, capability truth, state meanings, legal sources, and evidence semantics. They do not share component code or seek pixel identity.

### Public website composition

- Primary navigation is Product, How It Works, Privacy, Documentation, and Download. Record and Meeting are named Product destinations; Terms, Security, GitHub, checksums, model manifest, and notices remain visible in the document footer or relevant page.
- Home orders the private Mac instrument thesis, Record, Meeting, local-first privacy, the explanatory evidence demo, and verified Download. Record leads with capture truth, durability, recovery, source identity, and local transcript. Meeting leads with explicit context scope, sparse events, evidence lineage, and optional interpretation.
- How It Works is chronological: authorize, establish durable capture, review evidence, then optionally add context or intelligence. Download shows version/build, macOS/architecture, artifact size and SHA-256, model-bundling posture, release notes, and verification help from the exact release manifest.
- Privacy and Terms render the canonical adopted legal sources. Security renders the canonical policy and disclosure path. Documentation is an index over checked sources, not a second product specification.
- Every functioning-capability statement is a consumer of the verified shipped-binary capability manifest. Without a complete release manifest, Download says `No public release is available` and has no dummy action.

### Static-first website demonstration

- SSR contains the complete four-step sequence: pointer dwell on a named authorized display, one sparse context event, a transcript/context evidence pair, and an evidence-linked Loose End. The label is `Explanatory demonstration — not browser capture`.
- Hydration adds only optional local interaction. Previous/Next remains keyboard operable; pointer travel is not announced; focus/read order stays linear. No-script and hydration-failure states preserve all four steps and their evidence relationship.
- Reduced Motion replaces pointer travel and glow rise with immediate complete frames. No browser capture, microphone, display, storage, model, analytics, or remote-provider API is called.

### App icon contract

- The icon is `Open evidence ledger`: a native rounded Mac volume with a warm-white paper field, graphite open-ledger/spine form, and three restrained evidence/timestamp notches.
- It uses tonal depth but no recording red, microphone, waveform, AI sparkle, letters, glass orb, or additional brand color. Recording red remains product-state truth, never identity.
- The open-ledger silhouette must survive 16- and 32-pixel inspection without the notches. The 1024-pixel master and every asset-catalog rendition require light/dark desktop, small-size, Finder, Dock, Spotlight, and accessibility appearance review.

## 6. State semantics

The top-level lifecycle in the founding PRD remains authoritative:

`Idle → Ready → Recording → Paused → Finalizing → Ready for Review`, with interruption possible from active states.

The UI needs additional transition and condition presentations to avoid lying. These do **not** silently create a competing durable state machine:

- **Starting** is a transient presentation after explicit user intent and before the Rust core proves durable recording.
- **Degraded** is a health condition applied to an active lifecycle state when capture continues with reduced sources.
- **Permission revoked** is an authority condition applied to the affected source and lifecycle state.
- **Recovery required** is the user-facing presentation of an interrupted session requiring repair or confirmation.
- **Complete** is a session durability label within Ready for Review, not a new top-level application state.

### State and condition matrix

| Presentation | What is proven true | Required visible signals | Prohibited signal or copy | Primary user action |
|---|---|---|---|---|
| Idle | No capture is requested or active. | Neutral icon, explicit “Idle,” no timer, no active-source claim. | Red, moving meter, “ready to record” when no sources are selected. | Record or Start Meeting. |
| Ready | Sources/context are selected or suggested; capture durability is not established. | “Ready,” selected source names, authorization summary, neutral non-recording icon. | Timer, red recording signal, active meter presented as captured media. | Start explicitly or adjust sources. |
| Starting | User requested capture; journal/files/permissions are being established. | “Starting…,” progress indicator or static transitional glyph, source names, cancel when safe. | “Recording,” advancing duration presented as captured time, celebratory success. | Cancel or wait. |
| Recording | Capture files are open, journal is durable, timer advances, sources are monitored. | “Recording,” tabular advancing timer, active source labels, distinct recording glyph, menu-bar state, level activity where available. | Color-only signal, pulsing decoration, hidden source failure. | Pause, marker, stop, inspect scope. |
| Paused | Media and context capture are intentionally suspended or segmented; session remains recoverable. | “Paused,” static explicit time behavior, pause glyph, source labels with paused state. | Recording glyph, moving capture meter, ambiguous “stopped.” | Resume or stop. |
| Finalizing | Source audio is already safe; derived work may continue. | “Finalizing,” durable-media confirmation, named remaining work, dismiss-safe explanation. | Blocking spinner with no durable-media truth, “Recording.” | Open session, close window safely, view progress. |
| Degraded | At least one source failed while recoverable capture continues on named remaining sources. | “Recording — degraded” or equivalent, failed source and reason, remaining active sources, warning glyph, immediate menu-bar signal. | Generic warning, success-only treatment, stopping the timer if capture continues. | Repair source, continue knowingly, or stop. |
| Permission revoked | Platform authority disappeared for a named source. | Plain explanation, affected source, what continues, authority glyph, recovery action. | Silent retry, generic error code, implication that revoked content is still captured. | Open system setting or choose another source. |
| Recovery required | A prior session is interrupted and available evidence needs repair or confirmation. | Serious “Recovery required,” session identity, preserved evidence summary, safe next action. | Celebration, automatic deletion, indefinite “Recording.” | Recover, inspect, or defer safely. |
| Ready for Review — Complete | Session is durably closed and playable. | “Complete,” duration, storage location, processing statuses, next review action. | Confusing completion of capture with completion of transcript/AI. | Review, play, export. |

### Menu-bar icon contract

The menu-bar symbols are decided. Implementation checks availability against the macOS 13 deployment target and uses the named fallback rather than inventing a new glyph.

| State | Primary SF Symbol | Fallback | Text contract inside menu |
|---|---|---|---|
| Idle | `waveform` | `circle` | Idle |
| Ready | `waveform.circle` | `waveform` | Ready · source summary |
| Starting | `ellipsis.circle` | `ellipsis` | Starting… |
| Recording | `record.circle.fill` | `circle.fill` | Recording · `00:12:34` |
| Paused | `pause.circle.fill` | `pause.fill` | Paused · `00:12:34` |
| Degraded | `exclamationmark.triangle.fill` | `exclamationmark.triangle` | Recording — degraded |
| Recovery required | `clock.arrow.circlepath` | `clock` | Recovery required |

The accessibility label uses the text contract, never the symbol name. Menu-bar templates may not preserve chromatic red, so shape and menu text carry the state without color. If both primary and fallback are unavailable on a supported OS, the implementation uses the fallback text without an icon and fails the icon-availability test; it does not substitute an unreviewed symbol.

### State announcement contract

- Announce transitions into Recording, Paused, Degraded, permission loss, and Recovery required.
- Do not announce every timer tick, meter update, provisional transcript token, or unchanged context event.
- Source failure announcements name the failed source and whether capture continues.
- Starting never announces Recording until the durable-state event arrives from Rust.

## 7. Semantic visual vocabulary

### Typography

#### Native

- Use San Francisco through semantic SwiftUI/AppKit text styles.
- Use regular, medium, semibold, or bold weights; avoid thin and light weights.
- Document title: semantic title style, semibold only when hierarchy requires it.
- Transcript: user-scalable semantic body style with comfortable line spacing; no chat-bubble typography.
- Speaker label: semantic headline or subheadline, never color alone.
- Timestamp and technical metadata: semantic secondary/caption role, never below platform legibility guidance.
- Timer: semantic title role with monospaced/tabular digits and a stable width.
- No custom native font is approved.

#### Website

- Use a system UI stack for controls, navigation, labels, and body copy.
- Use typographic scale and whitespace—not an ornamental display face—to create authority in the first implementation.
- Transcript/evidence demonstrations use the same readable system stack, with speaker and timestamp roles matching the native semantics.
- Use no downloaded or custom brand typeface. The decided stack is `-apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif`.
- Transcript and evidence text remain sans serif. A serif treatment is rejected because native/web typographic divergence adds a variable without solving the truth-chain crux.

### Spacing

Use a 4-point base with one shared semantic scale:

| Token | Value | Use |
|---|---:|---|
| `space-1` | 4 | glyph/text optical correction and tightly related metadata |
| `space-2` | 8 | label/value and compact control gaps |
| `space-3` | 12 | compact rows and menu group internals |
| `space-4` | 16 | standard row and control grouping |
| `space-6` | 24 | section groups and document blocks |
| `space-8` | 32 | major content insets |
| `space-12` | 48 | major document section separation |

Use native control padding and form spacing before applying custom values. Do not create a second dense/comfortable scale until measured product content requires it.

### Shape and separation

- Native component shapes and radii are authoritative for controls, menus, fields, sheets, sidebars, and settings.
- Use separators, grouping, whitespace, and selection state before introducing custom containers.
- No global native “card radius” exists.
- Website buttons and inputs use a 6-pixel radius; grouped screenshots and demonstrations use an 8-pixel radius. Fully rounded shapes are reserved for actual tags or compact statuses. No other radius is approved, and cards are not the default section primitive.
- Focus uses the system focus ring. Do not replace it with a brand-colored shadow.

### Color roles

| Semantic role | Native realization | Meaning |
|---|---|---|
| background | system window/background | base window or document plane |
| surface | system control/grouped surface or material only when hierarchy requires it | raised or grouped system region |
| textPrimary | primary label | primary readable content |
| textSecondary | secondary label | timestamps, metadata, explanatory detail |
| interactive | user-selected system accent | available action or selection |
| recording | system red plus record glyph and “Recording” text | durable recording or destructive recording consequence only |
| warning | system orange/yellow plus warning glyph and text | degraded but actionable condition |
| failure | system red plus failure glyph and plain explanation | failed source, unrecoverable action, or destructive consequence |
| success | system green plus checkmark and text, used sparingly | verified completed operation, never branding |

Recording red must not be used for branding, selection, links, Ready, Starting, decorative glow, AI output, or general emphasis.

#### Website palette

The website palette is decided. These values are implementation inputs, not proof of rendered contrast. The foreground roles below were mathematically checked against their base background at ratios from 6.08:1 to 17.28:1; component-state combinations still require rendered WCAG 2.2 AA verification.

| Role | Light | Dark |
|---|---|---|
| background | `#F7F7F5` | `#11110F` |
| surface | `#FFFFFF` | `#1B1B18` |
| textPrimary | `#171714` | `#F5F5F0` |
| textSecondary | `#5C5C57` | `#B8B8B0` |
| interactive | `#0057B8` | `#6FB1FF` |
| recording | `#B42318` | `#FF6B61` |
| warning | `#8A4B00` | `#FFB455` |
| failure | `#B42318` | `#FF6B61` |
| success | `#1F6B3A` | `#63D297` |
| divider | `#D8D8D2` | `#3A3A35` |

No gradient, decorative accent, or additional brand color is approved. Interactive blue belongs only to links, focus-adjacent web treatment, and actionable controls; it is not a product-state color.

### Meter contract

- The compact live surface shows one horizontal level meter per active audio source, adjacent to the source name.
- Swift-owned platform telemetry updates the visual meter at 15 Hz. The accessibility value is rate-limited to 2 Hz and announced only on user inspection, not continuously.
- Rust receives durable capture health and bounded diagnostics, not frame-rate level samples. Ordinary UniFFI callbacks never carry the 15 Hz meter stream.
- A meter has three explicit conditions: live value, unavailable, and source failed. Unavailable and failed meters are static and labeled; neither displays synthesized motion.
- The main library and completed conversation document do not show live meters.

## 8. Motion and feedback

- Prefer system transitions and control feedback.
- Recording truth is static label + glyph + timer + sources. Do not pulse the whole window, timer, or record icon.
- Meter motion represents measured level data only. When data is unavailable or stale, the meter becomes unavailable; it does not animate decoratively.
- Source/state transitions may crossfade within the system's normal timing. Do not delay truth to complete an animation.
- The context-attention overlay uses one short luminance response when eligibility, hover, or selection changes. No looping glow.
- Custom overlay transition family: 160 ms ease-out for luminance and 200 ms ease-out for the selected-state depth change. These are the implementation values; rendered testing may falsify them through the revision gate, but implementation does not choose alternatives ad hoc.
- Reduced Motion: remove spatial lift, scaling, spring, and traveling perimeter effects; use an immediate state change or a short opacity crossfade no longer than 100 ms.
- Reduce Transparency: replace material/translucent custom backgrounds with opaque system surfaces.
- Increase Contrast: strengthen separators, text contrast, focus distinction, and overlay boundary without changing state meaning.

## 9. Context overlay rules

- Eligible scope: 1-point white perimeter at 10% opacity, no bloom, and only while the user is choosing scope.
- Hover: 1-point white perimeter at 55% opacity with an 8-point outer bloom at 20% opacity; no dimming of other screens.
- Selected: 2-point white perimeter at 70% opacity with a 12-point outer bloom at 25% opacity, plus a non-visual selected-scope description in the controlling UI.
- Active attention: one 160 ms rise to a 2-point white perimeter at 90% opacity with a 16-point outer bloom at 35% opacity, returning immediately to Selected. It is tied to a real accepted context event, never pointer motion alone.
- Paused: 1-point white perimeter at 30% opacity, no bloom, plus explicit Paused text in menu/live surfaces.
- Revoked or failed: warning/failure treatment with text in the controlling UI; never a decorative red halo.
- The overlay never implies raw-pixel retention. Retention truth is stated separately.
- Multi-display identity uses display/application/window names and position, not color alone.
- Full Keyboard Access and VoiceOver must be able to select, inspect, pause, and revoke scope without relying on the visual perimeter.
- Increase Contrast replaces the relevant perimeter with a 2-point 100%-opacity white line plus a 1-point black outer keyline and removes bloom.
- Reduce Transparency does not change the perimeter because it is not a material surface. Reduce Motion removes the Active rise and changes directly between static states.

## 10. Resizing and responsive behavior

### Native product window

These are implementation targets, not claims about the current M0 shell:

- Preferred first-open size: 1040 × 720 points.
- Product-window minimum: 760 × 520 points. This is the implementation constraint and acceptance size.
- Below 900 points wide, the inspector closes before the document narrows.
- The sidebar remains user-hideable at every supported width.
- Transcript measure targets roughly 60–85 readable characters per line; wide windows add margins or inspector space rather than stretching prose indefinitely.
- Toolbars overflow through native behavior; critical recording/failure truth never moves into overflow.
- Long localized labels wrap in documents and truncate only in bounded menus where the full accessibility label remains available.
- Large and multi-display layouts preserve window independence; recording truth is not confined to the currently focused display.
- If representative localization or accessibility content does not fit at 760 × 520, redesign the hierarchy, disclosure, wrapping, or scrolling before proposing a larger minimum. A larger minimum requires a contract revision backed by the failing exact render; individual views may not raise it themselves.

### Website

- Narrow/mobile: one reading column; demonstration, evidence excerpt, and explanation stack in source order.
- Medium: text and explanatory media may form two columns where reading order remains unambiguous.
- Wide: cap text measure; use extra space for evidence relationships or product context, not empty card grids.
- Navigation collapses into a standard disclosed menu without hiding Privacy, Download, GitHub, or Documentation.
- Interactive demonstrations lazy-load and retain a complete static explanation before hydration.
- Reduced motion presents the complete demonstration as discrete inspectable steps.

## 11. Content and state writing

- Name what is true now: “Starting…,” “Recording,” “Paused,” “Finalizing,” “Recording — degraded,” or “Recovery required.”
- Name the source: “MacBook Pro Microphone,” “FaceTime audio,” or the verified platform label.
- Name consequence and continuation: “FaceTime audio stopped. Microphone recording continues.”
- Separate capture completion from processing completion: “Recording complete. Transcript finalizing.”
- Separate provider choice from scope: “Provider selected” does not mean transcript or context is authorized.
- Avoid “magic,” “effortless,” “always listening,” “never miss anything,” and anthropomorphic AI language.
- Empty states explain what exists and what action is available; they do not advertise unimplemented features.
- Technical error codes may be disclosed in detail, but the primary message is plain language with a recovery action.

## 12. Rendered verification gate

The selected direction is not approved for product implementation completion until the exact built surfaces pass this matrix. Source review cannot close these claims.

### Required native captures and interaction checks

- light and dark appearance;
- Increase Contrast;
- Reduce Transparency;
- Reduce Motion;
- larger accessibility text and the app's transcript-size controls;
- VoiceOver labels, headings, announcements, and traversal order;
- Full Keyboard Access, visible focus, commands, and shortcuts;
- macOS 13 fallback behavior;
- current supported macOS behavior;
- 760 × 520 target and the measured true minimum;
- preferred and wide window sizes;
- single, large, and multi-display configurations;
- menu bar with crowded status items;
- Settings reached from the app menu, primary window, and menu-bar item;
- long localized lifecycle, source, permission, and recovery strings;
- every lifecycle state and every condition in section 6;
- source removal and permission revocation during capture;
- recovery after forced termination;
- inspector open/closed and sidebar visible/hidden;
- selected context scope under visual and non-visual operation.

For each run, inspect hierarchy, clipping, toolbar overflow, keyboard reachability, focus order, announcement timing, color independence, source naming, and whether Ready or Starting can ever be mistaken for Recording.

### Required website captures and checks

- narrow mobile, tablet, desktop, and wide desktop;
- light and dark if both are implemented;
- 200% and 400% zoom/reflow;
- keyboard-only navigation;
- screen-reader landmarks and reading order;
- WCAG 2.2 AA contrast and target sizing;
- reduced motion and no-script/static explanation;
- interactive demonstration with explicit “explanatory, not browser capture” language;
- long localization and content expansion;
- performance and useful SSR before hydration.

### Proof record

The implementation milestone must record:

1. exact checkout and SHA;
2. built artifact identity and OS version;
3. capture dimensions and appearance/accessibility settings;
4. state fixture or runtime precondition used;
5. observed failures and corrections;
6. remaining unknowns;
7. the narrow product gate that passed.

## 13. Strategic sequencing and stop rule

The coherent-action table in the strategy kernel is the implementation sequence. The constraint is concentration, not calendar ambition:

1. Preserve the current M0 diagnostic interface unchanged except for truthful maintenance.
2. Complete the coarse state contract and fixtures.
3. Complete both native truth surfaces from that one contract.
4. Prove real capture, degradation, permission loss, forced termination, and recovery against those surfaces.
5. Only then authorize review, transcript, intelligence, context, website presentation, distribution, or release work as separate bounded milestones.

If any tranche cannot satisfy its done-test, later tranches remain stopped. A partial implementation does not weaken the state assertion, remove the failing fixture, increase the product-window minimum, or replace proof with visual polish.

No sequence entry authorizes capture, product implementation, website initialization, release, or deployment by itself. Those actions still require the repository's explicit operator authorization and proof plane.

## 14. Decision record

### Selected

Field Instrument / Evidence Ledger: quiet native chrome, explicit capture authority, chronological evidence, document-like review, sparse status color, optional technical inspection, and a separate explanatory website composition.

### Rejected

- Dark AI command center: overstates intelligence, weakens local/document character, and creates decorative status ambiguity.
- Card-heavy meeting dashboard: makes derived concepts peers of evidence and reproduces the retired dashboard structure.
- Persistent recording console: lets a temporary live phase dominate long-term review.
- Spatial evidence graph as primary navigation: weakens chronology and non-visual reading order.
- Custom visual polish on the M0 proof: implies capabilities and approval that do not exist.

### Decided assumptions and revision gates

Uncertainty is handled by making a testable decision, not by delegating design choices to implementation. These decisions remain in force until the named evidence falsifies them.

| Decision | Locked assumption | Reopen only when |
|---|---|---|
| Product-window minimum | 760 × 520 points; preferred first-open size 1040 × 720. | An exact supported-OS render with representative localization or accessibility content cannot remain operable after hierarchy, disclosure, wrapping, and scrolling are corrected. |
| Menu-bar symbols | Use the primary/fallback mapping in section 6; labels remain authoritative. | A primary and fallback both fail the macOS 13 availability test or an accessibility inspection shows shape ambiguity with the accompanying label. |
| Typography | Native semantic San Francisco; website system sans stack; no serif or downloaded brand face. | Measured readability across transcript length, localization, and accessibility cohorts shows a material problem the semantic system stack cannot solve. |
| Website palette | Use the exact light/dark values in section 7 and follow `prefers-color-scheme`; no manual theme control in the first implementation. | Rendered WCAG testing, color-vision simulation, or platform appearance testing fails a semantic role after component treatment is corrected. |
| Meter behavior | One horizontal meter per active source; 15 Hz visual telemetry, 2 Hz inspectable accessibility value, no frame-rate UniFFI stream. | Measured capture/UI performance or user recognition shows the cadence is too costly or too ambiguous while durable capture remains unaffected. |
| Context overlay | Use the exact perimeter, bloom, timing, contrast, transparency, and motion values in section 9. | Matched captures across the supported multi-display matrix show clipping, invisibility, excessive distraction, or confusion with recording/failure state. |
| Evidence-linked interpretation | Material derived items remain subordinate, show evidence/contradiction counts, preserve focus through navigation, and use append-only human adjudication. | Exact document testing shows users cannot distinguish evidence, contradiction, model proposal, and human judgment after the hierarchy and labels are implemented as specified. |
| Intelligence authorization | Provider configuration authorizes no content; each run lists separately unchecked data categories and records a receipt. | A provider/network proof shows that this ceremony is insufficient to prevent unintended disclosure or users cannot predict what leaves the Mac. |
| Public website composition | Use the exact page hierarchy, capability-manifest consumers, static-first demo, palette/type/radii, and responsive rules in this contract and ADR 0015. | The complete rendered matrix shows inaccessible order, template residue, performance failure, or inability to predict shipped capability after implementation is corrected. |
| App icon | Use the Open evidence ledger brief; no recording red, microphone, waveform, AI sparkle, letters, or new brand color. | Matched 16–1024 px and real Finder/Dock/Spotlight tests show silhouette failure or material confusion with another installed product. |
| Custom motion | 160 ms luminance, 200 ms selected depth, ≤100 ms reduced-motion crossfade. | Reduced Motion testing or state-recognition timing shows discomfort or delayed truth. |

## 15. Acceptance statement

The research synthesis, strategy kernel, structural selection, and initial implementation decisions are complete. The direction is approved as a contract for future bounded implementation.

The current M0 proof remains approved only for its diagnostic purpose. Product-facing visual implementation, state behavior, accessibility, website responsiveness, and the full rendered matrix remain unverified and may not be claimed from this document.
