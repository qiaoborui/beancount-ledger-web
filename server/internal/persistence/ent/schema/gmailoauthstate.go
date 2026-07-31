package schema

import (
	"entgo.io/ent"
	"entgo.io/ent/dialect/entsql"
	"entgo.io/ent/schema"
	"entgo.io/ent/schema/field"
)

// GmailOAuthState is a single-use OAuth CSRF state kept outside runtime JSON.
type GmailOAuthState struct{ ent.Schema }

func (GmailOAuthState) Annotations() []schema.Annotation {
	return []schema.Annotation{entsql.Annotation{Table: "gmail_oauth_states"}}
}
func (GmailOAuthState) Fields() []ent.Field {
	return []ent.Field{field.String("id").Immutable(), field.String("value"), field.Time("created_at").Immutable(), field.Time("expires_at")}
}
