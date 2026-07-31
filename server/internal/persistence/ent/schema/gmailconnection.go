package schema

import (
	"entgo.io/ent"
	"entgo.io/ent/dialect/entsql"
	"entgo.io/ent/schema"
	"entgo.io/ent/schema/field"
)

// GmailConnection is the singleton OAuth connection. History IDs stay text:
// Gmail may exceed a signed PostgreSQL bigint.
type GmailConnection struct{ ent.Schema }

func (GmailConnection) Annotations() []schema.Annotation {
	return []schema.Annotation{entsql.Annotation{Table: "gmail_connections"}}
}
func (GmailConnection) Fields() []ent.Field {
	return []ent.Field{
		field.String("id").Immutable(), field.String("email"), field.String("encrypted_refresh_token").Sensitive(),
		field.String("label_id"), field.String("label_name"), field.String("history_id"), field.Int64("watch_expiration"),
		field.Time("connected_at").Immutable(), field.Time("updated_at"), field.Time("last_sync_at").Optional().Nillable(), field.String("last_error"),
	}
}
