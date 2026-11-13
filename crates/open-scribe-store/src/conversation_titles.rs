//! Conversation titles.
//!
//! The stored title stays the user-visible name of record. A capture starts
//! with a placeholder (`Conversation <timestamp>`) until a person renames it.
//! A suggested title is derived interpretation (founding PRD 2.3): it is kept
//! beside the stored title with the engine and transcript basis that produced
//! it, it is shown only while the stored title is still a placeholder, and it
//! is refused once a person has named the conversation.

use super::{
    MAX_TITLE_BYTES, SessionLifecycle, SessionOrigin, SessionStore, StoreError, SuggestionBasis,
    wall_time_milliseconds,
};
use open_scribe_types::SessionId;
use rusqlite::{Transaction, params};

/// Suggestions are short names, not summaries.
const MAX_SUGGESTED_TITLE_CHARS: usize = 80;

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
    /// The capture time a placeholder names, while the placeholder is what a
    /// reader sees. The app formats it in the reader's locale.
    pub placeholder_at_ms: Option<i64>,
    pub suggested_title: Option<String>,
    pub suggestion_engine: Option<String>,
    pub suggestion_basis: Option<SuggestionBasis>,
    /// Whether `suggest_conversation_title` would store a suggestion on each
    /// basis now; see [`ConversationTitle::accepts_suggestion`].
    pub accepts_draft_suggestion: bool,
    pub accepts_final_suggestion: bool,
}

impl ConversationTitle {
    /// The one acceptance rule. A person's title is never replaced and a
    /// placeholder always is. A Final-based suggestion stays put, so later
    /// corrections and launches do not rerun the model or change the title.
    /// A Draft-based one is replaced by a Final-based one, or by a newer
    /// Draft-based one while the conversation is still being recorded; saved
    /// Draft text is the same text the live suggestion already read.
    #[must_use]
    pub const fn accepts_suggestion(&self, basis: SuggestionBasis) -> bool {
        match basis {
            SuggestionBasis::Draft => self.accepts_draft_suggestion,
            SuggestionBasis::Final => self.accepts_final_suggestion,
        }
    }
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
    Ok(())
}

/// A capture is named `Conversation <UTC time to the second>` until a person
/// renames it. Titles the macOS app wrote before Rust named sessions have the
/// same form, so they stay placeholders.
const PLACEHOLDER_TITLE_PREFIX: &str = "Conversation ";

/// The placeholder title for a capture prepared at `wall_time_ms`.
#[must_use]
pub(super) fn placeholder_title(wall_time_ms: i64) -> String {
    format!(
        "{PLACEHOLDER_TITLE_PREFIX}{}",
        super::session_times::iso8601_utc_seconds(wall_time_ms)
    )
}

/// The capture time a placeholder title names. Only a capture's title can be
/// a placeholder; an import keeps the name it was given.
fn placeholder_time_ms(title: &str, origin: &str) -> Option<i64> {
    if origin != SessionOrigin::Capture.as_str() {
        return None;
    }
    super::session_times::parse_iso8601_utc_seconds(title.strip_prefix(PLACEHOLDER_TITLE_PREFIX)?)
}

/// The one title rule for a person's, an import's, or a suggested title:
/// trimmed, not empty, at most `MAX_TITLE_BYTES`, and free of control
/// characters.
pub(super) fn checked_title(title: &str) -> Result<&str, StoreError> {
    let title = title.trim();
    if title.is_empty() {
        return Err(StoreError::InvalidRequest("title is empty"));
    }
    if title.len() > MAX_TITLE_BYTES {
        return Err(StoreError::InvalidRequest("title exceeds byte limit"));
    }
    if title.chars().any(char::is_control) {
        return Err(StoreError::InvalidRequest(
            "title contains control characters",
        ));
    }
    Ok(title)
}

/// The title an import stores: its file or package name with any control
/// characters turned into spaces, so a name a person never typed cannot
/// refuse the import. A name with nothing printable keeps a plain fallback.
#[must_use]
pub fn imported_title(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|character| {
            if character.is_control() {
                ' '
            } else {
                character
            }
        })
        .collect();
    match cleaned.trim() {
        "" => "Imported conversation".to_owned(),
        trimmed => trimmed.to_owned(),
    }
}

/// Model output with its whitespace collapsed and surrounding quotes and
/// periods removed, within the suggestion length.
fn validated_suggestion(title: &str) -> Result<String, StoreError> {
    let collapsed = title.split_whitespace().collect::<Vec<_>>().join(" ");
    let trimmed = collapsed.trim_matches(|c: char| c == '"' || c == '\'' || c == '.');
    if trimmed.chars().count() > MAX_SUGGESTED_TITLE_CHARS {
        return Err(StoreError::InvalidRequest("suggested title is too long"));
    }
    Ok(checked_title(trimmed)?.to_owned())
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

/// The columns every title read selects from `sessions` joined with
/// [`TITLE_JOIN`], in the order [`TitleRow::read`] reads them.
pub(super) const TITLE_COLUMNS: &str = "sessions.title, sessions.origin, sessions.lifecycle,
    COALESCE(titles.named_by_person, 0), titles.suggested_title, titles.suggestion_engine,
    titles.suggestion_basis";
pub(super) const TITLE_JOIN: &str =
    "LEFT JOIN conversation_titles AS titles ON titles.session_id = sessions.id";

/// One session's stored title facts, as read; [`TitleRow::resolve`] turns
/// them into what a reader sees.
pub(super) struct TitleRow {
    stored_title: String,
    origin: String,
    lifecycle: String,
    named_by_person: bool,
    suggested_title: Option<String>,
    suggestion_engine: Option<String>,
    suggestion_basis: Option<String>,
}

impl TitleRow {
    /// Reads [`TITLE_COLUMNS`] starting at column `first`.
    pub(super) fn read(row: &rusqlite::Row<'_>, first: usize) -> rusqlite::Result<Self> {
        Ok(Self {
            stored_title: row.get(first)?,
            origin: row.get(first + 1)?,
            lifecycle: row.get(first + 2)?,
            named_by_person: row.get(first + 3)?,
            suggested_title: row.get(first + 4)?,
            suggestion_engine: row.get(first + 5)?,
            suggestion_basis: row.get(first + 6)?,
        })
    }

    /// A person's title always wins; a suggestion replaces only a placeholder.
    pub(super) fn resolve(self) -> Result<ConversationTitle, StoreError> {
        let lifecycle = SessionLifecycle::parse(&self.lifecycle)?;
        let suggestion_basis = self
            .suggestion_basis
            .as_deref()
            .map(SuggestionBasis::parse)
            .transpose()?;
        let placeholder_at_ms =
            placeholder_time_ms(&self.stored_title, &self.origin).filter(|_| !self.named_by_person);
        let (display_title, source) = match (placeholder_at_ms, &self.suggested_title) {
            (None, _) => (self.stored_title.clone(), TitleSource::Person),
            (Some(_), Some(suggested)) => (suggested.clone(), TitleSource::Suggested),
            (Some(_), None) => (self.stored_title.clone(), TitleSource::Placeholder),
        };
        let accepts = |basis: SuggestionBasis| match source {
            TitleSource::Person => false,
            TitleSource::Placeholder => true,
            TitleSource::Suggested => {
                suggestion_basis != Some(SuggestionBasis::Final)
                    && (basis == SuggestionBasis::Final || lifecycle.is_open_capture())
            }
        };
        Ok(ConversationTitle {
            display_title,
            source,
            placeholder_at_ms: placeholder_at_ms.filter(|_| source == TitleSource::Placeholder),
            accepts_draft_suggestion: accepts(SuggestionBasis::Draft),
            accepts_final_suggestion: accepts(SuggestionBasis::Final),
            stored_title: self.stored_title,
            suggested_title: self.suggested_title,
            suggestion_engine: self.suggestion_engine,
            suggestion_basis,
        })
    }
}

/// The resolved title of one session that is not deleted.
pub(super) fn conversation_title(
    connection: &rusqlite::Connection,
    session_id: &str,
) -> Result<ConversationTitle, StoreError> {
    connection
        .query_row(
            &format!(
                "SELECT {TITLE_COLUMNS} FROM sessions {TITLE_JOIN}
                 WHERE sessions.id = ?1 AND sessions.lifecycle <> 'deleted'"
            ),
            [session_id],
            |row| TitleRow::read(row, 0),
        )?
        .resolve()
}

impl SessionStore {
    /// The resolved title, including any stored suggestion and its basis.
    pub fn conversation_title(&self, session: &SessionId) -> Result<ConversationTitle, StoreError> {
        conversation_title(&self.connection, &session.0)
    }

    /// Stores a transcript-derived title. Returns false, storing nothing, when
    /// [`ConversationTitle::accepts_suggestion`] refuses it.
    pub fn suggest_conversation_title(
        &mut self,
        session: &SessionId,
        title: &str,
        engine: &str,
        basis: SuggestionBasis,
    ) -> Result<bool, StoreError> {
        let title = validated_suggestion(title)?;
        if engine.trim().is_empty() {
            return Err(StoreError::InvalidRequest("suggestion engine is empty"));
        }
        let _writer = self.write_guard()?;
        let transaction = self.connection.transaction()?;
        super::session_deletion::require_available(&transaction, &session.0)?;
        if !conversation_title(&transaction, &session.0)?.accepts_suggestion(basis) {
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

/// Whether a stored session title would read as the capture placeholder.
#[cfg(test)]
pub(super) fn is_placeholder_title(title: &str, origin: &str) -> bool {
    placeholder_time_ms(title, origin).is_some()
}

#[cfg(test)]
mod tests {
    use super::super::PrepareSessionRequest;
    use super::*;

    fn resolve(
        stored_title: &str,
        origin: &str,
        lifecycle: SessionLifecycle,
        named_by_person: bool,
        suggestion: Option<(&str, SuggestionBasis)>,
    ) -> ConversationTitle {
        TitleRow {
            stored_title: stored_title.to_owned(),
            origin: origin.to_owned(),
            lifecycle: lifecycle.as_str().to_owned(),
            named_by_person,
            suggested_title: suggestion.map(|(title, _)| title.to_owned()),
            suggestion_engine: suggestion.map(|_| "test-engine".to_owned()),
            suggestion_basis: suggestion.map(|(_, basis)| basis.as_str().to_owned()),
        }
        .resolve()
        .unwrap()
    }

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
        assert!(!is_placeholder_title(
            "Conversation 2026-11-12T19:30:05Z notes",
            "capture"
        ));
        assert!(!is_placeholder_title(
            "Conversation 2026-02-30T19:30:05Z",
            "capture"
        ));
    }

    #[test]
    fn rust_names_captures_in_the_form_the_app_wrote() {
        // ISO8601DateFormatter's default: UTC, whole seconds, `Z`.
        assert_eq!(
            placeholder_title(1_794_561_342_999),
            "Conversation 2026-11-13T09:15:42Z"
        );
        assert_eq!(placeholder_title(0), "Conversation 1970-01-01T00:00:00Z");
        assert_eq!(
            placeholder_time_ms("Conversation 2026-11-13T09:15:42Z", "capture"),
            Some(1_794_561_342_000)
        );
        assert!(is_placeholder_title(
            &placeholder_title(wall_time_milliseconds()),
            "capture"
        ));
        assert_eq!(
            PrepareSessionRequest::capture(Some("Board prep".to_owned())).title,
            "Board prep"
        );
        assert!(is_placeholder_title(
            &PrepareSessionRequest::capture(None).title,
            "capture"
        ));
    }

    #[test]
    fn a_person_title_outranks_a_suggestion() {
        let placeholder = "Conversation 2026-11-12T19:30:05Z";
        let saved = SessionLifecycle::ReadyForReview;
        let suggested = resolve(
            placeholder,
            "capture",
            saved,
            false,
            Some(("Mobile beta date", SuggestionBasis::Draft)),
        );
        assert_eq!(suggested.display_title, "Mobile beta date");
        assert_eq!(suggested.source, TitleSource::Suggested);
        assert_eq!(suggested.placeholder_at_ms, None);
        let bare = resolve(placeholder, "capture", saved, false, None);
        assert_eq!(
            (bare.display_title.as_str(), bare.source),
            (placeholder, TitleSource::Placeholder)
        );
        assert_eq!(bare.placeholder_at_ms, Some(1_794_511_805_000));
        let named = resolve(placeholder, "capture", saved, true, None);
        assert_eq!(
            (
                named.display_title.as_str(),
                named.source,
                named.placeholder_at_ms
            ),
            (placeholder, TitleSource::Person, None)
        );
        let person = resolve(
            "Board prep",
            "capture",
            saved,
            false,
            Some(("Mobile beta date", SuggestionBasis::Final)),
        );
        assert_eq!(
            (person.display_title.as_str(), person.source),
            ("Board prep", TitleSource::Person)
        );
    }

    #[test]
    fn one_rule_decides_which_suggestions_are_stored() {
        use SessionLifecycle::{ReadyForReview, Recording};
        use SuggestionBasis::{Draft, Final};
        let placeholder = "Conversation 2026-11-12T19:30:05Z";
        let accepts = |lifecycle, named, suggestion, basis| {
            resolve(placeholder, "capture", lifecycle, named, suggestion).accepts_suggestion(basis)
        };
        for basis in [Draft, Final] {
            assert!(accepts(ReadyForReview, false, None, basis));
            assert!(!accepts(ReadyForReview, true, None, basis));
            assert!(!accepts(Recording, false, Some(("Plan", Final)), basis));
            assert!(!accepts(
                ReadyForReview,
                false,
                Some(("Plan", Final)),
                basis
            ));
        }
        assert!(accepts(Recording, false, Some(("Plan", Draft)), Draft));
        assert!(!accepts(
            ReadyForReview,
            false,
            Some(("Plan", Draft)),
            Draft
        ));
        assert!(accepts(ReadyForReview, false, Some(("Plan", Draft)), Final));
        assert!(
            !resolve("Board prep", "capture", ReadyForReview, false, None)
                .accepts_suggestion(Final)
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
        assert!(validated_suggestion("Line\u{7}break").is_err());
        assert_eq!(checked_title("  Board prep ").unwrap(), "Board prep");
        assert!(checked_title(&"x".repeat(MAX_TITLE_BYTES + 1)).is_err());
    }

    #[test]
    fn imported_names_lose_control_characters_instead_of_refusing() {
        assert_eq!(
            imported_title("Board\tprep\u{7}notes\n"),
            "Board prep notes"
        );
        assert_eq!(
            checked_title(&imported_title("\u{1b}[31mCall")).unwrap(),
            "[31mCall"
        );
        assert_eq!(imported_title(" \u{0}\r\n"), "Imported conversation");
        assert!(
            checked_title("Board\tprep").is_err(),
            "a person's rename still refuses them"
        );
    }
}
