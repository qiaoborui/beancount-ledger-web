ALTER TABLE passkey_credentials
  ADD COLUMN IF NOT EXISTS name TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS last_used_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS passkey_credentials_last_used_at
  ON passkey_credentials (last_used_at DESC, created_at DESC);
