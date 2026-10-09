use super::*;

#[test]
fn enospc_append_preserves_complete_canonical_journal_without_replay() {
    for failure in [
        JournalReplacementFailurePoint::PartialWriteNoSpace,
        JournalReplacementFailurePoint::AfterRenameNoSpace,
    ] {
        let temp = TempDir::new().unwrap();
        let mut store = open_store(&temp);
        let receipt = store.prepare_session(request()).unwrap();
        let path = store
            .session_directory(&receipt.session_id.0)
            .unwrap()
            .join(JOURNAL_NAME);
        let before = fs::read(&path).unwrap();
        let JournalValidation::Valid(original) =
            validate_journal(&path, &receipt.session_id.0).unwrap()
        else {
            panic!("fixture journal must be valid");
        };
        let error = store
            .append_session_journal_inner(
                &receipt.session_id.0,
                "storage_observed",
                None,
                json!({"level": "critical"}),
                Some(failure),
            )
            .unwrap_err();
        assert!(matches!(error, StoreError::Io(error) if error.raw_os_error() == Some(28)));
        let JournalValidation::Valid(records) =
            validate_journal(&path, &receipt.session_id.0).unwrap()
        else {
            panic!("ENOSPC exposed an invalid canonical journal");
        };
        let committed = failure == JournalReplacementFailurePoint::AfterRenameNoSpace;
        assert_eq!(records.len(), original.len() + usize::from(committed));
        assert_eq!(
            records
                .iter()
                .filter(|r| r.body.event_kind == "storage_observed")
                .count(),
            usize::from(committed)
        );
        if !committed {
            assert_eq!(fs::read(&path).unwrap(), before);
        }
        drop(store);
        let reopened = open_store(&temp);
        assert!(matches!(
            validate_journal(&path, &receipt.session_id.0).unwrap(),
            JournalValidation::Valid(restarted) if restarted.len() == records.len()
        ));
        drop(reopened);
    }
}
