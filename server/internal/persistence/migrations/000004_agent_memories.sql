CREATE TABLE IF NOT EXISTS agent_memories (
  id TEXT PRIMARY KEY,
  cluster_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  title TEXT NOT NULL,
  instruction TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL,
  UNIQUE (cluster_id, kind, title)
);

CREATE INDEX IF NOT EXISTS agent_memories_cluster_updated_at
  ON agent_memories (cluster_id, updated_at DESC);
