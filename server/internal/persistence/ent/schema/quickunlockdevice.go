package schema

import (
	"entgo.io/ent"
	"entgo.io/ent/dialect/entsql"
	"entgo.io/ent/schema"
	"entgo.io/ent/schema/field"
)

// QuickUnlockDevice is a browser-scoped quick-unlock credential. Its token is
// represented exclusively by a non-reversible hash.
type QuickUnlockDevice struct{ ent.Schema }

func (QuickUnlockDevice) Annotations() []schema.Annotation {
	return []schema.Annotation{entsql.Annotation{Table: "quick_unlock_devices"}}
}

func (QuickUnlockDevice) Fields() []ent.Field {
	return []ent.Field{
		field.String("id").Immutable(),
		field.String("name"),
		field.String("mode"),
		field.String("token_hash").Sensitive(),
		field.Time("created_at").Immutable(),
		field.Time("last_used_at").Optional().Nillable(),
		field.Time("revoked_at").Optional().Nillable(),
	}
}
