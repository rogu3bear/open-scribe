# Open Scribe Nuance

> **Budget:** 500 words plus compact proven entries.

Add an entry only when a likely recurring contradiction is proved by an exact command or inspection and does not belong in an anchor, architecture decision, or code comment.

### Writer generation advances on every rotation

The segmented CAF writer opens a new segment every 30 seconds and on any
host-time discontinuity, and each successor's `writerGeneration` increments. A
capture identity bound once at start (`MicrophoneCaptureIdentity(authorization:)`)
goes stale after the first rotation: a health observation or failure reported
with the start-time generation no longer matches the writer's current
authorization. Reproduced by
`RecorderPauseResumeTests.testRouteInterruptionAfterRotationDegradesMicrophoneCapture`
(route loss after one rotation must still degrade the microphone). The controller
matches observations against the identity bound at capture start and compares by
session plus a monotonic sequence, never by generation.
