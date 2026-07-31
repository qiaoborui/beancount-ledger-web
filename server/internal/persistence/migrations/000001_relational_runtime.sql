-- First relational runtime slice. Legacy runtime_json remains readable during
-- rollout and is deliberately not altered in this migration.
CREATE TABLE IF NOT EXISTS schema_migrations (
  version TEXT PRIMARY KEY,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS relational_backfills (
  name TEXT PRIMARY KEY,
  completed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS web_push_subscriptions (
  id TEXT PRIMARY KEY,
  endpoint TEXT NOT NULL UNIQUE,
  expiration_time DOUBLE PRECISION,
  auth_secret TEXT NOT NULL,
  p256dh TEXT NOT NULL,
  user_agent TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS notifications (
  id TEXT PRIMARY KEY,
  insight_id TEXT NOT NULL,
  month TEXT NOT NULL,
  severity TEXT NOT NULL,
  title TEXT NOT NULL,
  detail TEXT NOT NULL,
  detail_hash TEXT NOT NULL,
  amount BIGINT,
  account TEXT NOT NULL DEFAULT '',
  occurred_on TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  read_at TIMESTAMPTZ,
  dismissed_at TIMESTAMPTZ,
  resolved_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL,
  UNIQUE (month, insight_id)
);

CREATE INDEX IF NOT EXISTS notifications_month_status_severity_updated_at
  ON notifications (month, status, severity, updated_at DESC);

CREATE TABLE IF NOT EXISTS bql_history_records (
  id TEXT PRIMARY KEY,
  cluster_id TEXT NOT NULL,
  query TEXT NOT NULL,
  title TEXT NOT NULL,
  title_source TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  last_run_at TIMESTAMPTZ NOT NULL,
  run_count INTEGER NOT NULL,
  UNIQUE (cluster_id, query)
);

CREATE INDEX IF NOT EXISTS bql_history_records_cluster_last_run_at
  ON bql_history_records (cluster_id, last_run_at DESC);
