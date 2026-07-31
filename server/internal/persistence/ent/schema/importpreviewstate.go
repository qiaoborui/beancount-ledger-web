package schema

import (
	"entgo.io/ent"
	"entgo.io/ent/dialect/entsql"
	"entgo.io/ent/schema"
	"entgo.io/ent/schema/field"
	"entgo.io/ent/schema/index"
)

// ImportPreviewState stores the scalar, queryable part of an import preview.
// Entries and account options are derived on read rather than persisted as a
// JSON response blob.
type ImportPreviewState struct{ ent.Schema }

func (ImportPreviewState) Annotations() []schema.Annotation {
	return []schema.Annotation{entsql.Annotation{Table: "import_preview_state"}}
}

func (ImportPreviewState) Fields() []ent.Field {
	return []ent.Field{
		field.String("id").StorageKey("import_id").Immutable(),
		field.String("dedup_report"),
		field.Int("candidate_count"),
		field.Int("raw_row_count"),
		field.Int("filtered_row_count"),
		field.Int("generated_count"),
		field.Int("excluded_row_count"),
		field.Int("skipped_duplicate_count"),
		field.String("date_start").Optional(),
		field.String("date_end").Optional(),
		field.Time("created_at").Immutable(),
		field.Time("updated_at"),
	}
}

func (ImportPreviewState) Indexes() []ent.Index {
	return []ent.Index{index.Fields("updated_at")}
}
