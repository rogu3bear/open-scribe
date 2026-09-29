use serde::Deserialize;
use std::fmt;

const MANIFEST_JSON: &str = include_str!("../../../docs/models/manifest.v1.json");
const MANIFEST_SCHEMA: &str = "open-scribe.models/v1";

/// Expected GGML Whisper hyperparameters, in file order after the magic.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
pub struct ModelHeader {
    pub magic: u32,
    pub n_vocab: i32,
    pub n_audio_ctx: i32,
    pub n_audio_state: i32,
    pub n_audio_head: i32,
    pub n_audio_layer: i32,
    pub n_text_ctx: i32,
    pub n_text_state: i32,
    pub n_text_head: i32,
    pub n_text_layer: i32,
    pub n_mels: i32,
    pub ftype: i32,
}

/// One checked catalog entry. Only fields the runtime acts on are typed;
/// provenance fields remain in the manifest for notices and release review.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct ModelRecord {
    pub id: String,
    pub profile: String,
    pub version: String,
    pub purpose: String,
    pub revision: String,
    pub license: String,
    pub engine: String,
    pub format: String,
    pub compatibility: String,
    pub header: ModelHeader,
    pub languages: Vec<String>,
    pub file_name: String,
    pub download_origins: Vec<String>,
    pub removal_group: String,
    pub sha256: String,
    pub byte_length: u64,
    pub bundled: bool,
}

#[derive(Debug, Deserialize)]
struct Manifest {
    schema: String,
    bundled_large_weights: bool,
    models: Vec<ModelRecord>,
}

#[derive(Debug, Eq, PartialEq)]
pub enum CatalogError {
    Malformed,
    UnsupportedSchema,
    BundledWeights,
    InvalidRecord(String),
    DuplicateId(String),
}

impl fmt::Display for CatalogError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Malformed => f.write_str("model manifest is not valid JSON"),
            Self::UnsupportedSchema => f.write_str("model manifest schema is unsupported"),
            Self::BundledWeights => f.write_str("model manifest declares bundled weights"),
            Self::InvalidRecord(id) => write!(f, "model record {id} is invalid"),
            Self::DuplicateId(id) => write!(f, "model record {id} is duplicated"),
        }
    }
}

impl std::error::Error for CatalogError {}

#[derive(Clone, Debug)]
pub struct Catalog {
    records: Vec<ModelRecord>,
}

impl Catalog {
    /// The checked catalog compiled into this build.
    pub fn canonical() -> Result<Self, CatalogError> {
        Self::parse(MANIFEST_JSON)
    }

    pub fn parse(json: &str) -> Result<Self, CatalogError> {
        let manifest: Manifest = serde_json::from_str(json).map_err(|_| CatalogError::Malformed)?;
        if manifest.schema != MANIFEST_SCHEMA {
            return Err(CatalogError::UnsupportedSchema);
        }
        if manifest.bundled_large_weights {
            return Err(CatalogError::BundledWeights);
        }
        let mut seen = std::collections::BTreeSet::new();
        for record in &manifest.models {
            if !seen.insert(record.id.clone()) {
                return Err(CatalogError::DuplicateId(record.id.clone()));
            }
            if !record_is_valid(record) {
                return Err(CatalogError::InvalidRecord(record.id.clone()));
            }
        }
        Ok(Self {
            records: manifest.models,
        })
    }

    pub fn records(&self) -> &[ModelRecord] {
        &self.records
    }

    pub fn get(&self, id: &str) -> Option<&ModelRecord> {
        self.records.iter().find(|record| record.id == id)
    }
}

fn record_is_valid(record: &ModelRecord) -> bool {
    identifier_is_safe(&record.id)
        && identifier_is_safe(&record.version)
        && identifier_is_safe(&record.file_name)
        && record.sha256.len() == 64
        && record
            .sha256
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
        && record.byte_length > 0
        && !record.bundled
        && !record.download_origins.is_empty()
        && record
            .download_origins
            .iter()
            .all(|origin| origin.starts_with("https://"))
}

/// Identifiers become path components, so they are restricted to a plain
/// portable alphabet with no separators, traversal, or hidden names.
fn identifier_is_safe(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && !value.starts_with('.')
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonical_catalog_declares_the_adr_profiles_without_bundled_weights() {
        let catalog = Catalog::canonical().unwrap();
        let profiles: Vec<_> = catalog
            .records()
            .iter()
            .map(|record| record.profile.as_str())
            .collect();
        assert_eq!(profiles, ["balanced-en", "balanced-multilingual"]);
        for record in catalog.records() {
            assert!(!record.bundled);
            assert_eq!(record.engine, "whisper.cpp");
            assert_eq!(record.header.magic, 0x6767_6d6c);
            assert!(record.download_origins[0].contains(&record.revision));
            assert!(record.download_origins[0].ends_with(&record.file_name));
        }
    }

    #[test]
    fn unsafe_or_contradictory_records_are_rejected() {
        let valid =
            serde_json::to_value(serde_json::from_str::<serde_json::Value>(MANIFEST_JSON).unwrap())
                .unwrap();
        let mutate = |path: &str, value: serde_json::Value| {
            let mut manifest = valid.clone();
            manifest["models"][0][path] = value;
            Catalog::parse(&manifest.to_string()).unwrap_err()
        };
        let id = "whisper-small.en-q5_1".to_owned();
        assert_eq!(
            mutate("file_name", "../escape.bin".into()),
            CatalogError::InvalidRecord(id.clone())
        );
        assert_eq!(
            mutate("sha256", "ABC".into()),
            CatalogError::InvalidRecord(id.clone())
        );
        assert_eq!(
            mutate("bundled", true.into()),
            CatalogError::InvalidRecord(id.clone())
        );
        assert_eq!(
            mutate(
                "download_origins",
                serde_json::json!(["http://example.invalid/x"])
            ),
            CatalogError::InvalidRecord(id)
        );

        let mut duplicate = valid.clone();
        duplicate["models"][1]["id"] = "whisper-small.en-q5_1".into();
        assert!(matches!(
            Catalog::parse(&duplicate.to_string()),
            Err(CatalogError::DuplicateId(_))
        ));

        let mut bundled = valid.clone();
        bundled["bundled_large_weights"] = true.into();
        assert_eq!(
            Catalog::parse(&bundled.to_string()).unwrap_err(),
            CatalogError::BundledWeights
        );

        let mut schema = valid;
        schema["schema"] = "open-scribe.models/v2".into();
        assert_eq!(
            Catalog::parse(&schema.to_string()).unwrap_err(),
            CatalogError::UnsupportedSchema
        );
    }
}
