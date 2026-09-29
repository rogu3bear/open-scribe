PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;
CREATE TABLE schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at_ms INTEGER NOT NULL
        );
INSERT INTO schema_migrations VALUES(1,1790717011453);
INSERT INTO schema_migrations VALUES(2,1790717011453);
INSERT INTO schema_migrations VALUES(3,1790717011453);
INSERT INTO schema_migrations VALUES(4,1790717011453);
CREATE TABLE sessions (
            id TEXT PRIMARY KEY,
            schema_version INTEGER NOT NULL,
            title TEXT NOT NULL,
            origin TEXT NOT NULL CHECK (origin IN ('capture', 'import')),
            lifecycle TEXT NOT NULL CHECK (
                lifecycle IN ('preparing', 'recording', 'paused', 'finalizing',
                              'ready_for_review', 'interrupted', 'deleted')
            ),
            health TEXT NOT NULL CHECK (health IN ('healthy', 'degraded')),
            journal_durable INTEGER NOT NULL CHECK (journal_durable IN (0, 1)),
            media_files_open INTEGER NOT NULL CHECK (media_files_open IN (0, 1)),
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL
        );
INSERT INTO sessions VALUES('01a0ef0d-2600-76c4-8f7e-de8905518c51',4,'Schema v4 fixture','import','ready_for_review','healthy',1,0,1790717011456,1790717011507);
CREATE TABLE sources (
            id TEXT PRIMARY KEY,
            schema_version INTEGER NOT NULL,
            session_id TEXT NOT NULL REFERENCES sessions(id),
            kind TEXT NOT NULL,
            display_name TEXT NOT NULL,
            lifecycle TEXT NOT NULL,
            UNIQUE(session_id, id)
        );
INSERT INTO sources VALUES('01a0ef0d-2610-77cf-88eb-59e05db5f66b',4,'01a0ef0d-2600-76c4-8f7e-de8905518c51','imported_audio','source.caf','sealed');
CREATE TABLE required_sources (
            session_id TEXT NOT NULL REFERENCES sessions(id),
            schema_version INTEGER NOT NULL,
            kind TEXT NOT NULL CHECK (
                kind IN ('microphone', 'application_audio', 'system_audio')
            ),
            lifecycle TEXT NOT NULL CHECK (
                lifecycle IN ('required', 'opening', 'open', 'capturing', 'failed', 'sealed')
            ),
            PRIMARY KEY(session_id, kind)
        );
CREATE TABLE tracks (
            id TEXT PRIMARY KEY,
            schema_version INTEGER NOT NULL,
            session_id TEXT NOT NULL REFERENCES sessions(id),
            source_id TEXT NOT NULL REFERENCES sources(id),
            kind TEXT NOT NULL,
            lifecycle TEXT NOT NULL
        );
INSERT INTO tracks VALUES('01a0ef0d-2610-77cf-88eb-59e1220757d7',4,'01a0ef0d-2600-76c4-8f7e-de8905518c51','01a0ef0d-2610-77cf-88eb-59e05db5f66b','audio','sealed');
CREATE TABLE segments (
            id TEXT PRIMARY KEY,
            schema_version INTEGER NOT NULL,
            session_id TEXT NOT NULL REFERENCES sessions(id),
            track_id TEXT NOT NULL REFERENCES tracks(id),
            sequence INTEGER NOT NULL,
            relative_path TEXT NOT NULL,
            lifecycle TEXT NOT NULL,
            original_start INTEGER,
            mapped_start_ns INTEGER NOT NULL,
            media_format TEXT NOT NULL,
            channels INTEGER NOT NULL DEFAULT 1 CHECK (channels IN (1, 2)),
            sample_count INTEGER,
            byte_length INTEGER,
            digest TEXT,
            seal_state TEXT NOT NULL,
            recovery_state TEXT NOT NULL,
            open_token TEXT,
            writer_generation INTEGER NOT NULL DEFAULT 0,
            file_device INTEGER,
            file_inode INTEGER,
            UNIQUE(track_id, sequence)
        );
INSERT INTO segments VALUES('01a0ef0d-2610-77cf-88eb-59e270d75ae0',4,'01a0ef0d-2600-76c4-8f7e-de8905518c51','01a0ef0d-2610-77cf-88eb-59e1220757d7',0,'audio/01a0ef0d-2610-77cf-88eb-59e1220757d7/000000-import.caf','sealed',0,0,'caf-pcm-s16le',1,48000,96068,'a8c794f178230c3f9e629e1366cf7c6891f1294a3d1eed283df1554fbeaa2587','sealed','not_required',NULL,0,16777229,1278569817);
CREATE TABLE session_events (
            id TEXT PRIMARY KEY,
            schema_version INTEGER NOT NULL,
            session_id TEXT NOT NULL REFERENCES sessions(id),
            sequence INTEGER NOT NULL,
            event_kind TEXT NOT NULL,
            session_nanoseconds INTEGER NOT NULL,
            wall_time_ms INTEGER NOT NULL,
            payload_json TEXT NOT NULL,
            prior_digest TEXT,
            digest TEXT NOT NULL,
            UNIQUE(session_id, sequence)
        );
INSERT INTO session_events VALUES('01a0ef0d-2600-76c4-8f7e-de8acecb08a8',4,'01a0ef0d-2600-76c4-8f7e-de8905518c51',1,'session_create_intent',0,1790717011456,'{"origin":"import"}',NULL,'54c2a3e199ba620b91a8655db9c347574af325bf87363a7aedefb82d76301f18');
INSERT INTO session_events VALUES('01a0ef0d-260f-7023-8436-fd78842c2f65',4,'01a0ef0d-2600-76c4-8f7e-de8905518c51',2,'session_directory_ready',0,1790717011456,'{"relative_path":"."}','54c2a3e199ba620b91a8655db9c347574af325bf87363a7aedefb82d76301f18','654f1294cf5efa7ad1f1864b47a4d6435beb877fb1df8845175378310243e053');
INSERT INTO session_events VALUES('01a0ef0d-2620-71f4-896d-fa6238fe7a8d',4,'01a0ef0d-2600-76c4-8f7e-de8905518c51',3,'media_imported',0,1790717011488,'{"byte_length":96068,"digest_sha256":"a8c794f178230c3f9e629e1366cf7c6891f1294a3d1eed283df1554fbeaa2587","media_format":"caf-pcm-s16le","original_media":null,"relative_path":"audio/01a0ef0d-2610-77cf-88eb-59e1220757d7/000000-import.caf","sample_count":48000,"segment_id":"01a0ef0d-2610-77cf-88eb-59e270d75ae0","source_display_name":"source.caf","source_id":"01a0ef0d-2610-77cf-88eb-59e05db5f66b","source_kind":"imported_audio","staging_relative_path":"audio/01a0ef0d-2610-77cf-88eb-59e1220757d7/.importing.caf","track_id":"01a0ef0d-2610-77cf-88eb-59e1220757d7"}','654f1294cf5efa7ad1f1864b47a4d6435beb877fb1df8845175378310243e053','66cca4e8acecba4bb12193a2147938c29605bf2749eebdd0ef66e208b6651b5f');
CREATE TABLE markers (
            id TEXT PRIMARY KEY,
            schema_version INTEGER NOT NULL,
            session_id TEXT NOT NULL REFERENCES sessions(id),
            session_nanoseconds INTEGER NOT NULL,
            label TEXT
        );
CREATE TABLE imports (
            id TEXT PRIMARY KEY,
            schema_version INTEGER NOT NULL,
            session_id TEXT NOT NULL REFERENCES sessions(id),
            relative_path TEXT NOT NULL,
            source_digest TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL
        );
INSERT INTO imports VALUES('01a0ef0d-2633-74d9-b285-bcd3baa7b9e3',4,'01a0ef0d-2600-76c4-8f7e-de8905518c51','audio/01a0ef0d-2610-77cf-88eb-59e1220757d7/000000-import.caf','a8c794f178230c3f9e629e1366cf7c6891f1294a3d1eed283df1554fbeaa2587',1790717011507);
CREATE TABLE deletion_receipts (
            id TEXT PRIMARY KEY,
            schema_version INTEGER NOT NULL,
            session_id TEXT NOT NULL REFERENCES sessions(id),
            trash_reference TEXT,
            created_at_ms INTEGER NOT NULL
        );
CREATE TABLE recovery_runs (
            id TEXT PRIMARY KEY,
            schema_version INTEGER NOT NULL,
            session_id TEXT NOT NULL REFERENCES sessions(id),
            disposition TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL
        );
COMMIT;
