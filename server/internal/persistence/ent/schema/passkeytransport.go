package schema

import (
	"entgo.io/ent"
	"entgo.io/ent/dialect/entsql"
	"entgo.io/ent/schema"
	"entgo.io/ent/schema/field"
	"entgo.io/ent/schema/index"
)

// PasskeyTransport is a transport hint belonging to a credential.
type PasskeyTransport struct{ ent.Schema }

func (PasskeyTransport) Annotations() []schema.Annotation {
	return []schema.Annotation{entsql.Annotation{Table: "passkey_transports"}}
}

func (PasskeyTransport) Fields() []ent.Field {
	return []ent.Field{
		field.String("id").Immutable(),
		field.String("credential_id").Immutable(),
		field.String("transport"),
	}
}

func (PasskeyTransport) Indexes() []ent.Index {
	return []ent.Index{index.Fields("credential_id", "transport").Unique()}
}
