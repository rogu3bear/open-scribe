//! Everything a session manifest or portable package must list (ADR 0010):
//! the saved session's identity, each sealed media file with its placement
//! and digest, the validated mix, and markers. Media is handed out only after
//! its full bytes are rehashed against the sealed digest. Read-only.

use super::import::COMPRESSED_IMPORT_MEDIA_FORMAT;
use super::transcript_input::verify_full_digest;
use super::{MEDIA_FORMAT_CAF_PCM_S16LE, SessionStore, StoreError};
use open_scribe_types::SessionId;
use std::fs::File;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionMediaEntry {
    pub track_id: String,
    pub source_id: String,
    pub source_kind: String,
    pub segment_id: String,
    pub sequence: u64,
    /// Relative to the session directory.
    pub relative_path: String,
    pub media_format: String,
    /// Playback placement on the session timeline.
    pub start_nanoseconds: i64,
    pub sample_count: u64,
    pub channels: u16,
    pub byte_length: u64,
    pub digest_sha256: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionMarker {
    pub marker_id: String,
    pub at_nanoseconds: i64,
    pub label: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionInventory {
    pub session_id: SessionId,
    pub title: String,
    pub origin: String,
    pub lifecycle: String,
    pub created_at_ms: i64,
    pub media: Vec<SessionMediaEntry>,
    pub markers: Vec<SessionMarker>,
    /// The validated derived mix, when one exists: relative path, length, digest.
    pub mixdown: Option<(String, u64, String)>,
}

/// A media file whose full bytes matched their recorded digest when opened.
pub struct VerifiedMedia {
    pub file: File,
    pub byte_length: u64,
    pub digest_sha256: String,
}

impl SessionStore {
    pub fn session_inventory(&self, session: &SessionId) -> Result<SessionInventory, StoreError> {
        let (title, origin, lifecycle, created_at_ms): (String, String, String, i64) = self
            .connection
            .query_row(
                "SELECT title, origin, lifecycle, created_at_ms FROM sessions
                 WHERE id = ?1 AND lifecycle = 'ready_for_review'",
                [&session.0],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .map_err(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => {
                    StoreError::InvalidState("session is not saved for review")
                }
                other => StoreError::Sqlite(other),
            })?;
        let placements: Vec<(String, i64)> = if origin == "capture" {
            self.playback_timeline(session)?
                .into_iter()
                .map(|segment| (segment.segment_id, segment.start_nanoseconds))
                .collect()
        } else {
            Vec::new()
        };
        let mut statement = self.connection.prepare(
            "SELECT segments.track_id, tracks.source_id, sources.kind, segments.id,
                    segments.sequence, segments.relative_path, segments.media_format,
                    segments.sample_count, segments.channels, segments.byte_length,
                    segments.digest
             FROM segments
             JOIN tracks ON tracks.id = segments.track_id AND tracks.session_id = segments.session_id
             JOIN sources ON sources.id = tracks.source_id AND sources.session_id = tracks.session_id
             WHERE segments.session_id = ?1 AND segments.lifecycle = 'sealed'
               AND segments.seal_state = 'sealed' AND segments.digest IS NOT NULL
               AND segments.media_format IN (?2, ?3)
             ORDER BY segments.track_id, segments.sequence",
        )?;
        let rows = statement
            .query_map(
                rusqlite::params![
                    &session.0,
                    MEDIA_FORMAT_CAF_PCM_S16LE,
                    COMPRESSED_IMPORT_MEDIA_FORMAT
                ],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, i64>(4)?,
                        row.get::<_, String>(5)?,
                        row.get::<_, String>(6)?,
                        row.get::<_, i64>(7)?,
                        row.get::<_, i64>(8)?,
                        row.get::<_, i64>(9)?,
                        row.get::<_, String>(10)?,
                    ))
                },
            )?
            .collect::<Result<Vec<_>, _>>()?;
        let mut media = Vec::with_capacity(rows.len());
        for row in rows {
            let (track_id, source_id, source_kind, segment_id, sequence, relative_path) =
                (row.0, row.1, row.2, row.3, row.4, row.5);
            let (media_format, sample_count, channels, byte_length, digest_sha256) =
                (row.6, row.7, row.8, row.9, row.10);
            let start_nanoseconds = if origin == "capture" {
                // Only segments on the validated playback plan are listed.
                let Some((_, start)) = placements.iter().find(|(id, _)| *id == segment_id) else {
                    continue;
                };
                *start
            } else {
                0
            };
            let channels = if media_format == COMPRESSED_IMPORT_MEDIA_FORMAT {
                self.compressed_import_channels(session, &segment_id)?
            } else {
                u16::try_from(channels)
                    .map_err(|_| StoreError::IntegrityMismatch("segment channels are invalid"))?
            };
            let invalid = || StoreError::IntegrityMismatch("segment identity is invalid");
            media.push(SessionMediaEntry {
                track_id,
                source_id,
                source_kind,
                segment_id,
                sequence: u64::try_from(sequence).map_err(|_| invalid())?,
                relative_path,
                media_format,
                start_nanoseconds,
                sample_count: u64::try_from(sample_count).map_err(|_| invalid())?,
                channels,
                byte_length: u64::try_from(byte_length).map_err(|_| invalid())?,
                digest_sha256,
            });
        }
        if media.is_empty() {
            return Err(StoreError::InvalidState("session has no sealed media"));
        }
        let markers = self
            .recorder_detail(session)?
            .events
            .into_iter()
            .filter(|event| event.kind == "marker_added")
            .map(|event| SessionMarker {
                marker_id: event.id,
                at_nanoseconds: event.session_nanoseconds,
                label: event.label,
            })
            .collect();
        // Only a capture has a timeline mix; imports keep their original.
        let mixdown = if origin != "capture" {
            None
        } else {
            self.validated_mixdown(session)?
        }
        .map(|mix| (mix.relative_path, mix.byte_length, mix.digest_sha256));
        Ok(SessionInventory {
            session_id: session.clone(),
            title,
            origin,
            lifecycle,
            created_at_ms,
            media,
            markers,
            mixdown,
        })
    }

    /// Opens one listed media file through its identity-bound lease and
    /// rehashes its full bytes against the sealed digest.
    pub fn open_verified_media(
        &self,
        session: &SessionId,
        entry: &SessionMediaEntry,
    ) -> Result<VerifiedMedia, StoreError> {
        let lease = if self.session_origin(session)? == "import" {
            self.lease_imported_playback(session)?
        } else {
            self.lease_capture_playback(
                session,
                &entry.source_id,
                &entry.track_id,
                &entry.segment_id,
                true,
            )?
        };
        verify_full_digest(lease.file(), &entry.digest_sha256)?;
        Ok(VerifiedMedia {
            file: lease.file().try_clone()?,
            byte_length: entry.byte_length,
            digest_sha256: entry.digest_sha256.clone(),
        })
    }

    /// The validated derived mix, rehashed when opened.
    pub fn open_verified_mixdown(
        &self,
        session: &SessionId,
    ) -> Result<Option<VerifiedMedia>, StoreError> {
        let Some(lease) = self.lease_validated_mixdown(session)? else {
            return Ok(None);
        };
        Ok(Some(VerifiedMedia {
            file: lease.file().try_clone()?,
            byte_length: lease.byte_length(),
            digest_sha256: lease.digest_sha256().to_owned(),
        }))
    }
}
