# Review a conversation

This guide describes the developer preview's controls. A successful source
build is not a signed release or proof that every microphone and Mac has been
tested. See [current verification limits](TESTING.md).

## Open the conversation

Choose a saved conversation in the sidebar. The title, date, duration, and
status help distinguish recordings with similar names. The pencil beside the
title renames that conversation.

**Import** opens local recordings. You can select several files; they are
imported one at a time. **Pause Imports** finishes the current file before
waiting. **Stop Imports** keeps the conversations already imported. A failed
file is identified without discarding the other completed imports.

New M4A imports keep a managed copy of the original file. Moving the selected
file afterward does not remove that managed copy. Older imports that retained
only decoded audio remain playable, but cannot export an original M4A that
was never retained.

**Open Package** opens a supported `.openscribe` export as a separate local
conversation. It is distinct from importing a recording. Package support is
limited; use transcript and original-audio exports when the package format
cannot preserve the conversation's media or speaker assignments.

## Find and check what was said

**Play** plays the conversation's saved audio. **Stop** stops playback.
**Audio Details** exposes the source tracks and their status when you need to
inspect an interruption or choose a source.

In the transcript, **Find in this transcript** searches the current reviewed
wording. Press Command-F to focus it. Matches are highlighted; clear the field
to restore the complete transcript. A word replaced by a correction does not
remain a hidden search match in the machine reading.

**Show** filters by a named person or by unassigned passages. Search and this
filter work together. If a search unexpectedly has no results, choose all
speakers as well as checking the search words.

Select the timestamp beside a passage to play from its position in the source
audio. **Follow playback** keeps the currently playing passage in view. Typing
a search or opening a correction stops automatic following so it does not
pull you away from your work; turn it back on when you want it.

## Correct text and name speakers

The pencil beside a passage opens **Correct Transcript Text**. Edit the text
and select **Save**. The correction is used for reading, search, and transcript
export. **Cancel** leaves the saved wording unchanged. The machine reading is
retained separately; expand **Corrected · Show machine reading** to inspect it.
**Restore Machine Reading** removes the active correction after it is saved.

Select a passage's speaker label to name that passage's speaker. These names
are human assignments, not automatic identification. **Edit a person's name**
renames an existing person. **Audio source labels**, below the reader, applies
to unassigned passages on an entire track; use passage names when one track
contains several people.

## Save a usable result

**Export Transcript** saves readable Markdown with timestamps and the current
text and speaker labels. Review the chosen destination in the save dialog.

**Other Exports** contains plain text, subtitles, transcript JSON, available
audio exports, the session manifest, and the supported portable package.
Choose **Original Audio** to copy retained imported bytes. Captured
conversations instead offer their available mix and source-track exports.
An unavailable original or package is not reconstructed from missing data.

Transcript JSON contains structured evidence references. Text and audio exports
are useful reading and listening copies; they are not a restorable backup of
every editing decision. See the [format limits](data-format/README.md).

Reopen the conversation in the sidebar to continue reviewing. Saved
corrections and person assignments belong to the conversation; exporting does
not remove them.

## Recording and interruptions

**Record** begins the selected sources. **Pause** stops captured time while
keeping the conversation open; **Resume** continues that conversation.
**Stop and Save** ends recording and preserves the captured audio.

If the microphone stops while another source continues, read the status and
use **Reconnect microphone** when ready. Ordinary Resume leaves a retired
microphone out. A different input requires **Use this microphone instead**.
The earlier audio and interruption remain part of the same conversation.

If capture cannot continue, review the preserved recording before starting
another one. A saved recording, a live source, and a source awaiting recovery
have different states; a failed source is not shown as still recording.

## When a transcript is not ready

Audio can remain available before a transcript exists. **Transcribe** requests
local processing with an installed, verified speech model. **Speech Model**
opens model setup when one is needed. Queue and failure messages explain
whether processing is waiting, incomplete, cancelled, or failed.

**Transcription → Reprocess All Tracks** requests replacement processing.
Earlier revisions and corrections remain in history. Review changes can
prevent a background replacement from becoming selected automatically. Use
this action to request new processing, not to save an ordinary correction.

Settings contains processing preferences and model management. These are
setup choices; they are not required actions for each reviewed passage.
