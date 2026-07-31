package schema

import (
	"encoding/json"

	"entgo.io/ent"
	"entgo.io/ent/dialect/entsql"
	"entgo.io/ent/schema"
	"entgo.io/ent/schema/field"
	"entgo.io/ent/schema/index"
)

// AgentApproval is a short-lived approval token. Dynamic tool arguments are
// retained as JSONB; all ownership and lifecycle fields are relational.
type AgentApproval struct{ ent.Schema }

func (AgentApproval) Annotations() []schema.Annotation {
	return []schema.Annotation{entsql.Annotation{Table: "agent_approvals"}}
}

func (AgentApproval) Fields() []ent.Field {
	return []ent.Field{
		field.String("id").Immutable(),
		field.String("cluster_id").Immutable(),
		field.String("session_id").Immutable(),
		field.String("tool_call_id"),
		field.String("tool_name"),
		field.String("tool_title"),
		field.JSON("arguments", json.RawMessage{}),
		field.String("summary"),
		field.String("page").Optional(),
		field.String("path").Optional(),
		field.String("range_start").Optional(),
		field.String("range_end").Optional(),
		field.String("valuation_currency").Optional(),
		field.String("bql_query").Optional(),
		field.Time("created_at").Immutable(),
		field.Time("expires_at"),
	}
}

func (AgentApproval) Indexes() []ent.Index {
	return []ent.Index{index.Fields("cluster_id", "session_id"), index.Fields("expires_at")}
}
