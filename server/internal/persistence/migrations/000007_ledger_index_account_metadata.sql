-- Beancount account metadata supports user-defined scalar values. Persist the
-- key and its declared scalar type rather than serializing a whole metadata
-- map, while retaining exact values for the API read model.
DO $$
BEGIN
  IF to_regclass('ledger_index_accounts') IS NOT NULL THEN
    CREATE TABLE IF NOT EXISTS ledger_index_account_metadata (
      revision_id BIGINT NOT NULL,
      account TEXT NOT NULL,
      metadata_key TEXT NOT NULL,
      value_kind TEXT NOT NULL CHECK (value_kind IN ('null', 'string', 'number', 'boolean')),
      text_value TEXT,
      number_value DOUBLE PRECISION,
      boolean_value BOOLEAN,
      PRIMARY KEY (revision_id, account, metadata_key),
      FOREIGN KEY (revision_id, account)
        REFERENCES ledger_index_accounts(revision_id, account) ON DELETE CASCADE,
      CHECK (
        (value_kind = 'null' AND text_value IS NULL AND number_value IS NULL AND boolean_value IS NULL) OR
        (value_kind = 'string' AND text_value IS NOT NULL AND number_value IS NULL AND boolean_value IS NULL) OR
        (value_kind = 'number' AND text_value IS NULL AND number_value IS NOT NULL AND boolean_value IS NULL) OR
        (value_kind = 'boolean' AND text_value IS NULL AND number_value IS NULL AND boolean_value IS NOT NULL)
      )
    );

    CREATE INDEX IF NOT EXISTS ledger_index_account_metadata_key
      ON ledger_index_account_metadata (revision_id, metadata_key);

    IF EXISTS (
      SELECT 1
      FROM ledger_index_accounts accounts
      CROSS JOIN LATERAL jsonb_each(accounts.metadata) AS metadata(key, value)
      WHERE jsonb_typeof(metadata.value) NOT IN ('null', 'string', 'number', 'boolean')
    ) THEN
      RAISE EXCEPTION 'ledger account metadata contains a non-scalar value';
    END IF;

    INSERT INTO ledger_index_account_metadata (revision_id, account, metadata_key, value_kind, text_value, number_value, boolean_value)
    SELECT
      accounts.revision_id,
      accounts.account,
      metadata.key,
      CASE jsonb_typeof(metadata.value)
        WHEN 'null' THEN 'null'
        WHEN 'string' THEN 'string'
        WHEN 'number' THEN 'number'
        WHEN 'boolean' THEN 'boolean'
      END,
      CASE WHEN jsonb_typeof(metadata.value) = 'string' THEN metadata.value #>> '{}' END,
      CASE WHEN jsonb_typeof(metadata.value) = 'number' THEN (metadata.value #>> '{}')::DOUBLE PRECISION END,
      CASE WHEN jsonb_typeof(metadata.value) = 'boolean' THEN (metadata.value #>> '{}')::BOOLEAN END
    FROM ledger_index_accounts accounts
    CROSS JOIN LATERAL jsonb_each(accounts.metadata) AS metadata(key, value)
    WHERE jsonb_typeof(metadata.value) IN ('null', 'string', 'number', 'boolean')
    ON CONFLICT (revision_id, account, metadata_key) DO NOTHING;

    ALTER TABLE ledger_index_accounts DROP COLUMN IF EXISTS metadata;
  END IF;
END $$;
