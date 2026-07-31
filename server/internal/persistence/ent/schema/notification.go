package schema

import (
	"entgo.io/ent"
	"entgo.io/ent/dialect/entsql"
	"entgo.io/ent/schema"
	"entgo.io/ent/schema/field"
	"entgo.io/ent/schema/index"
)

// Notification is a persisted insight state. Every queryable property is a
// column so refreshing a month no longer rewrites an unrelated JSON document.
type Notification struct{ ent.Schema }

func (Notification) Annotations() []schema.Annotation {
	return []schema.Annotation{entsql.Annotation{Table: "notifications"}}
}

func (Notification) Fields() []ent.Field {
	return []ent.Field{
		field.String("id").Immutable(),
		field.String("insight_id"),
		field.String("month"),
		field.String("severity"),
		field.String("title"),
		field.String("detail"),
		field.String("detail_hash"),
		field.Int("amount").Optional().Nillable(),
		field.String("account").Optional(),
		field.String("occurred_on").Optional(),
		field.String("status"),
		field.Time("created_at").Immutable(),
		field.Time("read_at").Optional().Nillable(),
		field.Time("dismissed_at").Optional().Nillable(),
		field.Time("resolved_at").Optional().Nillable(),
		field.Time("updated_at"),
	}
}

func (Notification) Indexes() []ent.Index {
	return []ent.Index{
		index.Fields("month", "insight_id").Unique(),
		index.Fields("month", "status", "severity", "updated_at"),
	}
}
