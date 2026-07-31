-- These columns duplicated data already represented by the surrounding
-- relational columns. The read model now reconstructs entities from those
-- columns and the postings relation instead of deserializing whole objects.
-- The general runtime store can apply migrations before the optional ledger
-- read-model tables are initialized. Keep this migration a no-op in that case;
-- EnsureSchema creates new read-model tables without these columns.
DO $$
DECLARE
  table_name TEXT;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'ledger_index_accounts',
    'ledger_index_transactions',
    'ledger_index_postings',
    'ledger_index_balance_assertions',
    'ledger_index_prices'
  ]
  LOOP
    IF to_regclass(table_name) IS NOT NULL THEN
      EXECUTE format('ALTER TABLE %I DROP COLUMN IF EXISTS payload', table_name);
    END IF;
  END LOOP;
END $$;
