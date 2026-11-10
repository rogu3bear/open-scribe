//! Provider-scope authorization for Open Scribe.
//!
//! Configuring a provider grants no content category and opens no connection.
//! A prepared review includes only categories a person granted for that run.
//! Claim generation is not implemented: this crate does not load a model,
//! store a secret, or contact a network.

mod authorization;
pub use authorization::{
    AuthorizedPart, CONFIGURED_PROVIDER_NOTICE, ContentCategory, ExecutionMode, NO_OUTBOUND_NOTICE,
    OfferedRecord, PolicyError, PreparedReview, ProviderConfiguration, ProviderReceipt,
    RunAuthorization, UNCONFIGURED_PROVIDER_NOTICE, authorize_run, configure_provider,
    grant_category, materialize_review, outbound_from_configuration, refuse_provider_secret,
    retarget_remote,
};
