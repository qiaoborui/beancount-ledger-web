package schema

import (
	"entgo.io/ent"
	"entgo.io/ent/dialect/entsql"
	"entgo.io/ent/schema"
	"entgo.io/ent/schema/field"
)

// WebPushSubscription is one browser endpoint. Endpoint is the natural key,
// while ID stays stable for API compatibility.
type WebPushSubscription struct{ ent.Schema }

func (WebPushSubscription) Annotations() []schema.Annotation {
	return []schema.Annotation{entsql.Annotation{Table: "web_push_subscriptions"}}
}

func (WebPushSubscription) Fields() []ent.Field {
	return []ent.Field{
		field.String("id").Immutable(),
		field.String("endpoint").Unique(),
		field.Float("expiration_time").Optional().Nillable(),
		field.String("auth_secret").Sensitive(),
		field.String("p256dh").Sensitive(),
		field.String("user_agent").Optional(),
		field.Time("created_at").Immutable(),
		field.Time("updated_at"),
	}
}
