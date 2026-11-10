//! Provider configuration is not permission to disclose a conversation.
//!
//! A configuration names a provider and, for a remote provider, one public
//! HTTPS origin. It grants no content category and opens no connection. A run
//! may include only the categories a person granted for that run. Audio and
//! snapshots cannot be granted. This build has no transport, so a prepared
//! review never reports an outbound request.

use std::collections::BTreeSet;
use std::fmt;

pub const CONFIGURED_PROVIDER_NOTICE: &str =
    "Provider configured — no conversation content authorized";
pub const UNCONFIGURED_PROVIDER_NOTICE: &str =
    "No remote provider is configured. Conversation content is not sent.";
pub const NO_OUTBOUND_NOTICE: &str = "No outbound request was made.";

const MAX_PARTS: usize = 32;
const MAX_TEXT_BYTES: usize = 65_536;
const MAX_TOTAL_BYTES: u64 = 256 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub enum ContentCategory {
    FinalTranscript,
    DraftTranscript,
    ContextText,
    UserNotes,
    ParticipantTopic,
    HumanCorrections,
    ExistingDerivedClaims,
}

impl ContentCategory {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::FinalTranscript => "final_transcript",
            Self::DraftTranscript => "draft_transcript",
            Self::ContextText => "context_text",
            Self::UserNotes => "user_notes",
            Self::ParticipantTopic => "participant_topic",
            Self::HumanCorrections => "human_corrections",
            Self::ExistingDerivedClaims => "existing_derived_claims",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ExecutionMode {
    Local,
    Remote,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProviderConfiguration {
    pub provider_id: String,
    pub model_id: String,
    pub execution: ExecutionMode,
    pub origin: Option<String>,
    pub credential_fingerprint: Option<String>,
    pub notice: &'static str,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RunAuthorization {
    pub authorization_id: String,
    pub session_id: String,
    pub configuration: ProviderConfiguration,
    granted: BTreeSet<ContentCategory>,
}

impl RunAuthorization {
    pub fn granted(&self) -> impl Iterator<Item = ContentCategory> + '_ {
        self.granted.iter().copied()
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OfferedRecord {
    pub category: ContentCategory,
    pub record_id: String,
    pub revision_id: Option<String>,
    pub content_digest: String,
    pub byte_count: u64,
    pub text: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuthorizedPart {
    pub category: ContentCategory,
    pub record_id: String,
    pub revision_id: Option<String>,
    pub content_digest: String,
    pub byte_count: u64,
    pub text: String,
}

/// What a person can inspect before anything leaves the Mac. This build has
/// no provider transport, so `network_used` and `outbound_request` stay false.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PreparedReview {
    pub granted: Vec<ContentCategory>,
    pub parts: Vec<AuthorizedPart>,
    pub receipt: ProviderReceipt,
    pub network_used: bool,
    pub outbound_request: bool,
    pub notice: &'static str,
}

/// Content-free record of a prepared review. It has no prompt, transcript,
/// note, or secret.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProviderReceipt {
    pub authorization_id: String,
    pub categories: Vec<ContentCategory>,
    pub content_digests: Vec<String>,
    pub byte_count: u64,
    pub network_used: bool,
    pub outbound_request: bool,
    pub credential_fingerprint: Option<String>,
}

impl ProviderReceipt {
    pub fn public_record(&self) -> String {
        let categories = self
            .categories
            .iter()
            .map(|category| category.as_str())
            .collect::<Vec<_>>()
            .join(",");
        let digests = self.content_digests.join(",");
        format!(
            "authorization_id={}\ncategories={categories}\ndigests={digests}\nbyte_count={}\nnetwork_used={}\noutbound_request={}\nfingerprint={}\n",
            self.authorization_id,
            self.byte_count,
            self.network_used,
            self.outbound_request,
            self.credential_fingerprint.as_deref().unwrap_or("")
        )
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PolicyError {
    InvalidIdentifier,
    OriginRequired,
    OriginRefused,
    LocalOriginRefused,
    FingerprintRefused,
    SecretMaterialRefused,
    NoCategoryGranted,
    CategoryUnavailable,
    UnknownCategory,
    LocalGrantDoesNotAuthorizeRemote,
    OriginChangeRequiresNewAuthorization,
    InvalidRecord,
    ByteCountMismatch,
    TooLarge,
}

impl fmt::Display for PolicyError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InvalidIdentifier => "provider identity is invalid",
            Self::OriginRequired => "a remote provider needs an https origin",
            Self::OriginRefused => "that origin is not an accepted public https endpoint",
            Self::LocalOriginRefused => "a local provider has no origin",
            Self::FingerprintRefused => "a credential fingerprint must be a SHA-256 digest",
            Self::SecretMaterialRefused => "provider secrets are not stored",
            Self::NoCategoryGranted => "a review needs at least one granted content category",
            Self::CategoryUnavailable => "audio and snapshots are not available to a provider",
            Self::UnknownCategory => "unknown content category",
            Self::LocalGrantDoesNotAuthorizeRemote => {
                "a local grant does not authorize a remote provider"
            }
            Self::OriginChangeRequiresNewAuthorization => {
                "changing the origin requires a new authorization"
            }
            Self::InvalidRecord => "an offered record is invalid",
            Self::ByteCountMismatch => "the offered byte count does not match the text",
            Self::TooLarge => "the offered review is too large",
        })
    }
}

impl std::error::Error for PolicyError {}

pub fn configure_provider(
    provider_id: &str,
    model_id: &str,
    execution: ExecutionMode,
    origin: Option<&str>,
    credential_fingerprint: Option<&str>,
) -> Result<ProviderConfiguration, PolicyError> {
    if !identifier_is_valid(provider_id) || !identifier_is_valid(model_id) {
        return Err(PolicyError::InvalidIdentifier);
    }
    let origin = match (execution, origin) {
        (ExecutionMode::Local, None) => None,
        (ExecutionMode::Local, Some(_)) => return Err(PolicyError::LocalOriginRefused),
        (ExecutionMode::Remote, None) => return Err(PolicyError::OriginRequired),
        (ExecutionMode::Remote, Some(origin)) => {
            if !origin_is_public_https(origin) {
                return Err(PolicyError::OriginRefused);
            }
            Some(origin.to_owned())
        }
    };
    let credential_fingerprint = match credential_fingerprint {
        None => None,
        Some(value) if fingerprint_is_digest(value) => Some(value.to_owned()),
        Some(_) => return Err(PolicyError::FingerprintRefused),
    };
    Ok(ProviderConfiguration {
        provider_id: provider_id.to_owned(),
        model_id: model_id.to_owned(),
        execution,
        origin,
        credential_fingerprint,
        notice: CONFIGURED_PROVIDER_NOTICE,
    })
}

/// This build does not accept provider secrets. The error text never echoes
/// the submitted material.
pub fn refuse_provider_secret(material: &str) -> Result<(), PolicyError> {
    let _ = material;
    Err(PolicyError::SecretMaterialRefused)
}

pub fn grant_category(name: &str) -> Result<ContentCategory, PolicyError> {
    match name {
        "final_transcript" => Ok(ContentCategory::FinalTranscript),
        "draft_transcript" => Ok(ContentCategory::DraftTranscript),
        "context_text" => Ok(ContentCategory::ContextText),
        "user_notes" => Ok(ContentCategory::UserNotes),
        "participant_topic" => Ok(ContentCategory::ParticipantTopic),
        "human_corrections" => Ok(ContentCategory::HumanCorrections),
        "existing_derived_claims" => Ok(ContentCategory::ExistingDerivedClaims),
        "audio" | "snapshots" => Err(PolicyError::CategoryUnavailable),
        _ => Err(PolicyError::UnknownCategory),
    }
}

pub fn authorize_run(
    configuration: &ProviderConfiguration,
    authorization_id: &str,
    session_id: &str,
    granted: &[ContentCategory],
) -> Result<RunAuthorization, PolicyError> {
    if !identifier_is_valid(authorization_id) || !identifier_is_valid(session_id) {
        return Err(PolicyError::InvalidIdentifier);
    }
    if granted.is_empty() {
        return Err(PolicyError::NoCategoryGranted);
    }
    Ok(RunAuthorization {
        authorization_id: authorization_id.to_owned(),
        session_id: session_id.to_owned(),
        configuration: configuration.clone(),
        granted: granted.iter().copied().collect(),
    })
}

/// Configuration alone cannot prepare a review, even when records are offered.
pub fn outbound_from_configuration(
    configuration: &ProviderConfiguration,
    offered: &[OfferedRecord],
) -> Result<PreparedReview, PolicyError> {
    let _ = (configuration, offered);
    Err(PolicyError::NoCategoryGranted)
}

pub fn materialize_review(
    authorization: &RunAuthorization,
    offered: &[OfferedRecord],
) -> Result<PreparedReview, PolicyError> {
    if authorization.granted.is_empty() {
        return Err(PolicyError::NoCategoryGranted);
    }
    if offered.len() > MAX_PARTS {
        return Err(PolicyError::TooLarge);
    }
    let mut total_bytes = 0_u64;
    for record in offered {
        validate_record(record)?;
        total_bytes = total_bytes
            .checked_add(record.byte_count)
            .ok_or(PolicyError::TooLarge)?;
        if total_bytes > MAX_TOTAL_BYTES {
            return Err(PolicyError::TooLarge);
        }
    }
    let mut parts = Vec::new();
    for record in offered {
        if !authorization.granted.contains(&record.category) {
            continue;
        }
        parts.push(AuthorizedPart {
            category: record.category,
            record_id: record.record_id.clone(),
            revision_id: record.revision_id.clone(),
            content_digest: record.content_digest.clone(),
            byte_count: record.byte_count,
            text: record.text.clone(),
        });
    }
    parts.sort_by(|left, right| {
        (left.category, left.record_id.as_str()).cmp(&(right.category, right.record_id.as_str()))
    });
    let mut categories = parts.iter().map(|part| part.category).collect::<Vec<_>>();
    categories.dedup();
    let receipt = ProviderReceipt {
        authorization_id: authorization.authorization_id.clone(),
        categories,
        content_digests: parts
            .iter()
            .map(|part| part.content_digest.clone())
            .collect(),
        byte_count: parts.iter().map(|part| part.byte_count).sum(),
        network_used: false,
        outbound_request: false,
        credential_fingerprint: authorization.configuration.credential_fingerprint.clone(),
    };
    Ok(PreparedReview {
        granted: authorization.granted.iter().copied().collect(),
        parts,
        receipt,
        network_used: false,
        outbound_request: false,
        notice: NO_OUTBOUND_NOTICE,
    })
}

/// A local authorization cannot be reused for a remote origin. Changing an
/// existing remote origin also requires a new authorization.
pub fn retarget_remote(
    authorization: &RunAuthorization,
    origin: &str,
) -> Result<RunAuthorization, PolicyError> {
    let _ = origin;
    match authorization.configuration.execution {
        ExecutionMode::Local => Err(PolicyError::LocalGrantDoesNotAuthorizeRemote),
        ExecutionMode::Remote => Err(PolicyError::OriginChangeRequiresNewAuthorization),
    }
}

fn validate_record(record: &OfferedRecord) -> Result<(), PolicyError> {
    if !identifier_is_valid(&record.record_id)
        || !record
            .revision_id
            .as_deref()
            .is_none_or(identifier_is_valid)
        || !fingerprint_is_digest(&record.content_digest)
    {
        return Err(PolicyError::InvalidRecord);
    }
    if record.text.len() > MAX_TEXT_BYTES {
        return Err(PolicyError::TooLarge);
    }
    if u64::try_from(record.text.len()).ok() != Some(record.byte_count) {
        return Err(PolicyError::ByteCountMismatch);
    }
    Ok(())
}

fn identifier_is_valid(value: &str) -> bool {
    let bytes = value.as_bytes();
    (1..=128).contains(&bytes.len())
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
}

fn fingerprint_is_digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn origin_is_public_https(origin: &str) -> bool {
    let Some(rest) = origin.strip_prefix("https://") else {
        return false;
    };
    if rest.is_empty()
        || rest.contains(['@', '?', '#', '\\', ' ', '\n', '\r', '\t'])
        || rest.starts_with('[')
    {
        return false;
    }
    let host_port = rest.split_once('/').map_or(rest, |(host, _)| host);
    if host_port.is_empty() {
        return false;
    }
    let host = if let Some((host, port)) = host_port.rsplit_once(':') {
        if port.is_empty() || port.len() > 5 || !port.bytes().all(|byte| byte.is_ascii_digit()) {
            return false;
        }
        host
    } else {
        host_port
    };
    hostname_is_public(host)
}

fn hostname_is_public(host: &str) -> bool {
    if host.is_empty()
        || host.len() > 253
        || host.starts_with('.')
        || host.ends_with('.')
        || host.contains("..")
    {
        return false;
    }
    let lower = host.to_ascii_lowercase();
    if lower == "localhost" || lower.ends_with(".localhost") || lower.ends_with(".local") {
        return false;
    }
    if lower.parse::<std::net::Ipv4Addr>().is_ok() {
        return false;
    }
    let labels: Vec<&str> = lower.split('.').collect();
    if labels.len() < 2 {
        return false;
    }
    labels.iter().all(|label| {
        (1..=63).contains(&label.len())
            && !label.starts_with('-')
            && !label.ends_with('-')
            && label
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const DIGEST: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const OTHER_DIGEST: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    fn remote() -> ProviderConfiguration {
        configure_provider(
            "example",
            "review",
            ExecutionMode::Remote,
            Some("https://api.example.com/v1"),
            Some(DIGEST),
        )
        .expect("public https configuration")
    }

    fn offered(category: ContentCategory, digest: &str, text: &str) -> OfferedRecord {
        OfferedRecord {
            category,
            record_id: "record-1".to_owned(),
            revision_id: Some("revision-1".to_owned()),
            content_digest: digest.to_owned(),
            byte_count: text.len() as u64,
            text: text.to_owned(),
        }
    }

    #[test]
    fn configuration_grants_nothing_and_sends_nothing() {
        let configuration = remote();
        assert_eq!(configuration.notice, CONFIGURED_PROVIDER_NOTICE);
        assert!(configuration.credential_fingerprint.is_some());
        let draft = "draft text stays local";
        let error = outbound_from_configuration(
            &configuration,
            &[offered(
                ContentCategory::DraftTranscript,
                OTHER_DIGEST,
                draft,
            )],
        )
        .expect_err("configuration is not a grant");
        assert_eq!(error, PolicyError::NoCategoryGranted);
        assert!(!error.to_string().contains(draft));
    }

    #[test]
    fn a_granted_category_excludes_every_other_category() {
        let configuration = remote();
        let final_text = "The decision was to ship.";
        let draft = "unrelated draft stays out";
        let authorization = authorize_run(
            &configuration,
            "auth-1",
            "session-1",
            &[ContentCategory::FinalTranscript],
        )
        .expect("one category");
        let prepared = materialize_review(
            &authorization,
            &[
                offered(ContentCategory::DraftTranscript, OTHER_DIGEST, draft),
                offered(ContentCategory::FinalTranscript, DIGEST, final_text),
            ],
        )
        .expect("prepared");
        assert!(!prepared.network_used);
        assert!(!prepared.outbound_request);
        assert_eq!(prepared.notice, NO_OUTBOUND_NOTICE);
        assert_eq!(prepared.parts.len(), 1);
        assert_eq!(prepared.parts[0].text, final_text);
        assert_eq!(prepared.parts[0].category, ContentCategory::FinalTranscript);
        let record = prepared.receipt.public_record();
        assert!(!record.contains(draft));
        assert!(!record.contains(final_text));
        assert!(record.contains("final_transcript"));
        assert!(!record.contains("draft_transcript"));
        assert!(record.contains("network_used=false"));
        assert!(record.contains("outbound_request=false"));
        assert!(record.contains(DIGEST));
    }

    #[test]
    fn audio_snapshots_secrets_and_private_origins_are_refused() {
        let secret = "sk-live-example-secret";
        let refused = refuse_provider_secret(secret).expect_err("no secret store");
        assert_eq!(refused, PolicyError::SecretMaterialRefused);
        assert!(!refused.to_string().contains(secret));
        assert_eq!(
            configure_provider(
                "example",
                "review",
                ExecutionMode::Remote,
                Some("https://api.example.com"),
                Some(secret),
            )
            .expect_err("fingerprint is a digest"),
            PolicyError::FingerprintRefused
        );
        assert_eq!(
            grant_category("audio").expect_err("audio"),
            PolicyError::CategoryUnavailable
        );
        assert_eq!(
            grant_category("snapshots").expect_err("snapshots"),
            PolicyError::CategoryUnavailable
        );
        for origin in [
            "http://api.example.com",
            "https://user:pass@api.example.com",
            "https://localhost/v1",
            "https://127.0.0.1/v1",
            "https://10.1.2.3/v1",
            "https://192.168.1.9/v1",
            "https://api.example.local/v1",
            "https://[::1]/v1",
        ] {
            assert_eq!(
                configure_provider(
                    "example",
                    "review",
                    ExecutionMode::Remote,
                    Some(origin),
                    None,
                )
                .expect_err(origin),
                PolicyError::OriginRefused,
                "{origin}"
            );
        }
    }

    #[test]
    fn a_local_grant_cannot_become_a_remote_request() {
        let local = configure_provider("example", "review", ExecutionMode::Local, None, None)
            .expect("local");
        assert_eq!(
            configure_provider(
                "example",
                "review",
                ExecutionMode::Local,
                Some("https://api.example.com"),
                None,
            )
            .expect_err("local has no origin"),
            PolicyError::LocalOriginRefused
        );
        let authorization =
            authorize_run(&local, "auth-1", "session-1", &[ContentCategory::UserNotes])
                .expect("local grant");
        assert_eq!(
            retarget_remote(&authorization, "https://api.example.com").expect_err("reuse"),
            PolicyError::LocalGrantDoesNotAuthorizeRemote
        );
        let remote_authorization = authorize_run(
            &remote(),
            "auth-2",
            "session-1",
            &[ContentCategory::UserNotes],
        )
        .expect("remote grant");
        assert_eq!(
            retarget_remote(&remote_authorization, "https://other.example.com").expect_err("move"),
            PolicyError::OriginChangeRequiresNewAuthorization
        );
    }

    #[test]
    fn an_empty_grant_and_a_dishonest_byte_count_fail_closed() {
        let configuration = remote();
        assert_eq!(
            authorize_run(&configuration, "auth-1", "session-1", &[]).expect_err("empty"),
            PolicyError::NoCategoryGranted
        );
        let authorization = authorize_run(
            &configuration,
            "auth-1",
            "session-1",
            &[ContentCategory::ContextText],
        )
        .expect("grant");
        let mut record = offered(ContentCategory::ContextText, DIGEST, "visible context");
        record.byte_count = 1;
        assert_eq!(
            materialize_review(&authorization, &[record]).expect_err("count"),
            PolicyError::ByteCountMismatch
        );
    }
}
