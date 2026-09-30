use super::*;
use open_scribe_evidence::ResolutionState;

fn display(id: &str, name: &str, x: f64) -> DisplayTopology {
    DisplayTopology {
        display_id: id.into(),
        name: name.into(),
        x,
        y: 0.0,
        width: 1512.0,
        height: 982.0,
        scale: 2.0,
        rotation: 0.0,
        is_main: x == 0.0,
    }
}

fn window_scope() -> ContextScopeRequest {
    ContextScopeRequest {
        mode: ContextMode::WatchWindow,
        targets: vec![ContextTarget {
            kind: ContextTargetKind::Window,
            platform_id: "4242".into(),
            name: "Quarterly plan".into(),
            application: Some("Preview".into()),
            description: "Preview — Quarterly plan, on Built-in Display".into(),
        }],
        bounds: None,
        topology: vec![
            display("1", "Built-in Display", 0.0),
            display("2", "Studio Display", 1512.0),
        ],
        exclusions: vec!["open_scribe".into(), "notifications".into()],
        permission: ScreenPermission::Granted,
        retention: ContextRetention::NoPixels,
    }
}

fn proposal(scope: &ContextScope, host: u64, lines: &[&str]) -> ContextProposal {
    ContextProposal {
        scope_id: scope.scope_id.clone(),
        epoch: scope.epoch,
        reason: ContextEventReason::FixedScopeChange,
        start_host_time: host,
        end_host_time: host + 1_000,
        observed_at_ms: 1_700_000_000_000,
        source: ContextSource {
            platform_id: "4242".into(),
            name: "Quarterly plan".into(),
            application: Some("Preview".into()),
        },
        bounds: None,
        reducer_revision: "luma-160x90-v1".into(),
        vision_revision: "vision-accurate-3".into(),
        languages: vec!["en-US".into()],
        blocks: lines
            .iter()
            .enumerate()
            .map(|(index, text)| ContextTextBlock {
                text: (*text).into(),
                x: 0.1,
                y: 0.1 + index as f64 * 0.1,
                width: 0.5,
                height: 0.05,
            })
            .collect(),
    }
}

fn authorize(store: &mut SessionStore, session: &SessionId) -> ContextScope {
    store
        .context_action(session.clone(), ContextAction::Authorize(window_scope()))
        .unwrap()
        .current()
        .cloned()
        .unwrap()
}

fn accepted(decision: ContextDecision) -> AcceptedContextEvent {
    match decision {
        ContextDecision::Accepted(event) => event,
        ContextDecision::Rejected(reason) => panic!("rejected: {reason:?}"),
    }
}

#[test]
fn a_scope_is_explicit_bounded_and_honest_about_permission() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, _) = recording_pair(&mut store);
    assert!(store.context_detail(&session).unwrap().scopes.is_empty());

    let mut denied = window_scope();
    denied.permission = ScreenPermission::Denied;
    assert!(matches!(
        store.context_action(session.clone(), ContextAction::Authorize(denied)),
        Err(StoreError::InvalidState(_))
    ));
    let mut retained = window_scope();
    retained.retention = ContextRetention::MeaningfulSnapshots;
    let mut unexcluded = window_scope();
    unexcluded.exclusions = vec!["dock".into()];
    let mut mismatched = window_scope();
    mismatched.mode = ContextMode::WatchDisplay;
    let mut region = window_scope();
    region.mode = ContextMode::WatchRegion;
    region.targets[0].kind = ContextTargetKind::Display;
    region.targets[0].platform_id = "2".into();
    region.bounds = Some(ContextBounds {
        display_id: "2".into(),
        x: 0.6,
        y: 0.0,
        width: 0.5,
        height: 0.5,
    });
    let mut ghost = window_scope();
    ghost.mode = ContextMode::WatchDisplay;
    ghost.targets[0].kind = ContextTargetKind::Display;
    ghost.targets[0].platform_id = "9".into();
    for request in [retained, unexcluded, mismatched, region, ghost] {
        assert!(matches!(
            store.context_action(session.clone(), ContextAction::Authorize(request)),
            Err(StoreError::InvalidRequest(_))
        ));
    }
    // Nothing was journaled for any refused request.
    assert!(
        !journal_records(&store, &session)
            .iter()
            .any(|record| record.body.event_kind.starts_with("context_"))
    );

    let scope = authorize(&mut store, &session);
    assert_eq!(
        (scope.epoch, scope.condition),
        (1, ContextCondition::Active)
    );
    assert_eq!(scope.request, window_scope());
}

#[test]
fn only_the_current_active_epoch_accepts_and_revocation_wins_the_race() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, _) = recording_pair(&mut store);
    let first = authorize(&mut store, &session);
    let event = accepted(
        store
            .propose_context_event(
                session.clone(),
                proposal(&first, 100_000_001, &["Revenue  up\t4%"]),
            )
            .unwrap(),
    );
    assert_eq!(event.start_ns, 100_000_000);

    // Queued under epoch 1, delivered after a pause: refused.
    let queued = proposal(&first, 200_000_001, &["Headcount flat"]);
    store
        .context_action(
            session.clone(),
            ContextAction::Pause(ContextPauseReason::User),
        )
        .unwrap();
    assert_eq!(
        store
            .propose_context_event(session.clone(), queued.clone())
            .unwrap(),
        ContextDecision::Rejected(ContextRejection::Paused)
    );
    // Resuming issues epoch 2; epoch 1 work stays stale forever.
    let detail = store
        .context_action(
            session.clone(),
            ContextAction::Resume {
                permission: ScreenPermission::Granted,
            },
        )
        .unwrap();
    let second = detail.current().cloned().unwrap();
    assert_eq!(second.epoch, 2);
    assert_eq!(detail.scopes[0].condition, ContextCondition::Superseded);
    assert_eq!(
        store
            .propose_context_event(session.clone(), queued)
            .unwrap(),
        ContextDecision::Rejected(ContextRejection::StaleEpoch)
    );
    accepted(
        store
            .propose_context_event(
                session.clone(),
                proposal(&second, 300_000_001, &["Headcount flat"]),
            )
            .unwrap(),
    );

    // Revocation: work already in flight for epoch 2 cannot land.
    let in_flight = proposal(&second, 400_000_001, &["Hiring paused"]);
    store
        .context_action(session.clone(), ContextAction::Revoke)
        .unwrap();
    assert_eq!(
        store
            .propose_context_event(session.clone(), in_flight)
            .unwrap(),
        ContextDecision::Rejected(ContextRejection::Revoked)
    );
    assert!(matches!(
        store.context_action(
            session.clone(),
            ContextAction::Resume {
                permission: ScreenPermission::Granted
            }
        ),
        Err(StoreError::InvalidState(_))
    ));
    // A new authorization is a new scope, not the old one resurrected.
    let third = authorize(&mut store, &session);
    assert_ne!(third.scope_id, first.scope_id);
    assert_eq!(third.epoch, 1);
    assert_eq!(store.context_detail(&session).unwrap().accepted_events, 2);
}

#[test]
fn duplicates_are_suppressed_changes_append_and_marks_are_explicit() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, _) = recording_pair(&mut store);
    let scope = authorize(&mut store, &session);
    let first = accepted(
        store
            .propose_context_event(
                session.clone(),
                proposal(&scope, 10_000_001, &["Q3 plan", "Owner: Dana"]),
            )
            .unwrap(),
    );
    // Same reading, different whitespace: the same semantic hash.
    assert_eq!(
        store
            .propose_context_event(
                session.clone(),
                proposal(&scope, 20_000_001, &["Q3  plan", " Owner: Dana "])
            )
            .unwrap(),
        ContextDecision::Rejected(ContextRejection::Duplicate)
    );
    let second = accepted(
        store
            .propose_context_event(
                session.clone(),
                proposal(&scope, 30_000_001, &["Q3 plan", "Owner: Sam"]),
            )
            .unwrap(),
    );
    assert_ne!(first.semantic_hash, second.semantic_hash);
    assert_eq!(
        store
            .propose_context_event(session.clone(), proposal(&scope, 40_000_001, &[]))
            .unwrap(),
        ContextDecision::Rejected(ContextRejection::NoSemanticContent)
    );
    // Time never moves backward.
    assert_eq!(
        store
            .propose_context_event(session.clone(), proposal(&scope, 5_000_001, &["Earlier"]))
            .unwrap(),
        ContextDecision::Rejected(ContextRejection::NonMonotonic)
    );
    let mut mark = proposal(&scope, 50_000_001, &[]);
    mark.reason = ContextEventReason::UserMarked;
    accepted(store.propose_context_event(session.clone(), mark).unwrap());
    let mut repeat = proposal(&scope, 60_000_001, &["Q3 plan", "Owner: Sam"]);
    repeat.reason = ContextEventReason::UserMarked;
    accepted(
        store
            .propose_context_event(session.clone(), repeat)
            .unwrap(),
    );
    let mut attention = proposal(&scope, 70_000_001, &["Other"]);
    attention.reason = ContextEventReason::Attention;
    assert!(matches!(
        store.propose_context_event(session.clone(), attention),
        Err(StoreError::InvalidRequest(_))
    ));

    let events = store.context_events(&session).unwrap();
    assert_eq!(events.len(), 4);
    assert_eq!(events[0].text, "Q3 plan\nOwner: Dana");
    assert_eq!(events[2].text, "");
    assert_eq!(events[2].reason, "user_marked");
    assert!(events.iter().all(|event| event.retention == "no_pixels"));
    // Each event chains to the one before it.
    let stored: Vec<Value> = journal_records(&store, &session)
        .into_iter()
        .filter(|record| record.body.event_kind == "context_event_accepted")
        .map(|record| record.body.payload)
        .collect();
    assert_eq!(stored[0]["prior_event_digest"], Value::Null);
    for pair in stored.windows(2) {
        assert_eq!(pair[1]["prior_event_digest"], pair[0]["event_digest"]);
    }
    assert!(stored.iter().all(|event| event["snapshot"].is_null()));
}

#[test]
fn context_requires_recording_and_leaves_audio_truth_untouched() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources) = recording_pair(&mut store);
    let scope = authorize(&mut store, &session);
    let before = store.recorder_detail(&session).unwrap();
    store
        .recorder_action(session.clone(), RecorderAction::BeginPause)
        .unwrap();
    assert_eq!(
        store
            .propose_context_event(
                session.clone(),
                proposal(&scope, 10_000_001, &["Paused audio"])
            )
            .unwrap(),
        ContextDecision::Rejected(ContextRejection::NotRecording)
    );
    for source in &sources {
        seal(&mut store, source, 1_000_000_001, 48_000);
    }
    store
        .recorder_action(
            session.clone(),
            RecorderAction::CompletePause {
                host_time: 2_000_000_001,
            },
        )
        .unwrap();
    store
        .context_action(
            session.clone(),
            ContextAction::Fail(ContextFailureReason::PermissionLost),
        )
        .unwrap();
    let after = store.recorder_detail(&session).unwrap();
    assert_eq!(after.lifecycle, "paused");
    assert_eq!(after.captured_nanoseconds, 1_000_000_000);
    assert_ne!(before.lifecycle, after.lifecycle);
    store
        .recorder_action(session.clone(), RecorderAction::FinishPaused)
        .unwrap();
    let detail = store.context_detail(&session).unwrap();
    assert_eq!(
        detail.current().unwrap().condition,
        ContextCondition::Failed
    );
    assert_eq!(
        detail.current().unwrap().reason.as_deref(),
        Some("permission_lost")
    );
    assert!(matches!(
        store.context_action(session.clone(), ContextAction::Authorize(window_scope())),
        Err(StoreError::InvalidState(_))
    ));
}

#[test]
fn a_crash_after_the_journal_replays_scopes_events_and_declarations_once() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, _) = recording_pair(&mut store);
    store
        .declare_session(
            session.clone(),
            SessionDeclaration {
                participants: vec![" Dana ".into(), "".into(), "Sam".into()],
                topic: Some("Quarterly plan".into()),
            },
        )
        .unwrap();
    let scope = authorize(&mut store, &session);
    accepted(
        store
            .propose_context_event(session.clone(), proposal(&scope, 10_000_001, &["Agenda"]))
            .unwrap(),
    );
    // Simulate a crash between journal append and projection.
    store
        .connection
        .execute_batch(&format!(
            "DELETE FROM context_events; DELETE FROM context_scopes;
             DELETE FROM session_declarations;
             DELETE FROM session_events WHERE event_kind IN
               ('context_scope_authorized', 'context_event_accepted', 'session_declared')
               AND session_id = '{}';",
            session.0
        ))
        .unwrap();
    drop(store);
    let mut store = SessionStore::open(temp.path()).unwrap();
    store.recover_playable_sessions().unwrap();
    store.recover_playable_sessions().unwrap();
    let detail = store.context_detail(&session).unwrap();
    assert_eq!(detail.scopes.len(), 1);
    assert_eq!(detail.accepted_events, 1);
    assert_eq!(detail.declaration.participants, vec!["Dana", "Sam"]);
    assert_eq!(detail.declaration.topic.as_deref(), Some("Quarterly plan"));
    assert_eq!(store.context_events(&session).unwrap()[0].text, "Agenda");
}

#[test]
fn malformed_proposals_fail_and_oversized_ones_are_refused_without_a_record() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, _) = recording_pair(&mut store);
    let scope = authorize(&mut store, &session);
    let mut outside = proposal(&scope, 10_000_001, &["Edge"]);
    outside.blocks[0].x = 0.9;
    let mut not_finite = proposal(&scope, 10_000_001, &["NaN"]);
    not_finite.blocks[0].height = f64::NAN;
    let control = proposal(&scope, 10_000_001, &["bell\u{7}"]);
    let mut reversed = proposal(&scope, 10_000_001, &["Time"]);
    reversed.end_host_time = 1;
    for bad in [outside, not_finite, control, reversed] {
        assert!(matches!(
            store.propose_context_event(session.clone(), bad),
            Err(StoreError::InvalidRequest(_))
        ));
    }
    let line = "x".repeat(1_000);
    let lines: Vec<&str> = (0..40).map(|_| line.as_str()).collect();
    let mut dense = proposal(&scope, 10_000_001, &[]);
    dense.blocks = lines
        .iter()
        .enumerate()
        .map(|(index, text)| ContextTextBlock {
            text: (*text).into(),
            x: 0.0,
            y: index as f64 * 0.02,
            width: 1.0,
            height: 0.01,
        })
        .collect();
    assert_eq!(
        store.propose_context_event(session.clone(), dense).unwrap(),
        ContextDecision::Rejected(ContextRejection::TooLarge)
    );
    assert!(
        !journal_records(&store, &session)
            .iter()
            .any(|record| record.body.event_kind == "context_event_accepted")
    );
}

#[test]
fn context_events_and_markers_are_citable_evidence() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, _) = recording_pair(&mut store);
    let scope = authorize(&mut store, &session);
    let event = accepted(
        store
            .propose_context_event(
                session.clone(),
                proposal(&scope, 10_000_001, &["Q3 plan", "Owner: Dana"]),
            )
            .unwrap(),
    );
    let whole = store
        .cite_context_event(&session, &event.event_id, None)
        .unwrap();
    let resolved = store.resolve_evidence(&whole).unwrap();
    assert_eq!(resolved.state, ResolutionState::Available);
    assert_eq!(resolved.text.as_deref(), Some("Q3 plan\nOwner: Dana"));
    let block = store
        .cite_context_event(&session, &event.event_id, Some(1))
        .unwrap();
    assert_eq!(block.sub_item.as_deref(), Some("block-1"));
    assert_eq!(
        store.resolve_evidence(&block).unwrap().text.as_deref(),
        Some("Owner: Dana")
    );
    assert!(
        store
            .cite_context_event(&session, &event.event_id, Some(9))
            .is_err()
    );
    let mut absent_block = block.clone();
    absent_block.sub_item = Some("block-9".into());
    assert_eq!(
        store.resolve_evidence(&absent_block).unwrap().state,
        ResolutionState::Missing
    );
    // A stored event whose bytes no longer match its digest does not verify.
    store
        .connection
        .execute_batch(
            "DROP TRIGGER context_events_append_only;
             UPDATE context_events SET event_json = replace(event_json, 'Dana', 'Sam');",
        )
        .unwrap();
    assert_eq!(
        store.resolve_evidence(&whole).unwrap().state,
        ResolutionState::IntegrityMismatch
    );

    store
        .recorder_action(
            session.clone(),
            RecorderAction::Marker {
                host_time: 20_000_001,
                label: "Decision".into(),
            },
        )
        .unwrap();
    let marker: String = store
        .connection
        .query_row(
            "SELECT id FROM markers WHERE session_id = ?1",
            [&session.0],
            |row| row.get(0),
        )
        .unwrap();
    let cited = store.cite_marker(&session, &marker).unwrap();
    let resolved = store.resolve_evidence(&cited).unwrap();
    assert_eq!(resolved.state, ResolutionState::Available);
    assert_eq!(resolved.text.as_deref(), Some("Decision"));
    let mut relabeled = cited;
    relabeled.content_digest = "f".repeat(64);
    assert_eq!(
        store.resolve_evidence(&relabeled).unwrap().state,
        ResolutionState::IntegrityMismatch
    );
}
