use super::*;

#[test]
fn request_bounds_fail_before_creating_session_state() {
    let temp = TempDir::new().unwrap();
    let mut store = open_store(&temp);

    for title in [String::new(), "x".repeat(MAX_TITLE_BYTES + 1)] {
        let error = store
            .prepare_session(PrepareSessionRequest {
                title,
                origin: SessionOrigin::Capture,
            })
            .unwrap_err();
        assert!(matches!(error, StoreError::InvalidRequest(_)));
    }
    assert_eq!(database_value(&store, "SELECT COUNT(*) FROM sessions"), 0);
    assert_eq!(fs::read_dir(&store.sessions_root).unwrap().count(), 0);
}

fn media_request(session_id: SessionId) -> AuthorizeMediaOpenRequest {
    AuthorizeMediaOpenRequest {
        session_id,
        source_kind: MediaSourceKind::Microphone,
        source_display_name: "Synthetic microphone".to_owned(),
    }
}

pub(super) fn write_test_caf(authorization: &MediaOpenAuthorization) -> u64 {
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&authorization.absolute_path)
        .unwrap();
    file.write_all(b"caff\0\x01\0\0deterministic-test-media")
        .unwrap();
    file.sync_all().unwrap();
    file.metadata().unwrap().len()
}

pub(super) fn media_receipt(
    authorization: &MediaOpenAuthorization,
    initial_byte_length: u64,
) -> MediaOpenReceipt {
    MediaOpenReceipt {
        session_id: authorization.session_id.clone(),
        track_id: authorization.track_id.clone(),
        segment_id: authorization.segment_id.clone(),
        open_token: authorization.open_token.clone(),
        writer_generation: authorization.writer_generation,
        relative_path: authorization.relative_path.clone(),
        media_format: authorization.media_format.clone(),
        sample_rate_hz: authorization.sample_rate_hz,
        channels: authorization.channels,
        initial_byte_length,
    }
}

pub(super) fn append_first_sample(authorization: &MediaOpenAuthorization) -> u64 {
    let mut writer = OpenOptions::new()
        .append(true)
        .open(&authorization.absolute_path)
        .unwrap();
    writer.write_all(b"first-captured-sample").unwrap();
    writer.sync_all().unwrap();
    writer.metadata().unwrap().len()
}

pub(super) fn first_sample_receipt(
    authorization: &MediaOpenAuthorization,
    observed_byte_length: u64,
) -> FirstSampleReceipt {
    FirstSampleReceipt {
        session_id: authorization.session_id.clone(),
        track_id: authorization.track_id.clone(),
        segment_id: authorization.segment_id.clone(),
        open_token: authorization.open_token.clone(),
        writer_generation: authorization.writer_generation,
        relative_path: authorization.relative_path.clone(),
        first_sample_host_time: 42_000,
        first_sample_frame_count: 480,
        observed_byte_length,
    }
}

pub(super) fn seal_receipt(
    authorization: &MediaOpenAuthorization,
    final_byte_length: u64,
) -> SealSegmentReceipt {
    SealSegmentReceipt {
        session_id: authorization.session_id.clone(),
        track_id: authorization.track_id.clone(),
        segment_id: authorization.segment_id.clone(),
        open_token: authorization.open_token.clone(),
        writer_generation: authorization.writer_generation,
        relative_path: authorization.relative_path.clone(),
        final_sample_host_time: 52_000,
        sample_count: 960,
        final_byte_length,
    }
}

fn prepared_first_sample(
    store: &mut SessionStore,
) -> (PreparedSessionReceipt, MediaOpenAuthorization, u64) {
    let prepared = store.prepare_session(request()).unwrap();
    let authorization = store
        .authorize_media_open(media_request(prepared.session_id.clone()))
        .unwrap();
    let initial_byte_length = write_test_caf(&authorization);
    store
        .accept_media_open(media_receipt(&authorization, initial_byte_length))
        .unwrap();
    let observed_byte_length = append_first_sample(&authorization);
    store
        .accept_first_sample(first_sample_receipt(&authorization, observed_byte_length))
        .unwrap();
    (prepared, authorization, observed_byte_length)
}

/// A first-sample segment rewritten as the 960-frame PCM CAF that
/// `seal_receipt` reports, so sealing can validate its channel layout.
fn prepared_sealable_segment(
    store: &mut SessionStore,
) -> (PreparedSessionReceipt, MediaOpenAuthorization, u64) {
    let (prepared, authorization, _) = prepared_first_sample(store);
    replace_with_recoverable_pcm_caf(&authorization, 960);
    let final_byte_length = fs::metadata(&authorization.absolute_path).unwrap().len();
    (prepared, authorization, final_byte_length)
}

pub(super) fn prepared_dual_first_samples(
    store: &mut SessionStore,
) -> (
    PreparedSessionReceipt,
    MediaOpenAuthorization,
    MediaOpenAuthorization,
) {
    let prepared = store
        .prepare_session_with_required_sources(
            request(),
            vec![MediaSourceKind::Microphone, MediaSourceKind::SystemAudio],
        )
        .unwrap();
    let microphone = store
        .authorize_media_open(AuthorizeMediaOpenRequest {
            session_id: prepared.session_id.clone(),
            source_kind: MediaSourceKind::Microphone,
            source_display_name: "Mac microphone".to_owned(),
        })
        .unwrap();
    let microphone_initial = write_test_caf(&microphone);
    store
        .accept_media_open(media_receipt(&microphone, microphone_initial))
        .unwrap();
    let system = store
        .authorize_media_open(AuthorizeMediaOpenRequest {
            session_id: prepared.session_id.clone(),
            source_kind: MediaSourceKind::SystemAudio,
            source_display_name: "Mac system audio".to_owned(),
        })
        .unwrap();
    let system_initial = write_test_caf(&system);
    store
        .accept_media_open(media_receipt(&system, system_initial))
        .unwrap();
    let microphone_observed = append_first_sample(&microphone);
    store
        .accept_first_sample(first_sample_receipt(&microphone, microphone_observed))
        .unwrap();
    let system_observed = append_first_sample(&system);
    store
        .accept_first_sample(first_sample_receipt(&system, system_observed))
        .unwrap();
    (prepared, microphone, system)
}

pub(super) fn replace_with_recoverable_pcm_caf(
    authorization: &MediaOpenAuthorization,
    sample_count: u64,
) {
    let mut file = OpenOptions::new()
        .write(true)
        .truncate(true)
        .open(&authorization.absolute_path)
        .unwrap();
    file.write_all(CAF_HEADER).unwrap();
    file.write_all(b"desc").unwrap();
    file.write_all(&32_i64.to_be_bytes()).unwrap();
    file.write_all(&48_000_f64.to_bits().to_be_bytes()).unwrap();
    file.write_all(b"lpcm").unwrap();
    file.write_all(&2_u32.to_be_bytes()).unwrap();
    file.write_all(&(2 * u32::from(authorization.channels)).to_be_bytes())
        .unwrap();
    file.write_all(&1_u32.to_be_bytes()).unwrap();
    file.write_all(&u32::from(authorization.channels).to_be_bytes())
        .unwrap();
    file.write_all(&16_u32.to_be_bytes()).unwrap();
    file.write_all(b"data").unwrap();
    file.write_all(&(-1_i64).to_be_bytes()).unwrap();
    file.write_all(&0_u32.to_be_bytes()).unwrap();
    file.write_all(&vec![
        0_u8;
        sample_count as usize
            * 2
            * usize::from(authorization.channels)
    ])
    .unwrap();
    file.sync_all().unwrap();
}

fn insert_parallel_database_event(
    store: &mut SessionStore,
    session_id: &str,
    event_kind: &str,
    payload: &Value,
) {
    let (sequence, prior_digest) = next_database_event(&store.connection, session_id).unwrap();
    let digest = event_digest(
        session_id,
        sequence,
        event_kind,
        payload,
        prior_digest.as_deref(),
    )
    .unwrap();
    let transaction = store.connection.transaction().unwrap();
    insert_event(
        &transaction,
        session_id,
        sequence,
        event_kind,
        wall_time_milliseconds(),
        payload,
        prior_digest.as_deref(),
        &digest,
    )
    .unwrap();
    transaction.commit().unwrap();
}

#[test]
fn sealed_segment_binds_writer_totals_to_an_independent_digest_without_recording() {
    let temp = TempDir::new().unwrap();
    let mut store = open_store(&temp);
    let (prepared, authorization, final_byte_length) = prepared_sealable_segment(&mut store);
    let receipt = seal_receipt(&authorization, final_byte_length);

    let evidence = store.seal_segment(receipt.clone()).unwrap();
    assert!(evidence.segment_sealed);
    assert!(!evidence.recording_started);
    assert_eq!(evidence.sample_count, 960);
    assert_eq!(evidence.digest_sha256.len(), 64);
    assert_eq!(store.seal_segment(receipt.clone()).unwrap(), evidence);
    assert_eq!(
        store
            .connection
            .query_row(
                "SELECT lifecycle, sample_count, byte_length, seal_state
                 FROM segments WHERE id = ?1",
                [&authorization.segment_id],
                |row| Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, String>(3)?,
                )),
            )
            .unwrap(),
        (
            "sealed".to_owned(),
            960,
            final_byte_length as i64,
            "sealed".to_owned()
        )
    );
    assert_eq!(
        store
            .connection
            .query_row(
                "SELECT lifecycle, media_files_open FROM sessions WHERE id = ?1",
                [&prepared.session_id.0],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, bool>(1)?)),
            )
            .unwrap(),
        ("preparing".to_owned(), false)
    );

    let mut changed = receipt.clone();
    changed.final_sample_host_time += 1;
    assert!(matches!(
        store.seal_segment(changed),
        Err(StoreError::IntegrityMismatch(
            "repeated segment-seal receipt changed accepted evidence"
        ))
    ));
    let mut miscounted = receipt;
    miscounted.sample_count += 1;
    assert!(matches!(
        store.seal_segment(miscounted),
        Err(StoreError::IntegrityMismatch(
            "segment-seal sample total does not match the accepted CAF"
        ))
    ));
}

#[test]
fn seal_segment_rejects_a_sample_total_that_disagrees_with_the_caf() {
    let temp = TempDir::new().unwrap();
    let mut store = open_store(&temp);
    let (_, authorization, _) = prepared_first_sample(&mut store);
    replace_with_recoverable_pcm_caf(&authorization, 48_000);
    let final_byte_length = fs::metadata(&authorization.absolute_path).unwrap().len();

    assert!(matches!(
        store.seal_segment(seal_receipt(&authorization, final_byte_length)),
        Err(StoreError::IntegrityMismatch(
            "segment-seal sample total does not match the accepted CAF"
        ))
    ));
    assert_eq!(
        store
            .connection
            .query_row(
                "SELECT lifecycle FROM segments WHERE id = ?1",
                [&authorization.segment_id],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "capturing"
    );
    assert_eq!(
        database_value(
            &store,
            "SELECT COUNT(*) FROM session_events WHERE event_kind = 'segment_sealed'",
        ),
        0
    );
}

#[test]
fn segment_seal_and_replay_ignore_later_parallel_events() {
    let temp = TempDir::new().unwrap();
    let mut store = open_store(&temp);
    let (prepared, authorization, final_byte_length) = prepared_sealable_segment(&mut store);
    let parallel_segment = Uuid::now_v7().to_string();
    insert_parallel_database_event(
        &mut store,
        &prepared.session_id.0,
        "first_sample_captured",
        &json!({
            "segment_id": parallel_segment,
            "track_id": Uuid::now_v7().to_string(),
        }),
    );

    let receipt = seal_receipt(&authorization, final_byte_length);
    let accepted = store.seal_segment(receipt.clone()).unwrap();
    insert_parallel_database_event(
        &mut store,
        &prepared.session_id.0,
        "segment_sealed",
        &json!({ "segment_id": parallel_segment }),
    );

    assert_eq!(store.seal_segment(receipt).unwrap(), accepted);
}

#[test]
fn recovery_event_lookup_is_segment_keyed() {
    let session_id = Uuid::now_v7().to_string();
    let target_segment = Uuid::now_v7().to_string();
    let parallel_segment = Uuid::now_v7().to_string();
    let mut target = new_journal_record(&session_id, wall_time_milliseconds()).unwrap();
    target.body.event_kind = "segment_sealed".to_owned();
    target.body.payload = json!({ "segment_id": target_segment });
    let mut parallel = target.clone();
    parallel.body.sequence += 1;
    parallel.body.payload = json!({ "segment_id": parallel_segment });

    let records = [target, parallel];
    assert_eq!(
        payload_string(
            &journal_record_for_segment(&records, "segment_sealed", &target_segment)
                .unwrap()
                .unwrap()
                .body
                .payload,
            "segment_id",
        )
        .unwrap(),
        target_segment
    );
}

#[test]
fn segment_seal_interruption_recovery_converges_without_recording() {
    for (phase, expected_first) in [
        (
            MediaFailurePoint::SegmentSealJournalSync,
            RecoveryDisposition::SegmentSealProjectionRepaired,
        ),
        (
            MediaFailurePoint::SegmentSealDatabaseProjection,
            RecoveryDisposition::SegmentSealedPrepared,
        ),
    ] {
        let temp = TempDir::new().unwrap();
        let root = temp.path().join("Open Scribe");
        {
            let mut store = SessionStore::open(&root).unwrap();
            let (_, authorization, final_byte_length) = prepared_sealable_segment(&mut store);
            let error = store
                .seal_segment_inner(seal_receipt(&authorization, final_byte_length), Some(phase))
                .unwrap_err();
            assert!(matches!(error, StoreError::InjectedInterruption));
        }

        let mut reopened = SessionStore::open(&root).unwrap();
        assert_eq!(
            reopened.recover_preparations().unwrap()[0].disposition,
            expected_first
        );
        assert_eq!(
            reopened.recover_preparations().unwrap()[0].disposition,
            RecoveryDisposition::SegmentSealedPrepared
        );
        assert_eq!(
            reopened
                .connection
                .query_row(
                    "SELECT lifecycle, media_files_open FROM sessions",
                    [],
                    |row| Ok((row.get::<_, String>(0)?, row.get::<_, bool>(1)?)),
                )
                .unwrap(),
            ("preparing".to_owned(), false)
        );
    }
}

#[test]
fn sealing_one_segment_does_not_close_parallel_projection() {
    let temp = TempDir::new().unwrap();
    let mut store = open_store(&temp);
    let (prepared, authorization, final_byte_length) = prepared_sealable_segment(&mut store);
    let parallel_source = Uuid::now_v7().to_string();
    let parallel_track = Uuid::now_v7().to_string();
    let parallel_segment = Uuid::now_v7().to_string();
    store
        .connection
        .execute(
            "INSERT INTO sources (id, schema_version, session_id, kind, display_name, lifecycle)
             VALUES (?1, ?2, ?3, 'system_audio', 'Parallel fixture', 'capturing')",
            params![parallel_source, SCHEMA_VERSION, prepared.session_id.0],
        )
        .unwrap();
    store
        .connection
        .execute(
            "INSERT INTO tracks (id, schema_version, session_id, source_id, kind, lifecycle)
             VALUES (?1, ?2, ?3, ?4, 'system_audio', 'capturing')",
            params![
                parallel_track,
                SCHEMA_VERSION,
                prepared.session_id.0,
                parallel_source,
            ],
        )
        .unwrap();
    store
        .connection
        .execute(
            "INSERT INTO segments (
                id, schema_version, session_id, track_id, sequence, relative_path,
                lifecycle, mapped_start_ns, media_format, seal_state, recovery_state
             ) VALUES (?1, ?2, ?3, ?4, 0, 'audio/parallel/000000-0.caf',
                       'capturing', 0, ?5, 'open', 'not_required')",
            params![
                parallel_segment,
                SCHEMA_VERSION,
                prepared.session_id.0,
                parallel_track,
                MEDIA_FORMAT_CAF_PCM_S16LE,
            ],
        )
        .unwrap();

    store
        .seal_segment(seal_receipt(&authorization, final_byte_length))
        .unwrap();

    assert_eq!(
        store
            .connection
            .query_row(
                "SELECT sources.lifecycle, tracks.lifecycle, segments.lifecycle,
                        sessions.media_files_open
                 FROM segments
                 JOIN tracks ON tracks.id = segments.track_id
                 JOIN sources ON sources.id = tracks.source_id
                 JOIN sessions ON sessions.id = segments.session_id
                 WHERE segments.id = ?1",
                [&parallel_segment],
                |row| Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, bool>(3)?,
                )),
            )
            .unwrap(),
        (
            "capturing".to_owned(),
            "capturing".to_owned(),
            "capturing".to_owned(),
            true,
        )
    );
}

#[test]
fn first_sample_is_durable_evidence_but_never_starts_recording() {
    let temp = TempDir::new().unwrap();
    let mut store = open_store(&temp);
    let prepared = store.prepare_session(request()).unwrap();
    let authorization = store
        .authorize_media_open(media_request(prepared.session_id.clone()))
        .unwrap();
    let initial_byte_length = write_test_caf(&authorization);
    store
        .accept_media_open(media_receipt(&authorization, initial_byte_length))
        .unwrap();

    let observed_byte_length = append_first_sample(&authorization);

    let evidence = store
        .accept_first_sample(first_sample_receipt(&authorization, observed_byte_length))
        .unwrap();

    assert!(evidence.journal_durable);
    assert!(evidence.media_files_open);
    assert!(evidence.first_sample_durable);
    assert!(!evidence.recording_started);
    assert_eq!(evidence.first_sample_session_nanoseconds, 0);
    assert_eq!(evidence.last_journal_sequence, 5);
    assert_eq!(
        store
            .connection
            .query_row(
                "SELECT sample_count FROM segments WHERE id = ?1",
                [&authorization.segment_id],
                |row| row.get::<_, Option<i64>>(0),
            )
            .unwrap(),
        None
    );
    assert_eq!(
        store
            .connection
            .query_row(
                "SELECT lifecycle FROM sessions WHERE id = ?1",
                [&prepared.session_id.0],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "preparing"
    );
}

#[test]
fn first_sample_requires_open_media_and_rejects_changed_replay() {
    let temp = TempDir::new().unwrap();
    let mut store = open_store(&temp);
    let prepared = store.prepare_session(request()).unwrap();
    let authorization = store
        .authorize_media_open(media_request(prepared.session_id))
        .unwrap();
    let initial_byte_length = write_test_caf(&authorization);
    let premature = first_sample_receipt(&authorization, initial_byte_length + 1);

    assert!(matches!(
        store.accept_first_sample(premature),
        Err(StoreError::InvalidState("media-open evidence is missing"))
    ));
    store
        .accept_media_open(media_receipt(&authorization, initial_byte_length))
        .unwrap();
    let observed_byte_length = append_first_sample(&authorization);
    let receipt = first_sample_receipt(&authorization, observed_byte_length);
    let accepted = store.accept_first_sample(receipt.clone()).unwrap();
    let repeated = store.accept_first_sample(receipt.clone()).unwrap();
    assert_eq!(accepted, repeated);

    let mut changed = receipt;
    changed.first_sample_frame_count += 1;
    assert!(matches!(
        store.accept_first_sample(changed),
        Err(StoreError::IntegrityMismatch(
            "repeated first-sample receipt changed accepted evidence"
        ))
    ));
}

#[test]
fn first_sample_interruption_recovery_converges_without_recording() {
    for (phase, expected_first) in [
        (
            MediaFailurePoint::FirstSampleJournalSync,
            RecoveryDisposition::FirstSampleProjectionRepaired,
        ),
        (
            MediaFailurePoint::FirstSampleDatabaseProjection,
            RecoveryDisposition::FirstSamplePrepared,
        ),
    ] {
        let temp = TempDir::new().unwrap();
        let root = temp.path().join("Open Scribe");
        {
            let mut store = SessionStore::open(&root).unwrap();
            let prepared = store.prepare_session(request()).unwrap();
            let authorization = store
                .authorize_media_open(media_request(prepared.session_id))
                .unwrap();
            let initial_byte_length = write_test_caf(&authorization);
            store
                .accept_media_open(media_receipt(&authorization, initial_byte_length))
                .unwrap();
            let observed_byte_length = append_first_sample(&authorization);
            let error = store
                .accept_first_sample_inner(
                    first_sample_receipt(&authorization, observed_byte_length),
                    Some(phase),
                )
                .unwrap_err();
            assert!(matches!(error, StoreError::InjectedInterruption));
        }

        let mut reopened = SessionStore::open(&root).unwrap();
        let first = reopened.recover_preparations().unwrap().remove(0);
        assert_eq!(first.disposition, expected_first);
        let second = reopened.recover_preparations().unwrap().remove(0);
        assert_eq!(second.disposition, RecoveryDisposition::FirstSamplePrepared);
        assert_eq!(
            reopened
                .connection
                .query_row("SELECT lifecycle FROM sessions", [], |row| row
                    .get::<_, String>(0))
                .unwrap(),
            "preparing"
        );
    }
}

#[test]
fn media_open_requires_rust_authority_and_never_starts_recording() {
    let temp = TempDir::new().unwrap();
    let mut store = open_store(&temp);
    let prepared = store.prepare_session(request()).unwrap();
    let authorization = store
        .authorize_media_open(media_request(prepared.session_id.clone()))
        .unwrap();

    assert!(!authorization.absolute_path.exists());
    assert!(authorization.relative_path.starts_with("audio/"));
    assert_eq!(authorization.media_format, MEDIA_FORMAT_CAF_PCM_S16LE);
    assert_eq!(authorization.sample_rate_hz, MEDIA_SAMPLE_RATE_HZ);
    let byte_length = write_test_caf(&authorization);
    let evidence = store
        .accept_media_open(media_receipt(&authorization, byte_length))
        .unwrap();

    assert!(evidence.journal_durable);
    assert!(evidence.media_files_open);
    assert!(!evidence.recording_started);
    assert_eq!(evidence.last_journal_sequence, 4);
    let lifecycle: String = store
        .connection
        .query_row(
            "SELECT lifecycle FROM sessions WHERE id = ?1",
            [&prepared.session_id.0],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(lifecycle, "preparing");

    let repeated = store
        .accept_media_open(media_receipt(&authorization, byte_length))
        .unwrap();
    assert_eq!(repeated.last_journal_sequence, 4);
}

#[test]
fn idempotent_media_receipt_revalidates_the_accepted_file() {
    let temp = TempDir::new().unwrap();
    let mut store = open_store(&temp);
    let prepared = store.prepare_session(request()).unwrap();
    let authorization = store
        .authorize_media_open(media_request(prepared.session_id))
        .unwrap();
    let byte_length = write_test_caf(&authorization);
    let receipt = media_receipt(&authorization, byte_length);
    store.accept_media_open(receipt.clone()).unwrap();

    let mut retained_writer = OpenOptions::new()
        .append(true)
        .open(&authorization.absolute_path)
        .unwrap();
    retained_writer.write_all(b"more-media").unwrap();
    retained_writer.sync_all().unwrap();
    let grown = store.accept_media_open(receipt.clone()).unwrap();
    assert!(grown.media_files_open);
    assert_eq!(grown.last_journal_sequence, 4);

    let replacement_path = authorization.absolute_path.with_extension("replacement");
    let mut replacement = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&replacement_path)
        .unwrap();
    replacement
        .write_all(b"caff\0\x01\0\0deterministic-test-media")
        .unwrap();
    replacement.sync_all().unwrap();

    fs::remove_file(&authorization.absolute_path).unwrap();
    assert!(matches!(
        store.accept_media_open(receipt.clone()),
        Err(StoreError::IntegrityMismatch(
            "accepted media file is missing"
        ))
    ));

    fs::rename(&replacement_path, &authorization.absolute_path).unwrap();
    assert!(matches!(
        store.accept_media_open(receipt),
        Err(StoreError::IntegrityMismatch(
            "accepted media file identity changed"
        ))
    ));
}

#[test]
fn stale_foreign_and_symlinked_media_receipts_are_rejected() {
    let temp = TempDir::new().unwrap();
    let mut store = open_store(&temp);
    let prepared = store.prepare_session(request()).unwrap();
    let authorization = store
        .authorize_media_open(media_request(prepared.session_id))
        .unwrap();
    let byte_length = write_test_caf(&authorization);

    let mut stale = media_receipt(&authorization, byte_length);
    stale.open_token = Uuid::now_v7().to_string();
    assert!(matches!(
        store.accept_media_open(stale),
        Err(StoreError::IntegrityMismatch(_))
    ));

    fs::remove_file(&authorization.absolute_path).unwrap();
    let outside = temp.path().join("outside.caf");
    fs::write(&outside, b"caff-outside").unwrap();
    symlink(&outside, &authorization.absolute_path).unwrap();
    assert!(matches!(
        store.accept_media_open(media_receipt(
            &authorization,
            fs::metadata(&outside).unwrap().len(),
        )),
        Err(StoreError::IntegrityMismatch(_))
    ));

    let mut traversal = media_receipt(&authorization, byte_length);
    traversal.relative_path = "audio/../outside.caf".to_owned();
    assert!(matches!(
        store.accept_media_open(traversal),
        Err(StoreError::InvalidRequest(_))
    ));
}

fn assert_intermediate_media_symlink_is_rejected(replace_audio_directory: bool) {
    let temp = TempDir::new().unwrap();
    let mut store = open_store(&temp);
    let prepared = store.prepare_session(request()).unwrap();
    let authorization = store
        .authorize_media_open(media_request(prepared.session_id))
        .unwrap();
    let track_directory = authorization.absolute_path.parent().unwrap().to_path_buf();
    let audio_directory = track_directory.parent().unwrap().to_path_buf();
    let session_directory = audio_directory.parent().unwrap().to_path_buf();
    let original = if replace_audio_directory {
        audio_directory
    } else {
        track_directory
    };
    let escaped = temp.path().join(if replace_audio_directory {
        "escaped-audio"
    } else {
        "escaped-track"
    });
    fs::rename(&original, &escaped).unwrap();
    symlink(&escaped, &original).unwrap();

    let byte_length = write_test_caf(&authorization);
    let resolved_media = fs::canonicalize(&authorization.absolute_path).unwrap();
    assert!(!resolved_media.starts_with(&session_directory));
    assert!(matches!(
        store.accept_media_open(media_receipt(&authorization, byte_length)),
        Err(StoreError::IntegrityMismatch(_))
    ));
    assert_eq!(
        database_value(&store, "SELECT media_files_open FROM sessions"),
        0
    );
}

#[test]
fn intermediate_audio_symlink_cannot_escape_the_session() {
    assert_intermediate_media_symlink_is_rejected(true);
}

#[test]
fn intermediate_track_symlink_cannot_escape_the_session() {
    assert_intermediate_media_symlink_is_rejected(false);
}

#[test]
fn media_interruption_phases_recover_without_recording_claims() {
    for phase in [
        MediaFailurePoint::AuthorizationJournalSync,
        MediaFailurePoint::AuthorizationDatabaseProjection,
    ] {
        let temp = TempDir::new().unwrap();
        let root = temp.path().join("Open Scribe");
        {
            let mut store = SessionStore::open(&root).unwrap();
            let prepared = store.prepare_session(request()).unwrap();
            let error = store
                .authorize_media_open_inner(media_request(prepared.session_id), Some(phase))
                .unwrap_err();
            assert!(matches!(error, StoreError::InjectedInterruption));
        }
        let mut reopened = SessionStore::open(&root).unwrap();
        let finding = reopened.recover_preparations().unwrap().remove(0);
        assert_eq!(finding.disposition, RecoveryDisposition::MissingMediaFile);
        assert_eq!(
            database_value(&reopened, "SELECT media_files_open FROM sessions"),
            0
        );
        assert_eq!(
            reopened
                .connection
                .query_row("SELECT lifecycle FROM sessions", [], |row| row
                    .get::<_, String>(0))
                .unwrap(),
            "preparing"
        );
    }

    for (phase, expected_first) in [
        (
            MediaFailurePoint::ReceiptJournalSync,
            RecoveryDisposition::MediaOpenProjectionRepaired,
        ),
        (
            MediaFailurePoint::ReceiptDatabaseProjection,
            RecoveryDisposition::MediaOpenPrepared,
        ),
    ] {
        let temp = TempDir::new().unwrap();
        let root = temp.path().join("Open Scribe");
        {
            let mut store = SessionStore::open(&root).unwrap();
            let prepared = store.prepare_session(request()).unwrap();
            let authorization = store
                .authorize_media_open(media_request(prepared.session_id))
                .unwrap();
            let byte_length = write_test_caf(&authorization);
            let error = store
                .accept_media_open_inner(media_receipt(&authorization, byte_length), Some(phase))
                .unwrap_err();
            assert!(matches!(error, StoreError::InjectedInterruption));
        }
        let mut reopened = SessionStore::open(&root).unwrap();
        let first = reopened.recover_preparations().unwrap().remove(0);
        assert_eq!(first.disposition, expected_first);
        let second = reopened.recover_preparations().unwrap().remove(0);
        assert_eq!(second.disposition, RecoveryDisposition::MediaOpenPrepared);
        assert_eq!(
            database_value(&reopened, "SELECT media_files_open FROM sessions"),
            1
        );
        assert_eq!(
            reopened
                .connection
                .query_row("SELECT lifecycle FROM sessions", [], |row| row
                    .get::<_, String>(0))
                .unwrap(),
            "preparing"
        );
    }
}

#[test]
fn valid_unaccepted_media_remains_awaiting_receipt() {
    let temp = TempDir::new().unwrap();
    let mut store = open_store(&temp);
    let prepared = store.prepare_session(request()).unwrap();
    let authorization = store
        .authorize_media_open(media_request(prepared.session_id))
        .unwrap();
    write_test_caf(&authorization);

    let finding = store.recover_preparations().unwrap().remove(0);
    assert_eq!(
        finding.disposition,
        RecoveryDisposition::MediaOpenAwaitingReceipt
    );
    assert_eq!(
        database_value(&store, "SELECT media_files_open FROM sessions"),
        0
    );
}

#[test]
fn recovery_rejects_replaced_media_after_journal_acceptance() {
    let temp = TempDir::new().unwrap();
    let root = temp.path().join("Open Scribe");
    let authorization;
    {
        let mut store = SessionStore::open(&root).unwrap();
        let prepared = store.prepare_session(request()).unwrap();
        authorization = store
            .authorize_media_open(media_request(prepared.session_id))
            .unwrap();
        let byte_length = write_test_caf(&authorization);
        let error = store
            .accept_media_open_inner(
                media_receipt(&authorization, byte_length),
                Some(MediaFailurePoint::ReceiptJournalSync),
            )
            .unwrap_err();
        assert!(matches!(error, StoreError::InjectedInterruption));
    }

    fs::remove_file(&authorization.absolute_path).unwrap();
    write_test_caf(&authorization);
    let mut reopened = SessionStore::open(&root).unwrap();
    let finding = reopened.recover_preparations().unwrap().remove(0);
    assert_eq!(finding.disposition, RecoveryDisposition::InvalidMediaFile);
    assert_eq!(
        database_value(&reopened, "SELECT media_files_open FROM sessions"),
        0
    );
}

#[test]
fn recovery_accepts_growth_of_the_same_media_identity() {
    let temp = TempDir::new().unwrap();
    let root = temp.path().join("Open Scribe");
    {
        let mut store = SessionStore::open(&root).unwrap();
        let prepared = store.prepare_session(request()).unwrap();
        let authorization = store
            .authorize_media_open(media_request(prepared.session_id))
            .unwrap();
        let byte_length = write_test_caf(&authorization);
        store
            .accept_media_open(media_receipt(&authorization, byte_length))
            .unwrap();
        let mut retained_writer = OpenOptions::new()
            .append(true)
            .open(&authorization.absolute_path)
            .unwrap();
        retained_writer.write_all(b"more-media").unwrap();
        retained_writer.sync_all().unwrap();
    }

    let mut reopened = SessionStore::open(&root).unwrap();
    let finding = reopened.recover_preparations().unwrap().remove(0);
    assert_eq!(finding.disposition, RecoveryDisposition::MediaOpenPrepared);
    assert_eq!(
        database_value(&reopened, "SELECT media_files_open FROM sessions"),
        1
    );
}

#[test]
fn interrupted_first_sample_is_durable_discoverable_and_media_preserving() {
    let temp = TempDir::new().unwrap();
    let root = temp.path().join("Open Scribe");
    let session_id;
    let media_path;
    let media_before;
    {
        let mut store = SessionStore::open(&root).unwrap();
        let (prepared, authorization, _) = prepared_first_sample(&mut store);
        session_id = prepared.session_id;
        media_path = authorization.absolute_path;
        media_before = fs::read(&media_path).unwrap();

        let evidence = store
            .interrupt_session(InterruptSessionRequest {
                session_id: session_id.clone(),
                reason: SessionInterruptionReason::CaptureFailed,
            })
            .unwrap();

        assert!(evidence.journal_durable);
        assert!(evidence.session_interrupted);
        assert!(!evidence.recording_started);
        assert_eq!(evidence.last_journal_sequence, 6);
        assert_eq!(fs::read(&media_path).unwrap(), media_before);
    }

    let mut reopened = SessionStore::open(&root).unwrap();
    let finding = reopened.recover_preparations().unwrap().remove(0);
    assert_eq!(
        finding.disposition,
        RecoveryDisposition::InterruptedFirstSample
    );
    assert_eq!(
        reopened
            .connection
            .query_row(
                "SELECT lifecycle FROM sessions WHERE id = ?1",
                [&session_id.0],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "interrupted"
    );
    assert_eq!(fs::read(media_path).unwrap(), media_before);
}

#[test]
fn interruption_replay_is_idempotent_and_rejects_a_changed_reason() {
    let temp = TempDir::new().unwrap();
    let mut store = open_store(&temp);
    let (prepared, _, _) = prepared_first_sample(&mut store);
    let request = InterruptSessionRequest {
        session_id: prepared.session_id,
        reason: SessionInterruptionReason::CaptureFailed,
    };

    let accepted = store.interrupt_session(request.clone()).unwrap();
    let repeated = store.interrupt_session(request.clone()).unwrap();
    assert_eq!(accepted, repeated);

    let changed = InterruptSessionRequest {
        session_id: request.session_id,
        reason: SessionInterruptionReason::FirstSampleRejected,
    };
    assert!(matches!(
        store.interrupt_session(changed),
        Err(StoreError::IntegrityMismatch(
            "repeated interruption changed accepted evidence"
        ))
    ));
}

#[test]
fn restart_repairs_journaled_interruption_projection_without_touching_media() {
    let temp = TempDir::new().unwrap();
    let root = temp.path().join("Open Scribe");
    let session_id;
    let media_path;
    let media_before;
    {
        let mut store = SessionStore::open(&root).unwrap();
        let (prepared, authorization, _) = prepared_first_sample(&mut store);
        session_id = prepared.session_id;
        media_path = authorization.absolute_path;
        media_before = fs::read(&media_path).unwrap();
        store
            .append_session_journal(
                &session_id.0,
                "session_interrupted",
                None,
                json!({ "reason": "capture_failed" }),
            )
            .unwrap();
    }

    let mut reopened = SessionStore::open(&root).unwrap();
    let first = reopened.recover_preparations().unwrap().remove(0);
    assert_eq!(
        first.disposition,
        RecoveryDisposition::InterruptionProjectionRepaired
    );
    let second = reopened.recover_preparations().unwrap().remove(0);
    assert_eq!(
        second.disposition,
        RecoveryDisposition::InterruptedFirstSample
    );
    assert_eq!(fs::read(media_path).unwrap(), media_before);
}

#[test]
fn direct_retry_repairs_journaled_interruption_and_rejects_changed_reason() {
    let temp = TempDir::new().unwrap();
    let mut store = open_store(&temp);
    let (prepared, _, _) = prepared_first_sample(&mut store);
    store
        .append_session_journal(
            &prepared.session_id.0,
            "session_interrupted",
            None,
            json!({ "reason": "capture_failed" }),
        )
        .unwrap();

    let changed = store.interrupt_session(InterruptSessionRequest {
        session_id: prepared.session_id.clone(),
        reason: SessionInterruptionReason::FirstSampleRejected,
    });
    assert!(matches!(
        changed,
        Err(StoreError::IntegrityMismatch(
            "repeated interruption changed accepted evidence"
        ))
    ));

    let repaired = store
        .interrupt_session(InterruptSessionRequest {
            session_id: prepared.session_id.clone(),
            reason: SessionInterruptionReason::CaptureFailed,
        })
        .unwrap();
    assert!(repaired.journal_durable);
    assert!(repaired.session_interrupted);
    assert!(!repaired.recording_started);
    assert_eq!(repaired.last_journal_sequence, 6);
    assert_eq!(
        store
            .connection
            .query_row(
                "SELECT lifecycle FROM sessions WHERE id = ?1",
                [&prepared.session_id.0],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "interrupted"
    );

    let replayed = store
        .interrupt_session(InterruptSessionRequest {
            session_id: prepared.session_id,
            reason: SessionInterruptionReason::CaptureFailed,
        })
        .unwrap();
    assert_eq!(repaired, replayed);
}

#[test]
fn forced_exit_recovery_preserves_caf_and_converges_to_ready_for_review() {
    let temp = TempDir::new().unwrap();
    let root = temp.path().join("Open Scribe");
    let session_id;
    let media_path;
    let media_before;
    {
        let mut store = SessionStore::open(&root).unwrap();
        let (prepared, authorization, _) = prepared_first_sample(&mut store);
        session_id = prepared.session_id;
        replace_with_recoverable_pcm_caf(&authorization, 48_000);
        media_path = authorization.absolute_path;
        media_before = fs::read(&media_path).unwrap();
    }

    let mut reopened = SessionStore::open(&root).unwrap();
    let recovered = reopened.recover_playable_sessions().unwrap();
    assert_eq!(recovered.len(), 1);
    assert_eq!(recovered[0].session_id, session_id);
    assert_eq!(recovered[0].sample_count, 48_000);
    assert_eq!(recovered[0].duration_nanoseconds, 1_000_000_000);
    assert!(recovered[0].media_preserved);
    assert!(recovered[0].ready_for_review);
    assert!(!recovered[0].recording_started);
    assert_eq!(fs::read(&media_path).unwrap(), media_before);
    let repeated = reopened.recover_playable_sessions().unwrap();
    assert_eq!(repeated.len(), 1);
    assert_eq!(repeated[0].session_id, session_id);
    assert_eq!(
        reopened
            .connection
            .query_row(
                "SELECT lifecycle FROM sessions WHERE id = ?1",
                [&session_id.0],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "ready_for_review"
    );
    let healthy = reopened
        .runtime_library_snapshot()
        .unwrap()
        .saved_sessions
        .remove(0);
    assert_eq!(healthy.health, "healthy");
    assert!(healthy.interruption_reason.is_none());
    assert_eq!(healthy.elapsed_seconds, 1);
    assert!(healthy.recovered);
    assert!(healthy.playable_media.is_none());
    assert_eq!(
        reopened
            .connection
            .query_row(
                "SELECT recovery_state FROM segments WHERE session_id = ?1",
                [&session_id.0],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "recovered"
    );
    assert_eq!(
        database_value(
            &reopened,
            "SELECT COUNT(*) FROM recovery_runs WHERE disposition = 'playable_media_recovered'",
        ),
        1
    );
}

#[test]
fn dual_source_recovery_projects_both_tracks_atomically_and_idempotently() {
    let temp = TempDir::new().unwrap();
    let root = temp.path().join("Open Scribe");
    let session_id;
    let microphone_path;
    let system_path;
    let microphone_bytes;
    let system_bytes;
    {
        let mut store = SessionStore::open(&root).unwrap();
        let (prepared, microphone, system) = prepared_dual_first_samples(&mut store);
        session_id = prepared.session_id.clone();
        replace_with_recoverable_pcm_caf(&microphone, 48_000);
        replace_with_recoverable_pcm_caf(&system, 240_000);
        microphone_path = microphone.absolute_path.clone();
        system_path = system.absolute_path.clone();
        microphone_bytes = fs::read(&microphone_path).unwrap();
        system_bytes = fs::read(&system_path).unwrap();
        store.confirm_recording(session_id.clone()).unwrap();
        store
            .interrupt_session(InterruptSessionRequest {
                session_id: session_id.clone(),
                reason: SessionInterruptionReason::CaptureFailed,
            })
            .unwrap();
    }

    let mut reopened = SessionStore::open(&root).unwrap();
    let recovered = reopened.recover_playable_sessions().unwrap();
    assert_eq!(recovered.len(), 2);
    assert!(recovered.iter().all(|item| item.session_id == session_id));
    assert_eq!(recovered[0].source_kind, MediaSourceKind::Microphone);
    assert_eq!(recovered[0].source_display_name, "Mac microphone");
    assert_eq!(recovered[1].source_kind, MediaSourceKind::SystemAudio);
    assert_eq!(recovered[1].source_display_name, "Mac system audio");
    assert_ne!(recovered[0].source_id, recovered[1].source_id);
    assert_ne!(recovered[0].track_id, recovered[1].track_id);
    assert_eq!(
        recovered
            .iter()
            .map(|item| item.sample_count)
            .collect::<Vec<_>>(),
        [48_000, 240_000]
    );
    assert_eq!(
        database_value(
            &reopened,
            "SELECT COUNT(*) FROM segments WHERE lifecycle = 'sealed' AND recovery_state = 'recovered'",
        ),
        2
    );
    assert_eq!(
        database_value(
            &reopened,
            "SELECT COUNT(*) FROM required_sources WHERE lifecycle = 'sealed'",
        ),
        2
    );
    assert_eq!(
        database_value(
            &reopened,
            "SELECT COUNT(*) FROM sessions WHERE lifecycle = 'ready_for_review'",
        ),
        1
    );
    assert_eq!(fs::read(&microphone_path).unwrap(), microphone_bytes);
    assert_eq!(fs::read(&system_path).unwrap(), system_bytes);

    let recovered_snapshot = reopened
        .runtime_library_snapshot()
        .unwrap()
        .saved_sessions
        .remove(0);
    assert_eq!(recovered_snapshot.health, "degraded");
    assert_eq!(
        recovered_snapshot.interruption_reason,
        Some(SessionInterruptionReason::CaptureFailed)
    );
    reopened
        .connection
        .execute(
            "UPDATE sessions SET health = 'healthy' WHERE id = ?1",
            [&session_id.0],
        )
        .unwrap();
    let legacy_health_snapshot = reopened
        .runtime_library_snapshot()
        .unwrap()
        .saved_sessions
        .remove(0);
    assert_eq!(legacy_health_snapshot.health, "degraded");
    let interrupted_at_ms = reopened
        .connection
        .query_row(
            "SELECT wall_time_ms FROM session_events
             WHERE session_id = ?1 AND event_kind = 'session_interrupted'",
            [&session_id.0],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    reopened
        .connection
        .execute(
            "UPDATE sessions SET updated_at_ms = ?2 WHERE id = ?1",
            params![&session_id.0, interrupted_at_ms + 60_000],
        )
        .unwrap();
    let duration_snapshot = reopened
        .runtime_library_snapshot()
        .unwrap()
        .saved_sessions
        .remove(0);
    assert_eq!(duration_snapshot.elapsed_seconds, 5);

    let repeated = reopened.recover_playable_sessions().unwrap();
    assert_eq!(repeated.len(), 2);
    assert_eq!(
        database_value(
            &reopened,
            "SELECT COUNT(*) FROM recovery_runs WHERE disposition = 'playable_media_recovered'",
        ),
        1
    );
}

#[test]
fn dual_source_recovery_refuses_partial_projection_when_one_track_is_invalid() {
    let temp = TempDir::new().unwrap();
    let root = temp.path().join("Open Scribe");
    let microphone_path;
    let microphone_bytes;
    {
        let mut store = SessionStore::open(&root).unwrap();
        let (prepared, microphone, _) = prepared_dual_first_samples(&mut store);
        replace_with_recoverable_pcm_caf(&microphone, 4_800);
        microphone_path = microphone.absolute_path.clone();
        microphone_bytes = fs::read(&microphone_path).unwrap();
        store
            .confirm_recording(prepared.session_id.clone())
            .unwrap();
        store
            .interrupt_session(InterruptSessionRequest {
                session_id: prepared.session_id,
                reason: SessionInterruptionReason::CaptureFailed,
            })
            .unwrap();
    }

    let mut reopened = SessionStore::open(&root).unwrap();
    assert!(reopened.recover_playable_sessions().unwrap().is_empty());
    assert_eq!(
        database_value(
            &reopened,
            "SELECT COUNT(*) FROM segments WHERE lifecycle = 'capturing'",
        ),
        2
    );
    assert_eq!(
        database_value(
            &reopened,
            "SELECT COUNT(*) FROM session_events WHERE event_kind = 'playable_media_recovered'",
        ),
        0
    );
    assert_eq!(
        database_value(
            &reopened,
            "SELECT COUNT(*) FROM sessions WHERE lifecycle = 'interrupted'",
        ),
        1
    );
    assert_eq!(fs::read(microphone_path).unwrap(), microphone_bytes);
}

#[test]
fn recovery_returns_normally_sealed_companion_with_recovered_track() {
    let temp = TempDir::new().unwrap();
    let root = temp.path().join("Open Scribe");
    let microphone_path;
    let system_path;
    let microphone_bytes;
    let system_bytes;
    {
        let mut store = SessionStore::open(&root).unwrap();
        let (prepared, microphone, system) = prepared_dual_first_samples(&mut store);
        replace_with_recoverable_pcm_caf(&microphone, 240_000);
        replace_with_recoverable_pcm_caf(&system, 48_000);
        microphone_path = microphone.absolute_path.clone();
        system_path = system.absolute_path.clone();
        microphone_bytes = fs::read(&microphone_path).unwrap();
        system_bytes = fs::read(&system_path).unwrap();
        store
            .confirm_recording(prepared.session_id.clone())
            .unwrap();
        let mut microphone_seal = seal_receipt(&microphone, microphone_bytes.len() as u64);
        microphone_seal.sample_count = 240_000;
        store.seal_segment(microphone_seal).unwrap();
        store
            .interrupt_session(InterruptSessionRequest {
                session_id: prepared.session_id,
                reason: SessionInterruptionReason::SegmentSealFailed,
            })
            .unwrap();
    }

    let mut reopened = SessionStore::open(&root).unwrap();
    let recovered = reopened.recover_playable_sessions().unwrap();
    assert_eq!(recovered.len(), 2);
    assert_eq!(
        database_value(
            &reopened,
            "SELECT COUNT(*) FROM segments WHERE lifecycle = 'sealed'",
        ),
        2
    );
    assert_eq!(
        database_value(
            &reopened,
            "SELECT COUNT(*) FROM segments WHERE recovery_state = 'recovered'",
        ),
        1
    );
    assert_eq!(fs::read(&microphone_path).unwrap(), microphone_bytes);
    assert_eq!(fs::read(&system_path).unwrap(), system_bytes);
    let snapshot = reopened
        .runtime_library_snapshot()
        .unwrap()
        .saved_sessions
        .remove(0);
    assert_eq!(snapshot.elapsed_seconds, 5);
    assert_eq!(reopened.recover_playable_sessions().unwrap().len(), 2);
}

#[test]
fn changed_sealed_companion_cannot_commit_recovery_readiness() {
    let temp = TempDir::new().unwrap();
    let root = temp.path().join("Open Scribe");
    let session_id;
    let microphone_path;
    {
        let mut store = SessionStore::open(&root).unwrap();
        let (prepared, microphone, system) = prepared_dual_first_samples(&mut store);
        session_id = prepared.session_id.clone();
        replace_with_recoverable_pcm_caf(&microphone, 240_000);
        replace_with_recoverable_pcm_caf(&system, 48_000);
        microphone_path = microphone.absolute_path.clone();
        store.confirm_recording(session_id.clone()).unwrap();
        let microphone_bytes = fs::metadata(&microphone_path).unwrap().len();
        let mut microphone_seal = seal_receipt(&microphone, microphone_bytes);
        microphone_seal.sample_count = 240_000;
        store.seal_segment(microphone_seal).unwrap();
        store
            .interrupt_session(InterruptSessionRequest {
                session_id: session_id.clone(),
                reason: SessionInterruptionReason::SegmentSealFailed,
            })
            .unwrap();
    }
    OpenOptions::new()
        .append(true)
        .open(&microphone_path)
        .unwrap()
        .write_all(b"changed-after-seal")
        .unwrap();

    let mut reopened = SessionStore::open(&root).unwrap();
    let recovery = reopened.recover_library().unwrap();
    assert_eq!(
        recovery
            .findings
            .iter()
            .find(|finding| finding.session_id == session_id)
            .map(|finding| finding.disposition),
        Some(RecoveryDisposition::IntegrityMismatch),
        "the changed companion is the session's own finding"
    );
    assert!(recovery.playable.is_empty());
    assert_eq!(
        reopened
            .connection
            .query_row(
                "SELECT lifecycle FROM sessions WHERE id = ?1",
                [&session_id.0],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "interrupted"
    );
    assert_eq!(
        database_value(
            &reopened,
            "SELECT COUNT(*) FROM recovery_runs WHERE disposition = 'playable_media_recovered'",
        ),
        0
    );
    assert_eq!(
        database_value(
            &reopened,
            "SELECT COUNT(*) FROM session_events WHERE event_kind = 'playable_media_recovered'",
        ),
        0
    );
}

#[test]
fn forced_exit_recovery_repairs_a_journal_first_projection_interruption() {
    let temp = TempDir::new().unwrap();
    let root = temp.path().join("Open Scribe");
    let session_id;
    {
        let mut store = SessionStore::open(&root).unwrap();
        let (prepared, authorization, observed_byte_length) = prepared_first_sample(&mut store);
        session_id = prepared.session_id;
        replace_with_recoverable_pcm_caf(&authorization, 2_400);
        let validated = store
            .validate_media_file(
                &session_id.0,
                &authorization.relative_path,
                MediaLengthRequirement::AtLeast(observed_byte_length),
                true,
            )
            .unwrap();
        let payload = json!({
            "source_id": authorization.source_id,
            "track_id": authorization.track_id,
            "segment_id": authorization.segment_id,
            "relative_path": authorization.relative_path,
            "sample_count": validated.recoverable_sample_count.unwrap(),
            "final_byte_length": validated.byte_length,
            "digest_sha256": validated.digest_sha256.unwrap(),
            "file_device": validated.device,
            "file_inode": validated.inode,
            "truncated_bytes": 0,
        });
        store
            .append_session_journal(
                &session_id.0,
                "playable_media_recovered",
                Some(&authorization.relative_path),
                payload,
            )
            .unwrap();
    }

    let mut reopened = SessionStore::open(&root).unwrap();
    let recovered = reopened.recover_playable_sessions().unwrap();
    assert_eq!(recovered.len(), 1);
    assert_eq!(recovered[0].session_id, session_id);
    assert_eq!(recovered[0].sample_count, 2_400);
    let repeated = reopened.recover_playable_sessions().unwrap();
    assert_eq!(repeated.len(), 1);
    assert_eq!(repeated[0].session_id, session_id);
    assert_eq!(
        database_value(
            &reopened,
            "SELECT COUNT(*) FROM recovery_runs WHERE disposition = 'playable_media_recovered'",
        ),
        1
    );
}

#[test]
fn forced_exit_recovery_refuses_unparseable_media_without_mutation() {
    let temp = TempDir::new().unwrap();
    let root = temp.path().join("Open Scribe");
    let media_path;
    let media_before;
    {
        let mut store = SessionStore::open(&root).unwrap();
        let (_, authorization, _) = prepared_first_sample(&mut store);
        media_path = authorization.absolute_path;
        media_before = fs::read(&media_path).unwrap();
    }

    let mut reopened = SessionStore::open(&root).unwrap();
    assert!(reopened.recover_playable_sessions().unwrap().is_empty());
    assert_eq!(fs::read(media_path).unwrap(), media_before);
    assert_eq!(
        database_value(
            &reopened,
            "SELECT COUNT(*) FROM sessions WHERE lifecycle = 'preparing'",
        ),
        1
    );
}
