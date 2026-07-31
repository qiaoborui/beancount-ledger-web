package schema

import (
	"entgo.io/ent"
	"entgo.io/ent/dialect/entsql"
	"entgo.io/ent/schema"
	"entgo.io/ent/schema/field"
	"entgo.io/ent/schema/index"
)

// AgentMemory stores one confirmed user preference/rule for a ledger cluster.
type AgentMemory struct{ ent.Schema }

func (AgentMemory) Annotations() []schema.Annotation {
	return []schema.Annotation{entsql.Annotation{Table: "agent_memories"}}
}

func (AgentMemory) Fields() []ent.Field {
	return []ent.Field{
		field.String("id").Immutable(),
		field.String("cluster_id").Immutable(),
		field.String("kind"),
		field.String("title"),
		field.String("instruction"),
		field.Time("created_at").Immutable(),
		field.Time("updated_at"),
	}
}

func (AgentMemory) Indexes() []ent.Index {
	return []ent.Index{index.Fields("cluster_id", "kind", "title").Unique(), index.Fields("cluster_id", "updated_at")}
}
