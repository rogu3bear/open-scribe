//! Projection of journaled events into `session_events`.

use super::*;

#[allow(clippy::too_many_arguments)]
pub(crate) fn insert_event(
    connection: &Connection,
    session_id: &str,
    sequence: u64,
    event_kind: &str,
    wall_time_ms: i64,
    payload: &Value,
    prior_digest: Option<&str>,
    digest: &str,
) -> Result<(), StoreError> {
    insert_event_with_id(
        connection,
        &Uuid::now_v7().to_string(),
        session_id,
        sequence,
        event_kind,
        wall_time_ms,
        payload,
        prior_digest,
        digest,
    )
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn insert_event_with_id(
    connection: &Connection,
    event_id: &str,
    session_id: &str,
    sequence: u64,
    event_kind: &str,
    wall_time_ms: i64,
    payload: &Value,
    prior_digest: Option<&str>,
    digest: &str,
) -> Result<(), StoreError> {
    connection.execute(
        "INSERT INTO session_events (
            id, schema_version, session_id, sequence, event_kind,
            session_nanoseconds, wall_time_ms, payload_json, prior_digest, digest
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?10, ?6, ?7, ?8, ?9)",
        params![
            event_id,
            SCHEMA_VERSION,
            session_id,
            sequence as i64,
            event_kind,
            wall_time_ms,
            serde_json::to_string(payload)?,
            prior_digest,
            digest,
            payload
                .get("session_nanoseconds")
                .or_else(|| payload.get("first_sample_session_nanoseconds"))
                .and_then(Value::as_i64)
                .unwrap_or(0)
        ],
    )?;
    Ok(())
}

pub(crate) fn next_database_event(
    connection: &Connection,
    session_id: &str,
) -> Result<(u64, Option<String>), StoreError> {
    let result: (i64, Option<String>) = connection.query_row(
        "SELECT COALESCE(MAX(sequence), 0) + 1,
                (SELECT digest FROM session_events
                 WHERE session_id = ?1 ORDER BY sequence DESC LIMIT 1)
         FROM session_events WHERE session_id = ?1",
        [session_id],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    Ok((result.0 as u64, result.1))
}

pub(crate) fn event_digest(
    session_id: &str,
    sequence: u64,
    event_kind: &str,
    payload: &Value,
    prior_digest: Option<&str>,
) -> Result<String, StoreError> {
    digest_json(&json!({
        "session_id": session_id,
        "sequence": sequence,
        "event_kind": event_kind,
        "payload": payload,
        "prior_digest": prior_digest,
    }))
}

/// Inserts the `session_events` row for one journaled event, chained after
/// the session's last row. The row keeps the record's event id, wall time
/// and payload: that pairing is how a reader matches the database to the
/// journal (script/verify_m1_injected.rb).
pub(crate) fn insert_journaled_event(
    connection: &Connection,
    record: &JournalRecord,
    event_kind: &str,
) -> Result<(), StoreError> {
    let session_id = record.body.session_id.as_str();
    let (sequence, prior_digest) = next_database_event(connection, session_id)?;
    let digest = event_digest(
        session_id,
        sequence,
        event_kind,
        &record.body.payload,
        prior_digest.as_deref(),
    )?;
    insert_event_with_id(
        connection,
        &record.body.event_id,
        session_id,
        sequence,
        event_kind,
        record.body.wall_time_milliseconds,
        &record.body.payload,
        prior_digest.as_deref(),
        &digest,
    )
}
