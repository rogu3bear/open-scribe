//! Metadata time is independent of the legacy lifecycle timestamp. Library
//! order is creation order; editing a title cannot move or lengthen media.
use super::*;
pub(super) fn apply_schema(tx: &Transaction<'_>) -> Result<(), StoreError> {
    tx.execute_batch(
        "CREATE TABLE IF NOT EXISTS session_metadata_times (
        session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
        modified_at_ms INTEGER NOT NULL);
        INSERT OR IGNORE INTO session_metadata_times
            SELECT id, updated_at_ms FROM sessions WHERE lifecycle <> 'deleted';
        CREATE TRIGGER IF NOT EXISTS session_metadata_initial AFTER INSERT ON sessions BEGIN
            INSERT INTO session_metadata_times VALUES(NEW.id, NEW.created_at_ms);
        END;",
    )?;
    tx.execute(
        "INSERT OR IGNORE INTO schema_migrations VALUES(12, ?1)",
        [wall_time_milliseconds()],
    )?;
    Ok(())
}
impl SessionStore {
    pub fn metadata_modified_at(&self, session: &SessionId) -> Result<i64, StoreError> {
        Ok(self.connection.query_row(
            "SELECT modified_at_ms FROM session_metadata_times WHERE session_id = ?1",
            [&session.0],
            |r| r.get(0),
        )?)
    }
}

pub(super) fn record_change(
    tx: &Transaction<'_>,
    session: &str,
    observed_ms: i64,
) -> Result<(), StoreError> {
    // A monotonic edit stamp with a wall-time anchor; never capture calibration.
    if tx.execute("UPDATE session_metadata_times SET modified_at_ms = MAX(modified_at_ms + 1, ?2) WHERE session_id = ?1",
        params![session, observed_ms])? != 1 {
        return Err(StoreError::IntegrityMismatch("metadata clock missing"));
    }
    Ok(())
}
