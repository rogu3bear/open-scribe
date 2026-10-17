# Support for the developer preview

Open Scribe provides public source and unsigned contributor builds. There is no
supported installer or app release. [Testing](docs/TESTING.md) records exact,
dated qualification; a build does not prove live permissions, two-hour capture,
model accuracy, signed distribution, or recovery of a particular private library.

## Reporting a problem

For suspected security or privacy issues, use [SECURITY.md](SECURITY.md). Keep
conversation, screen, transcript, OCR, participant, account, credential and
private-path data out of public issues. No response-time guarantee or staffed
support service is established.

For an ordinary development bug, report the source commit, candidate/build
identity when known, macOS version, Apple Silicon model, operation attempted,
and visible state/error. Use synthetic or nonprivate steps. Separate expected
and observed behavior. The public form does not require a recording, database,
package, model or log upload.

Settings → Diagnostics → Export Diagnostics creates a local text file for
inspection; it does not send it. It omits titles, transcript text and paths,
but can contain session/model identifiers, permission state, OS/build information
and operation notes. Read the whole file and redact sensitive details before
choosing a recipient. Export is not repair or proof that an operation succeeded.

## Storage and recovery

The ordinary development library resolves beneath the current account's
Application Support directory as `Open Scribe`. A sandboxed build can resolve
it inside its app container. Proof/test launches use separate explicit roots.
Never use the ordinary library as a verification fixture.

Source audio, session files, `Library.sqlite3`, SQLite companions, journals,
models and preferences have separate roles. Do not replace the database, edit
a journal, remove retained chunks or clear app data because a transcript fails.
Recovered audio can remain available with a separate transcript-maintenance
warning. Preserve the exact error and original inputs. For a private backup,
quit the app and copy the complete managed library; a lone database copy can
omit its journal, media or WAL. This preserves evidence but cannot establish
that an unknown library is healthy.

Use the app's confirmed **Move to Trash** action for a saved conversation. It
does not securely erase media, empty Trash, delete original imports, or remove
backup/export copies. Keep needed copies before deletion. Do not manually move
internal folders back into the library as a restore.

Low disk, failed media integrity, missing access or an incomplete recovery
barrier can prevent work. Keep the state/error; do not bypass the hold or
repeatedly start operations. Transcript Retry resumes eligible incomplete work.
Deliberate reprocessing is separate and cannot repair unverifiable source audio.

## Models and offline use

Recording needs no speech model. The implemented speech engine runs locally;
Open Scribe never downloads weights. Settings → Speech Models shows the pinned
origin, size, SHA-256 and local readiness. A browser download is a separate user
choice. **Install from File…** verifies the selected file and test-runs the
engine; an invalid model offers **Repair from File…**. Do not rename arbitrary
weights to satisfy the catalog or bypass verification. Both catalog models
remain Pending release review and unbundled. See [model authority](docs/models/README.md).

## Compatibility and exports

- The target is Apple Silicon with a macOS 13 deployment floor, which is not
  qualification on every supported Mac/version. Contributors need pinned tools.
- Import accepts bounded PCM CAF and supported M4A AAC/Apple Lossless layouts.
  Four-hour and source/decoded size limits apply. Other extensions, layouts and
  rates can be refused. See [the exact import limits](apps/macos/README.md#local-audio-import).
- Import/playback does not establish portable round-trip support. A package
  containing compressed M4A cannot currently be reopened. Context events are
  omitted, and failed transcription restores as pending. A package is not a
  complete backup of all history; see [format authority](docs/data-format/README.md).
- Corrections change selected review text while original hypotheses and immutable
  history remain. Export contains private content and goes to a user-selected
  destination. Review output and evidence references before sharing.

## Installation, removal and documents

Use [isolated contributor qualification](CONTRIBUTING.md). The local
`install_app.sh` and `uninstall_app.sh` tools change installed bytes, Launch
Services registration and development privacy decisions. They are not routine
troubleshooting/source checks; invoke them only when intending those effects.
Uninstall preserves the ordinary library; Trash, backups, exports and original
imports remain separate.

Settings → **Read Policies and Licenses…** reads bundled copies of the canonical
privacy, terms, security, MIT license and third-party notices offline. Privacy
and terms remain unadopted drafts; notices and redistribution review remain
incomplete. Reading the documents does not change those gates.
