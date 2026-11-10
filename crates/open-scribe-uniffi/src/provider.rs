//! Coarse provider-scope boundary. Configuration and review manifests cross
//! here. Audio samples, secrets, and network requests do not.

use open_scribe_core::{
    CONFIGURED_PROVIDER_NOTICE, ContentCategory, ExecutionMode, NO_OUTBOUND_NOTICE, OfferedRecord,
    PolicyError, PreparedReview, ProviderConfiguration, RunAuthorization,
    UNCONFIGURED_PROVIDER_NOTICE, authorize_run, configure_provider, grant_category,
    materialize_review, outbound_from_configuration, refuse_provider_secret, retarget_remote,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum NativeContentCategory {
    FinalTranscript,
    DraftTranscript,
    ContextText,
    UserNotes,
    ParticipantTopic,
    HumanCorrections,
    ExistingDerivedClaims,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum NativeProviderExecution {
    Local,
    Remote,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeProviderConfiguration {
    pub provider_id: String,
    pub model_id: String,
    pub execution: NativeProviderExecution,
    pub origin: Option<String>,
    pub credential_fingerprint: Option<String>,
    pub notice: String,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeProviderOfferedRecord {
    pub category: NativeContentCategory,
    pub record_id: String,
    pub revision_id: Option<String>,
    pub content_digest: String,
    pub byte_count: u64,
    pub text: String,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeAuthorizedPart {
    pub category: NativeContentCategory,
    pub record_id: String,
    pub revision_id: Option<String>,
    pub content_digest: String,
    pub byte_count: u64,
    pub text: String,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeProviderReceipt {
    pub authorization_id: String,
    pub categories: Vec<String>,
    pub content_digests: Vec<String>,
    pub byte_count: u64,
    pub network_used: bool,
    pub outbound_request: bool,
    pub credential_fingerprint: Option<String>,
    pub public_record: String,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativePreparedReview {
    pub granted: Vec<NativeContentCategory>,
    pub parts: Vec<NativeAuthorizedPart>,
    pub receipt: NativeProviderReceipt,
    pub network_used: bool,
    pub outbound_request: bool,
    pub notice: String,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum NativeProviderError {
    #[error("provider identity is invalid")]
    InvalidIdentifier,
    #[error("a remote provider needs an https origin")]
    OriginRequired,
    #[error("that origin is not an accepted public https endpoint")]
    OriginRefused,
    #[error("a local provider has no origin")]
    LocalOriginRefused,
    #[error("a credential fingerprint must be a SHA-256 digest")]
    FingerprintRefused,
    #[error("provider secrets are not stored")]
    SecretMaterialRefused,
    #[error("a review needs at least one granted content category")]
    NoCategoryGranted,
    #[error("audio and snapshots are not available to a provider")]
    CategoryUnavailable,
    #[error("unknown content category")]
    UnknownCategory,
    #[error("a local grant does not authorize a remote provider")]
    LocalGrantDoesNotAuthorizeRemote,
    #[error("changing the origin requires a new authorization")]
    OriginChangeRequiresNewAuthorization,
    #[error("an offered record is invalid")]
    InvalidRecord,
    #[error("the offered byte count does not match the text")]
    ByteCountMismatch,
    #[error("the offered review is too large")]
    TooLarge,
}

fn map_error(error: PolicyError) -> NativeProviderError {
    match error {
        PolicyError::InvalidIdentifier => NativeProviderError::InvalidIdentifier,
        PolicyError::OriginRequired => NativeProviderError::OriginRequired,
        PolicyError::OriginRefused => NativeProviderError::OriginRefused,
        PolicyError::LocalOriginRefused => NativeProviderError::LocalOriginRefused,
        PolicyError::FingerprintRefused => NativeProviderError::FingerprintRefused,
        PolicyError::SecretMaterialRefused => NativeProviderError::SecretMaterialRefused,
        PolicyError::NoCategoryGranted => NativeProviderError::NoCategoryGranted,
        PolicyError::CategoryUnavailable => NativeProviderError::CategoryUnavailable,
        PolicyError::UnknownCategory => NativeProviderError::UnknownCategory,
        PolicyError::LocalGrantDoesNotAuthorizeRemote => {
            NativeProviderError::LocalGrantDoesNotAuthorizeRemote
        }
        PolicyError::OriginChangeRequiresNewAuthorization => {
            NativeProviderError::OriginChangeRequiresNewAuthorization
        }
        PolicyError::InvalidRecord => NativeProviderError::InvalidRecord,
        PolicyError::ByteCountMismatch => NativeProviderError::ByteCountMismatch,
        PolicyError::TooLarge => NativeProviderError::TooLarge,
    }
}

fn category_from_native(category: NativeContentCategory) -> ContentCategory {
    match category {
        NativeContentCategory::FinalTranscript => ContentCategory::FinalTranscript,
        NativeContentCategory::DraftTranscript => ContentCategory::DraftTranscript,
        NativeContentCategory::ContextText => ContentCategory::ContextText,
        NativeContentCategory::UserNotes => ContentCategory::UserNotes,
        NativeContentCategory::ParticipantTopic => ContentCategory::ParticipantTopic,
        NativeContentCategory::HumanCorrections => ContentCategory::HumanCorrections,
        NativeContentCategory::ExistingDerivedClaims => ContentCategory::ExistingDerivedClaims,
    }
}

fn category_to_native(category: ContentCategory) -> NativeContentCategory {
    match category {
        ContentCategory::FinalTranscript => NativeContentCategory::FinalTranscript,
        ContentCategory::DraftTranscript => NativeContentCategory::DraftTranscript,
        ContentCategory::ContextText => NativeContentCategory::ContextText,
        ContentCategory::UserNotes => NativeContentCategory::UserNotes,
        ContentCategory::ParticipantTopic => NativeContentCategory::ParticipantTopic,
        ContentCategory::HumanCorrections => NativeContentCategory::HumanCorrections,
        ContentCategory::ExistingDerivedClaims => NativeContentCategory::ExistingDerivedClaims,
    }
}

fn execution_from_native(execution: NativeProviderExecution) -> ExecutionMode {
    match execution {
        NativeProviderExecution::Local => ExecutionMode::Local,
        NativeProviderExecution::Remote => ExecutionMode::Remote,
    }
}

fn execution_to_native(execution: ExecutionMode) -> NativeProviderExecution {
    match execution {
        ExecutionMode::Local => NativeProviderExecution::Local,
        ExecutionMode::Remote => NativeProviderExecution::Remote,
    }
}

fn configuration_to_native(configuration: ProviderConfiguration) -> NativeProviderConfiguration {
    NativeProviderConfiguration {
        provider_id: configuration.provider_id,
        model_id: configuration.model_id,
        execution: execution_to_native(configuration.execution),
        origin: configuration.origin,
        credential_fingerprint: configuration.credential_fingerprint,
        notice: configuration.notice.to_owned(),
    }
}

fn configuration_from_native(
    configuration: &NativeProviderConfiguration,
) -> Result<ProviderConfiguration, NativeProviderError> {
    configure_provider(
        &configuration.provider_id,
        &configuration.model_id,
        execution_from_native(configuration.execution),
        configuration.origin.as_deref(),
        configuration.credential_fingerprint.as_deref(),
    )
    .map_err(map_error)
}

fn prepared_to_native(prepared: PreparedReview) -> NativePreparedReview {
    let public_record = prepared.receipt.public_record();
    NativePreparedReview {
        granted: prepared
            .granted
            .into_iter()
            .map(category_to_native)
            .collect(),
        parts: prepared
            .parts
            .into_iter()
            .map(|part| NativeAuthorizedPart {
                category: category_to_native(part.category),
                record_id: part.record_id,
                revision_id: part.revision_id,
                content_digest: part.content_digest,
                byte_count: part.byte_count,
                text: part.text,
            })
            .collect(),
        receipt: NativeProviderReceipt {
            authorization_id: prepared.receipt.authorization_id,
            categories: prepared
                .receipt
                .categories
                .iter()
                .map(|category| category.as_str().to_owned())
                .collect(),
            content_digests: prepared.receipt.content_digests,
            byte_count: prepared.receipt.byte_count,
            network_used: prepared.receipt.network_used,
            outbound_request: prepared.receipt.outbound_request,
            credential_fingerprint: prepared.receipt.credential_fingerprint,
            public_record,
        },
        network_used: prepared.network_used,
        outbound_request: prepared.outbound_request,
        notice: prepared.notice.to_owned(),
    }
}

#[uniffi::export]
pub fn provider_configured_notice() -> String {
    CONFIGURED_PROVIDER_NOTICE.to_owned()
}

#[uniffi::export]
pub fn provider_unconfigured_notice() -> String {
    UNCONFIGURED_PROVIDER_NOTICE.to_owned()
}

#[uniffi::export]
pub fn provider_no_outbound_notice() -> String {
    NO_OUTBOUND_NOTICE.to_owned()
}

#[uniffi::export]
pub fn configure_content_provider(
    provider_id: String,
    model_id: String,
    execution: NativeProviderExecution,
    origin: Option<String>,
    credential_fingerprint: Option<String>,
) -> Result<NativeProviderConfiguration, NativeProviderError> {
    configure_provider(
        &provider_id,
        &model_id,
        execution_from_native(execution),
        origin.as_deref(),
        credential_fingerprint.as_deref(),
    )
    .map(configuration_to_native)
    .map_err(map_error)
}

#[uniffi::export]
pub fn refuse_content_provider_secret(material: String) -> Result<(), NativeProviderError> {
    refuse_provider_secret(&material).map_err(map_error)
}

#[uniffi::export]
pub fn grant_content_category(name: String) -> Result<NativeContentCategory, NativeProviderError> {
    grant_category(&name)
        .map(category_to_native)
        .map_err(map_error)
}

#[uniffi::export]
pub fn authorize_content_provider_run(
    configuration: NativeProviderConfiguration,
    authorization_id: String,
    session_id: String,
    granted: Vec<NativeContentCategory>,
) -> Result<Vec<NativeContentCategory>, NativeProviderError> {
    let configuration = configuration_from_native(&configuration)?;
    let granted = granted
        .into_iter()
        .map(category_from_native)
        .collect::<Vec<_>>();
    let authorization = authorize_run(&configuration, &authorization_id, &session_id, &granted)
        .map_err(map_error)?;
    Ok(authorization.granted().map(category_to_native).collect())
}

#[uniffi::export]
pub fn materialize_content_provider_review(
    configuration: NativeProviderConfiguration,
    authorization_id: String,
    session_id: String,
    granted: Vec<NativeContentCategory>,
    offered: Vec<NativeProviderOfferedRecord>,
) -> Result<NativePreparedReview, NativeProviderError> {
    let configuration = configuration_from_native(&configuration)?;
    let granted_native = granted;
    let granted = granted_native
        .iter()
        .copied()
        .map(category_from_native)
        .collect::<Vec<_>>();
    let authorization: RunAuthorization =
        authorize_run(&configuration, &authorization_id, &session_id, &granted)
            .map_err(map_error)?;
    let offered = offered
        .into_iter()
        .map(|record| OfferedRecord {
            category: category_from_native(record.category),
            record_id: record.record_id,
            revision_id: record.revision_id,
            content_digest: record.content_digest,
            byte_count: record.byte_count,
            text: record.text,
        })
        .collect::<Vec<_>>();
    materialize_review(&authorization, &offered)
        .map(prepared_to_native)
        .map_err(map_error)
}

#[uniffi::export]
pub fn outbound_from_content_provider_configuration(
    configuration: NativeProviderConfiguration,
    offered: Vec<NativeProviderOfferedRecord>,
) -> Result<NativePreparedReview, NativeProviderError> {
    let configuration = configuration_from_native(&configuration)?;
    let offered = offered
        .into_iter()
        .map(|record| OfferedRecord {
            category: category_from_native(record.category),
            record_id: record.record_id,
            revision_id: record.revision_id,
            content_digest: record.content_digest,
            byte_count: record.byte_count,
            text: record.text,
        })
        .collect::<Vec<_>>();
    outbound_from_configuration(&configuration, &offered)
        .map(prepared_to_native)
        .map_err(map_error)
}

#[uniffi::export]
pub fn retarget_content_provider_remote(
    configuration: NativeProviderConfiguration,
    authorization_id: String,
    session_id: String,
    granted: Vec<NativeContentCategory>,
    origin: String,
) -> Result<(), NativeProviderError> {
    let configuration = configuration_from_native(&configuration)?;
    let granted = granted
        .into_iter()
        .map(category_from_native)
        .collect::<Vec<_>>();
    let authorization = authorize_run(&configuration, &authorization_id, &session_id, &granted)
        .map_err(map_error)?;
    retarget_remote(&authorization, &origin)
        .map(|_| ())
        .map_err(map_error)
}
