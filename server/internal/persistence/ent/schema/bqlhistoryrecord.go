package schema

import (
	"entgo.io/ent"
	"entgo.io/ent/dialect/entsql"
	"entgo.io/ent/schema"
	"entgo.io/ent/schema/field"
	"entgo.io/ent/schema/index"
)

// BQLHistoryRecord belongs to a ledger cluster and is deduplicated by query.
type BQLHistoryRecord struct{ ent.Schema }

func (BQLHistoryRecord) Annotations() []schema.Annotation {
	return []schema.Annotation{entsql.Annotation{Table: "bql_history_records"}}
}

func (BQLHistoryRecord) Fields() []ent.Field {
	return []ent.Field{
		field.String("id").Immutable(),
		field.String("cluster_id").Immutable(),
		field.String("query"),
		field.String("title"),
		field.String("title_source"),
		field.Time("created_at").Immutable(),
		field.Time("last_run_at"),
		field.Int("run_count"),
	}
}

func (BQLHistoryRecord) Indexes() []ent.Index {
	return []ent.Index{
		index.Fields("cluster_id", "query").Unique(),
		index.Fields("cluster_id", "last_run_at"),
	}
}
