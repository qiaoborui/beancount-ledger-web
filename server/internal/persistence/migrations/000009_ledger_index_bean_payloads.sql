-- The optional ledger read-model owns this migration because its tables are
-- created lazily. LedgerIndexStore backfills legacy bean_entries/bean_errors
-- into typed relations in one transaction, then removes the JSONB columns.
SELECT 1;
