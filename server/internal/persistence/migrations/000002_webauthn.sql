CREATE TABLE IF NOT EXISTS passkey_credentials (
  id TEXT PRIMARY KEY,
  public_key BYTEA NOT NULL,
  sign_count BIGINT NOT NULL,
  backup_eligible BOOLEAN,
  backup_state BOOLEAN,
  created_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS passkey_transports (
  id TEXT PRIMARY KEY,
  credential_id TEXT NOT NULL REFERENCES passkey_credentials(id) ON DELETE CASCADE,
  transport TEXT NOT NULL,
  UNIQUE (credential_id, transport)
);

CREATE INDEX IF NOT EXISTS passkey_transports_credential_id
  ON passkey_transports (credential_id);

CREATE TABLE IF NOT EXISTS passkey_sessions (
  challenge TEXT PRIMARY KEY,
  data JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS passkey_sessions_expires_at
  ON passkey_sessions (expires_at);
