package schema

import (
	"entgo.io/ent"
	"entgo.io/ent/dialect/entsql"
	"entgo.io/ent/schema"
	"entgo.io/ent/schema/field"
)

// PasskeyCredential stores one WebAuthn credential. PublicKey is binary data,
// never a serialized runtime document.
type PasskeyCredential struct{ ent.Schema }

func (PasskeyCredential) Annotations() []schema.Annotation {
	return []schema.Annotation{entsql.Annotation{Table: "passkey_credentials"}}
}

func (PasskeyCredential) Fields() []ent.Field {
	return []ent.Field{
		field.String("id").Immutable(),
		field.Bytes("public_key").Sensitive(),
		field.Uint64("sign_count"),
		field.String("name").Default(""),
		field.Bool("backup_eligible").Optional().Nillable(),
		field.Bool("backup_state").Optional().Nillable(),
		field.Time("created_at").Immutable(),
		field.Time("updated_at"),
		field.Time("last_used_at").Optional().Nillable(),
	}
}
