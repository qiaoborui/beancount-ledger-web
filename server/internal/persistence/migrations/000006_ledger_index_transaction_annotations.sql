-- Transaction tags and links are separately queryable ledger concepts. They
-- live in their own relations so the read model does not store collections in
-- an array column. The read-model tables are optional, so this migration must
-- also be safe when the general runtime store runs before they exist.
DO $$
BEGIN
  IF to_regclass('ledger_index_transactions') IS NOT NULL THEN
    ALTER TABLE ledger_index_transactions
      DROP COLUMN IF EXISTS tags,
      DROP COLUMN IF EXISTS links;
  END IF;
END $$;
