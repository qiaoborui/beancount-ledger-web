package schema

import (
	"entgo.io/ent"
	"entgo.io/ent/dialect/entsql"
	"entgo.io/ent/schema"
	"entgo.io/ent/schema/field"
	"entgo.io/ent/schema/index"
)

// GmailPushEvent is one deduplicated Pub/Sub delivery and its retry state.
type GmailPushEvent struct{ ent.Schema }

func (GmailPushEvent) Annotations() []schema.Annotation {
	return []schema.Annotation{entsql.Annotation{Table: "gmail_push_events"}}
}
func (GmailPushEvent) Fields() []ent.Field {
	return []ent.Field{
		field.String("id").Immutable(), field.String("email"), field.String("history_id"), field.String("status"), field.Int("attempts"),
		field.Time("available_at"), field.Time("lease_until").Optional().Nillable(), field.String("last_error"), field.Time("created_at").Immutable(), field.Time("updated_at"),
	}
}
func (GmailPushEvent) Indexes() []ent.Index {
	return []ent.Index{index.Fields("status", "available_at"), index.Fields("created_at")}
}
