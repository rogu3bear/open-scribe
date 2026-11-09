//! Source-topology disposition before voice clustering.
//!
//! Known capture sources are not rediscovered by clustering. No VAD,
//! embedder, clustering threshold, or model weight is selected. Clustering
//! stays unavailable until a versioned calibration artifact exists.

/// Disposition algorithm. It does not name a model or a threshold.
pub const ALGORITHM_ID: &str = "topology-before-clustering-v1";

/// Clustering cannot run: no calibrated diarization model is installed.
pub const CLUSTERING_UNAVAILABLE: &str = "unavailable";

/// Why this decision does not split a track into speakers.
pub const UNAVAILABLE_REASON: &str = "no calibrated diarization model";

/// Whether a track's identity is already known from capture topology.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SpeakerDisposition {
    /// Microphone, application, or system audio. Do not recluster it.
    Topology,
    /// Imported audio or any other kind. Identity stays unresolved.
    Unresolved,
}

impl SpeakerDisposition {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Topology => "topology",
            Self::Unresolved => "unresolved",
        }
    }
}

/// Voice clustering has no calibrated state in this crate.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ClusteringState {
    Unavailable,
}

impl ClusteringState {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Unavailable => CLUSTERING_UNAVAILABLE,
        }
    }
}

/// The only diarization decision this crate can make.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TrackDiarization {
    pub disposition: SpeakerDisposition,
    pub clustering: ClusteringState,
    pub reason: &'static str,
}

/// Classifies one source kind. The result has no speaker count, numeric
/// threshold, or generated name.
#[must_use]
pub fn disposition_for_source_kind(source_kind: &str) -> TrackDiarization {
    let disposition = match source_kind {
        "microphone" | "application_audio" | "system_audio" => SpeakerDisposition::Topology,
        _ => SpeakerDisposition::Unresolved,
    };
    TrackDiarization {
        disposition,
        clustering: ClusteringState::Unavailable,
        reason: UNAVAILABLE_REASON,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_sources_stay_topology_and_other_sources_stay_unresolved() {
        for kind in ["microphone", "application_audio", "system_audio"] {
            let decision = disposition_for_source_kind(kind);
            assert_eq!(decision.disposition, SpeakerDisposition::Topology);
            assert_eq!(decision.disposition.as_str(), "topology");
            assert_eq!(decision.clustering, ClusteringState::Unavailable);
            assert_eq!(decision.clustering.as_str(), CLUSTERING_UNAVAILABLE);
            assert_eq!(decision.reason, UNAVAILABLE_REASON);
        }
        for kind in ["imported_audio", "mystery", ""] {
            let decision = disposition_for_source_kind(kind);
            assert_eq!(decision.disposition, SpeakerDisposition::Unresolved);
            assert_eq!(decision.disposition.as_str(), "unresolved");
            assert_eq!(decision.clustering, ClusteringState::Unavailable);
            assert_eq!(decision.reason, UNAVAILABLE_REASON);
        }
    }
}
