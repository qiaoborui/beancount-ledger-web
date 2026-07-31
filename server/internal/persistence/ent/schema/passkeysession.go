package schema

import (
	"github.com/go-webauthn/webauthn/webauthn"

	"entgo.io/ent"
	"entgo.io/ent/dialect/entsql"
	"entgo.io/ent/schema"
	"entgo.io/ent/schema/field"
)

// PasskeySession is a short-lived, single-use WebAuthn challenge. SessionData
// remains JSONB because it is a third-party protocol structure, not a
// queryable application entity.
type PasskeySession struct{ ent.Schema }

func (PasskeySession) Annotations() []schema.Annotation {
	return []schema.Annotation{entsql.Annotation{Table: "passkey_sessions"}}
}

func (PasskeySession) Fields() []ent.Field {
	return []ent.Field{
		field.String("id").StorageKey("challenge").Immutable(),
		field.JSON("data", webauthn.SessionData{}),
		field.Time("created_at").Immutable(),
		field.Time("expires_at"),
	}
}
