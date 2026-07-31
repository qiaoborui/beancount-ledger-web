package schema

import (
	"encoding/json"

	"entgo.io/ent"
	"entgo.io/ent/dialect/entsql"
	"entgo.io/ent/schema"
	"entgo.io/ent/schema/field"
	"entgo.io/ent/schema/index"
)

// AgentSessionMessage stores one model message; only dynamic tool-call content
// is JSON because its schema belongs to the model provider.
type AgentSessionMessage struct{ ent.Schema }

func (AgentSessionMessage) Annotations() []schema.Annotation {
	return []schema.Annotation{entsql.Annotation{Table: "agent_session_messages"}}
}

func (AgentSessionMessage) Fields() []ent.Field {
	return []ent.Field{
		field.String("id").Immutable(),
		field.String("session_key").Immutable(),
		field.Int("ordinal"),
		field.String("role"),
		field.String("content").Optional(),
		field.String("tool_call_id").Optional(),
		field.JSON("tool_calls", json.RawMessage{}).Optional(),
	}
}

func (AgentSessionMessage) Indexes() []ent.Index {
	return []ent.Index{index.Fields("session_key", "ordinal").Unique()}
}
