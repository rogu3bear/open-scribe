//! Conversation titles.
//!
//! The stored title stays the user-visible name of record. A capture starts
//! with a placeholder (`Conversation <timestamp>`) until a person renames it.
//! A suggested title is derived interpretation (founding PRD 2.3): it is kept
//! beside the stored title with the engine and transcript basis that produced
//! it, it is shown only while the stored title is still a placeholder, and it
//! is refused once a person has named the conversation.

use super::{SessionStore, StoreError, wall_time_milliseconds};
use open_scribe_types::SessionId;
use rusqlite::{OptionalExtension, Transaction, params};

pub(super) const CONVERSATION_TITLE_MIGRATION_VERSION: i64 = 21;

/// Suggestions are short names, not summaries.
pub const MAX_SUGGESTED_TITLE_CHARS: usize = 80;

/// Where the title a reader sees comes from.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum TitleSource {
    /// The capture placeholder; the app may present it as a date.
    #[default]
    Placeholder,
    /// Derived from the transcript; not chosen by a person.
    Suggested,
    /// Chosen by a person, or any title that is not a capture placeholder.
    Person,
}

impl TitleSource {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Placeholder => "placeholder",
            Self::Suggested => "suggested",
            Self::Person => "person",
        }
    }
}

/// The resolved title of one conversation and its parts.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversationTitle {
    pub stored_title: String,
    pub display_title: String,
    pub source: TitleSource,
    pub suggested_title: Option<String>,
    pub suggestion_engine: Option<String>,
    pub suggestion_basis: Option<String>,
}

pub(super) fn apply_schema(transaction: &Transaction<'_>) -> Result<(), StoreError> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS conversation_titles (
            session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
            named_by_person INTEGER NOT NULL DEFAULT 0 CHECK (named_by_person IN (0, 1)),
            suggested_title TEXT,
            suggestion_engine TEXT,
            suggestion_basis TEXT
                CHECK (suggestion_basis IS NULL OR suggestion_basis IN ('draft', 'final')),
            suggested_at_ms INTEGER,
            CHECK ((suggested_title IS NULL) = (suggestion_engine IS NULL)),
            CHECK ((suggested_title IS NULL) = (suggestion_basis IS NULL))
        );",
    )?;
    transaction.execute(
        "INSERT OR IGNORE INTO schema_migrations (version, applied_at_ms) VALUES (?1, ?2)",
        params![
            CONVERSATION_TITLE_MIGRATION_VERSION,
            wall_time_milliseconds()
        ],
    )?;
    Ok(())
}

/// The capture default written when recording starts.
#[must_use]
pub fn is_placeholder_title(title: &str, origin: &str) -> bool {
    let Some(stamp) = title.strip_prefix("Conversation ") else {
        return false;
    };
    let bytes = stamp.as_bytes();
    origin == "capture"
        && bytes.len() >= 11
        && bytes[..4].iter().all(u8::is_ascii_digit)
        && bytes[4] == b'-'
        && bytes[5..7].iter().all(u8::is_ascii_digit)
        && bytes[7] == b'-'
        && bytes[8..10].iter().all(u8::is_ascii_digit)
        && bytes[10] == b'T'
}

/// A person's title always wins; a suggestion replaces only a placeholder.
#[must_use]
pub fn resolve_title(
    stored_title: &str,
    origin: &str,
    named_by_person: bool,
    suggested_title: Option<&str>,
) -> (String, TitleSource) {
    if named_by_person || !is_placeholder_title(stored_title, origin) {
        return (stored_title.to_owned(), TitleSource::Person);
    }
    match suggested_title {
        Some(suggested) => (suggested.to_owned(), TitleSource::Suggested),
        None => (stored_title.to_owned(), TitleSource::Placeholder),
    }
}

fn validated_suggestion(title: &str) -> Result<String, StoreError> {
    let collapsed = title.split_whitespace().collect::<Vec<_>>().join(" ");
    let trimmed = collapsed.trim_matches(|c: char| c == '"' || c == '\'' || c == '.');
    if trimmed.is_empty() {
        return Err(StoreError::InvalidRequest("suggested title is empty"));
    }
    if trimmed.chars().count() > MAX_SUGGESTED_TITLE_CHARS {
        return Err(StoreError::InvalidRequest("suggested title is too long"));
    }
    if trimmed.chars().any(char::is_control) {
        return Err(StoreError::InvalidRequest(
            "suggested title contains control characters",
        ));
    }
    Ok(trimmed.to_owned())
}

/// Marks a conversation as named by a person inside the rename transaction.
pub(super) fn record_person_named(
    transaction: &Transaction<'_>,
    session_id: &str,
) -> Result<(), StoreError> {
    transaction.execute(
        "INSERT INTO conversation_titles (session_id, named_by_person) VALUES (?1, 1)
         ON CONFLICT(session_id) DO UPDATE SET named_by_person = 1",
        [session_id],
    )?;
    Ok(())
}

impl SessionStore {
    /// The resolved title, including any stored suggestion and its basis.
    pub fn conversation_title(&self, session: &SessionId) -> Result<ConversationTitle, StoreError> {
        let (stored_title, origin): (String, String) = self.connection.query_row(
            "SELECT title, origin FROM sessions WHERE id = ?1 AND lifecycle <> 'deleted'",
            [&session.0],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        let row: Option<(bool, Option<String>, Option<String>, Option<String>)> = self
            .connection
            .query_row(
                "SELECT named_by_person, suggested_title, suggestion_engine, suggestion_basis
                 FROM conversation_titles WHERE session_id = ?1",
                [&session.0],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .optional()?;
        let (named, suggested_title, suggestion_engine, suggestion_basis) =
            row.unwrap_or((false, None, None, None));
        let (display_title, source) =
            resolve_title(&stored_title, &origin, named, suggested_title.as_deref());
        Ok(ConversationTitle {
            stored_title,
            display_title,
            source,
            suggested_title,
            suggestion_engine,
            suggestion_basis,
        })
    }

    /// Stores a transcript-derived title. Returns false, storing nothing, when
    /// a person has already named the conversation. A Final-based suggestion
    /// is never replaced by a Draft-based one.
    pub fn suggest_conversation_title(
        &mut self,
        session: &SessionId,
        title: &str,
        engine: &str,
        basis: &str,
    ) -> Result<bool, StoreError> {
        let title = validated_suggestion(title)?;
        if engine.trim().is_empty() {
            return Err(StoreError::InvalidRequest("suggestion engine is empty"));
        }
        if basis != "draft" && basis != "final" {
            return Err(StoreError::InvalidRequest(
                "suggestion basis must be draft or final",
            ));
        }
        let _writer = self.write_guard()?;
        let transaction = self.connection.transaction()?;
        super::session_deletion::require_available(&transaction, &session.0)?;
        let (stored_title, origin): (String, String) = transaction.query_row(
            "SELECT title, origin FROM sessions WHERE id = ?1 AND lifecycle <> 'deleted'",
            [&session.0],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        let existing: Option<(bool, Option<String>)> = transaction
            .query_row(
                "SELECT named_by_person, suggestion_basis FROM conversation_titles
                 WHERE session_id = ?1",
                [&session.0],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        let named = existing.as_ref().is_some_and(|(named, _)| *named);
        let has_final = existing
            .as_ref()
            .and_then(|(_, basis)| basis.as_deref())
            .is_some_and(|basis| basis == "final");
        if named || !is_placeholder_title(&stored_title, &origin) || (has_final && basis == "draft")
        {
            return Ok(false);
        }
        transaction.execute(
            "INSERT INTO conversation_titles
                (session_id, named_by_person, suggested_title, suggestion_engine,
                 suggestion_basis, suggested_at_ms)
             VALUES (?1, 0, ?2, ?3, ?4, ?5)
             ON CONFLICT(session_id) DO UPDATE SET
                suggested_title = excluded.suggested_title,
                suggestion_engine = excluded.suggestion_engine,
                suggestion_basis = excluded.suggestion_basis,
                suggested_at_ms = excluded.suggested_at_ms",
            params![
                session.0,
                title,
                engine.trim(),
                basis,
                wall_time_milliseconds()
            ],
        )?;
        transaction.commit()?;
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_capture_default_is_a_placeholder() {
        assert!(is_placeholder_title(
            "Conversation 2026-11-12T19:30:05Z",
            "capture"
        ));
        assert!(!is_placeholder_title(
            "Conversation 2026-11-12T19:30:05Z",
            "import"
        ));
        assert!(!is_placeholder_title("Conversation with Dana", "capture"));
        assert!(!is_placeholder_title("Conversation 2026", "capture"));
        assert!(!is_placeholder_title("Design review", "capture"));
    }

    #[test]
    fn a_person_title_outranks_a_suggestion() {
        let placeholder = "Conversation 2026-11-12T19:30:05Z";
        assert_eq!(
            resolve_title(placeholder, "capture", false, Some("Mobile beta date")),
            ("Mobile beta date".to_owned(), TitleSource::Suggested)
        );
        assert_eq!(
            resolve_title(placeholder, "capture", false, None),
            (placeholder.to_owned(), TitleSource::Placeholder)
        );
        assert_eq!(
            resolve_title(placeholder, "capture", true, Some("Mobile beta date")),
            (placeholder.to_owned(), TitleSource::Person)
        );
        assert_eq!(
            resolve_title("Board prep", "capture", false, Some("Mobile beta date")),
            ("Board prep".to_owned(), TitleSource::Person)
        );
    }

    #[test]
    fn suggestions_are_trimmed_and_bounded() {
        assert_eq!(
            validated_suggestion("  \"Mobile   beta launch.\" ").unwrap(),
            "Mobile beta launch"
        );
        assert!(validated_suggestion("   ").is_err());
        assert!(validated_suggestion(&"a".repeat(81)).is_err());
    }
}
