package schema

import (
	"entgo.io/ent"
	"entgo.io/ent/dialect/entsql"
	"entgo.io/ent/schema"
	"entgo.io/ent/schema/field"
	"entgo.io/ent/schema/index"
)

// AgentSession scopes a conversation to one ledger cluster.
type AgentSession struct{ ent.Schema }

func (AgentSession) Annotations() []schema.Annotation {
	return []schema.Annotation{entsql.Annotation{Table: "agent_sessions"}}
}

func (AgentSession) Fields() []ent.Field {
	return []ent.Field{
		field.String("id").Immutable(),
		field.String("cluster_id").Immutable(),
		field.String("session_id").Immutable(),
		field.Time("updated_at"),
	}
}

func (AgentSession) Indexes() []ent.Index {
	return []ent.Index{index.Fields("cluster_id", "session_id").Unique(), index.Fields("updated_at")}
}
