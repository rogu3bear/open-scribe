# Open Scribe Privacy Notice

> **Draft for MLNavigator review — not adopted and not effective.**
> No Open Scribe public release has been qualified. This draft distinguishes
> current source behavior, intended safeguards, and features awaiting proof.

## Publisher and scope

MLNavigator is the intended publisher of Open Scribe, a local-first macOS
conversation application, and its informational website at open-scribe.app.
This notice covers Open Scribe, rather than every MLNavigator product. A
third-party provider, download host, website host, or Apple service has its own
privacy practices for requests it receives.

Open Scribe's core recording, recovery, playback, and installed-model
transcription workflow is designed to work without an account. Conversation
content is not sent to MLNavigator merely by keeping it in the local library.
This design requirement does not establish that every release, optional
integration, or operating-system service has been qualified as offline.

## Information on your Mac

The repository implements local storage for the following information when you
choose the corresponding operation:

- Recorded or imported audio, track and source identity, timing, markers, and
  durable capture/recovery history.
- Conversation titles, participants or topics you enter, original recognition
  hypotheses, transcript revisions, human corrections, and search indexes.
- Optional declared screen-context scope and locally reduced context events,
  which can include recognized screen text and application/window metadata.
- Evidence references, generated results where supported, model files you
  install, preferences, and local diagnostic records.

These records support preservation, recovery, transcription, review, search,
playback, and export. Keeping an earlier hypothesis, revision, correction, or
failure is intentional: editing the displayed transcript does not erase that
underlying history. Screen-context processing is a separate, explicit choice;
it is not required to record or transcribe audio.

The current context-storage contract accepts reduced events without retaining
raw screen images. Retained snapshots and optional video are not admitted by
that contract. Calendar, Contacts, and other intended integrations must not be
treated as collected data or granted permissions merely because the product
design mentions them. A future implementation requires an updated disclosure
and its own permission and qualification evidence.

## Storage, retention, and deletion

The normal application library and managed models reside under your user's
Application Support/Open Scribe directory. macOS sandboxing can change the
physical location. Imported originals and files you export may remain at the
locations you selected outside that library. Open Scribe does not promise
automatic expiry of stored conversations or erasure of every copy.

The implemented conversation-deletion path first asks macOS to move the
managed session directory to Trash, then removes the session's database rows.
If that move fails, the conversation is retained. Audio in Trash remains until
Trash is emptied. This is recoverable deletion, not secure erasure, and the
actual system-Trash workflow still requires release qualification.

Deleting a conversation does not delete an imported original, an earlier
export, a recipient's copy, a model, a provider's records, Time Machine backups,
or other backup/synchronization copies. Those copies are controlled separately.
A portable export contains sensitive evidence; review its contents and format
limits before sharing. Portable-format support does not promise a complete
round trip for all media, context, or historical processing states.

## Permissions and choices

Recording is deliberate. Microphone and screen/system-audio access use Apple's
permission and source-selection mechanisms. The native interface may read
permission status without starting a stream. Optional context has its own
declared scope, pause, and revocation controls. Denying or revoking permission
can prevent the affected operation; an in-app state indicator is not a
substitute for the operating system's controls.

Import/export uses files you choose. macOS permissions, file access, privacy
settings, disk encryption, backups, and other software on the Mac affect the
protection of local content. Local-first storage is not a promise of protection
from someone who already has access to your account or exported files.

## Optional network requests

The local workflow does not require a remote AI provider. Provider selection
alone does not authorize sharing content. The product contract requires a
separate, explicit authorization for each content category and a record of
what was sent. Provider execution and its release qualification remain open;
this draft does not claim that provider-scope safeguards have passed.

Before using a remote provider, review the actual endpoint, authorized content,
provider terms, retention/training practices, and cost controls. A provider may
retain a request after local deletion. Transcript and screen text can contain
other people's personal information or confidential material.

Current model management supports choosing a local model file; it performs
integrity checks and does not implicitly download weights. In-app model
downloads and signed update delivery remain release prerequisites. When
implemented, a deliberate download or update check will reveal ordinary
request metadata to the destination. Visiting GitHub, a model-hosting site, or
Apple trust/notarization services is governed by that service's practices.

## Diagnostics, support, and the website

There is no required product telemetry or account in the product contract.
Content-free operational diagnostics are required; complete logging and crash
report qualification remains open. Review any diagnostic material before
sharing it. Do not include recordings, transcripts, screen text, credentials,
or private paths in a public issue.

If you contact MLNavigator, it receives the information you choose to send and
uses it to respond. Do not send conversation content or secrets without an
agreed private path. No support mailbox retention period or automatic deletion
schedule has been established for Open Scribe.

The checked website has informational, legal, and repository-link routes; it
does not implement a newsletter, contact form, advertising scripts, or a
third-party analytics client. Its Cloudflare deployment is a separate proof
plane. A host can receive IP address, user agent, request path, and time when a
page is requested. Host logging, retention, and any deployed configuration
must be verified before adoption; the MLNavigator site's own retention or
analytics claims are not automatically Open Scribe's claims.

## Requests and changes

You control the local library, macOS permissions, exports, and backups on your
Mac. MLNavigator cannot retrieve or erase a local library it has never received.
Requests concerning information you sent to MLNavigator should identify the
relevant contact or submission without including unnecessary sensitive content.
Applicable rights depend on the processing and law that apply to that request.

Proposed privacy contact: privacy@mlnavigator.com, carried over from
MLNavigator's existing site policy. Mailbox operation and the responsible legal
entity must be verified before adoption. Security reports follow SECURITY.md;
this proposed privacy contact is not the GitHub vulnerability-reporting channel.

Material changes must be disclosed in this canonical notice before the
affected release or data practice is offered. No effective date, legal adoption,
or public availability is created by preparing this draft.
