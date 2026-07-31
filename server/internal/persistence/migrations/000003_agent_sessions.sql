CREATE TABLE IF NOT EXISTS agent_sessions (
  id TEXT PRIMARY KEY,
  cluster_id TEXT NOT NULL,
  session_id TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL,
  UNIQUE (cluster_id, session_id)
);

CREATE INDEX IF NOT EXISTS agent_sessions_updated_at ON agent_sessions (updated_at);

CREATE TABLE IF NOT EXISTS agent_session_messages (
  id TEXT PRIMARY KEY,
  session_key TEXT NOT NULL REFERENCES agent_sessions(id) ON DELETE CASCADE,
  ordinal INTEGER NOT NULL,
  role TEXT NOT NULL,
  content TEXT NOT NULL DEFAULT '',
  tool_call_id TEXT NOT NULL DEFAULT '',
  tool_calls JSONB,
  UNIQUE (session_key, ordinal)
);

CREATE TABLE IF NOT EXISTS agent_approvals (
  id TEXT PRIMARY KEY,
  cluster_id TEXT NOT NULL,
  session_id TEXT NOT NULL,
  tool_call_id TEXT NOT NULL,
  tool_name TEXT NOT NULL,
  tool_title TEXT NOT NULL,
  arguments JSONB NOT NULL,
  summary TEXT NOT NULL,
  page TEXT NOT NULL DEFAULT '',
  path TEXT NOT NULL DEFAULT '',
  range_start TEXT NOT NULL DEFAULT '',
  range_end TEXT NOT NULL DEFAULT '',
  valuation_currency TEXT NOT NULL DEFAULT '',
  bql_query TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS agent_approvals_cluster_session ON agent_approvals (cluster_id, session_id);
CREATE INDEX IF NOT EXISTS agent_approvals_expires_at ON agent_approvals (expires_at);
