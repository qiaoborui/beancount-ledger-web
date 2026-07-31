-- Runtime business state is stored in independently mutable relational rows.
-- runtime_json remains only for filesystem deployments and upgrade backfills.

CREATE TABLE IF NOT EXISTS quick_unlock_devices (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    mode TEXT NOT NULL,
    token_hash TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    last_used_at TIMESTAMPTZ,
    revoked_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS gmail_connections (
    id TEXT PRIMARY KEY,
    email TEXT NOT NULL,
    encrypted_refresh_token TEXT NOT NULL,
    label_id TEXT NOT NULL,
    label_name TEXT NOT NULL,
    history_id TEXT NOT NULL,
    watch_expiration BIGINT NOT NULL,
    connected_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    last_sync_at TIMESTAMPTZ,
    last_error TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS gmail_oauth_states (
    id TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS gmail_push_events (
    id TEXT PRIMARY KEY,
    email TEXT NOT NULL,
    history_id TEXT NOT NULL,
    status TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    available_at TIMESTAMPTZ NOT NULL,
    lease_until TIMESTAMPTZ,
    last_error TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS gmail_push_events_claim_idx ON gmail_push_events (status, available_at, created_at);
CREATE INDEX IF NOT EXISTS gmail_push_events_lease_idx ON gmail_push_events (lease_until) WHERE lease_until IS NOT NULL;

CREATE TABLE IF NOT EXISTS gmail_sync_leases (
    name TEXT PRIMARY KEY,
    owner TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL
);
-- A permanent mutex row lets Ent's SELECT ... FOR UPDATE preserve the former
-- RuntimeStore critical-section semantics across application instances.
INSERT INTO gmail_sync_leases (name, owner, expires_at)
VALUES ('__gmail_state_lock__', '', to_timestamp(0))
ON CONFLICT (name) DO NOTHING;

CREATE TABLE IF NOT EXISTS import_jobs (
    id TEXT PRIMARY KEY,
    provider TEXT NOT NULL,
    original_filename TEXT NOT NULL,
    input_filename TEXT NOT NULL DEFAULT '',
    input_file_key TEXT NOT NULL DEFAULT '',
    document_file_key TEXT NOT NULL DEFAULT '',
    generated_file_key TEXT NOT NULL DEFAULT '',
    deduped_file_key TEXT NOT NULL DEFAULT '',
    detection_provider TEXT NOT NULL DEFAULT '',
    detection_reason TEXT NOT NULL DEFAULT '',
    detection_confidence TEXT NOT NULL DEFAULT '',
    statement_hash TEXT NOT NULL DEFAULT '',
    date_start TEXT NOT NULL DEFAULT '',
    date_end TEXT NOT NULL DEFAULT '',
    expected_entry_count INTEGER,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS import_preview_state (
    import_id TEXT PRIMARY KEY REFERENCES import_jobs(id) ON DELETE CASCADE,
    dedup_report TEXT NOT NULL DEFAULT '',
    candidate_count INTEGER NOT NULL DEFAULT 0,
    raw_row_count INTEGER NOT NULL DEFAULT 0,
    filtered_row_count INTEGER NOT NULL DEFAULT 0,
    generated_count INTEGER NOT NULL DEFAULT 0,
    excluded_row_count INTEGER NOT NULL DEFAULT 0,
    skipped_duplicate_count INTEGER NOT NULL DEFAULT 0,
    date_start TEXT NOT NULL DEFAULT '',
    date_end TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS import_preview_warnings (
    id TEXT PRIMARY KEY,
    import_id TEXT NOT NULL REFERENCES import_preview_state(import_id) ON DELETE CASCADE,
    position INTEGER NOT NULL,
    message TEXT NOT NULL,
    UNIQUE (import_id, position)
);

CREATE TABLE IF NOT EXISTS gmail_pending_imports (
    id TEXT PRIMARY KEY,
    import_id TEXT,
    source_key TEXT NOT NULL DEFAULT '',
    message_id TEXT NOT NULL,
    thread_id TEXT NOT NULL DEFAULT '',
    sender TEXT NOT NULL DEFAULT '',
    subject TEXT NOT NULL DEFAULT '',
    received_at TIMESTAMPTZ,
    filename TEXT NOT NULL DEFAULT '',
    provider TEXT NOT NULL DEFAULT '',
    candidate_count INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL,
    error TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    stored_bytes BIGINT NOT NULL DEFAULT 0,
    output_file TEXT NOT NULL DEFAULT ''
);
CREATE UNIQUE INDEX IF NOT EXISTS gmail_pending_imports_source_key_unique
    ON gmail_pending_imports (source_key) WHERE source_key <> '';
CREATE INDEX IF NOT EXISTS gmail_pending_imports_status_updated_idx
    ON gmail_pending_imports (status, updated_at DESC);
