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

/// A Unix-epoch millisecond count as RFC 3339 UTC to the millisecond
/// (`2026-09-21T14:13:20.000Z`).
#[must_use]
pub fn rfc3339_utc(milliseconds: i64) -> String {
    format!(
        "{}.{:03}Z",
        utc_date_time(milliseconds),
        milliseconds.rem_euclid(1000)
    )
}

/// The same instant to the second (`2026-09-21T14:13:20Z`), the form
/// Foundation's default `ISO8601DateFormatter` writes.
pub(crate) fn iso8601_utc_seconds(milliseconds: i64) -> String {
    format!("{}Z", utc_date_time(milliseconds))
}

/// The instant `iso8601_utc_seconds` wrote as `text`, or `None` for any
/// other spelling: exactly `YYYY-MM-DDTHH:MM:SSZ`, a real calendar time.
pub(crate) fn parse_iso8601_utc_seconds(text: &str) -> Option<i64> {
    let bytes = text.as_bytes();
    if bytes.len() != 20
        || bytes[4] != b'-'
        || bytes[7] != b'-'
        || bytes[10] != b'T'
        || bytes[13] != b':'
        || bytes[16] != b':'
        || bytes[19] != b'Z'
    {
        return None;
    }
    let number = |range: std::ops::Range<usize>| -> Option<i64> {
        let digits = &bytes[range];
        digits.iter().all(u8::is_ascii_digit).then(|| {
            digits
                .iter()
                .fold(0_i64, |value, digit| value * 10 + i64::from(digit - b'0'))
        })
    };
    let (year, month, day) = (number(0..4)?, number(5..7)?, number(8..10)?);
    let (hour, minute, second) = (number(11..13)?, number(14..16)?, number(17..19)?);
    if !(1..=12).contains(&month) || hour > 23 || minute > 59 || second > 59 {
        return None;
    }
    // Howard Hinnant's days-from-civil algorithm.
    let shifted_year = if month <= 2 { year - 1 } else { year };
    let era = shifted_year.div_euclid(400);
    let year_of_era = shifted_year - era * 400;
    let day_of_year = (153 * ((month + 9) % 12) + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    let days = era * 146_097 + day_of_era - 719_468;
    let milliseconds = days * 86_400_000 + hour * 3_600_000 + minute * 60_000 + second * 1000;
    // A day past the month's end would normalize into another date.
    (iso8601_utc_seconds(milliseconds) == text).then_some(milliseconds)
}

fn utc_date_time(milliseconds: i64) -> String {
    let days = milliseconds.div_euclid(86_400_000);
    let of_day = milliseconds.rem_euclid(86_400_000);
    // Howard Hinnant's civil-from-days algorithm.
    let shifted = days + 719_468;
    let era = shifted.div_euclid(146_097);
    let day_of_era = shifted.rem_euclid(146_097);
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 {
        month_index + 3
    } else {
        month_index - 9
    };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}",
        of_day / 3_600_000,
        of_day / 60_000 % 60,
        of_day / 1000 % 60,
    )
}
