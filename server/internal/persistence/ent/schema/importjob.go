package schema

import (
	"entgo.io/ent"
	"entgo.io/ent/dialect/entsql"
	"entgo.io/ent/schema"
	"entgo.io/ent/schema/field"
	"entgo.io/ent/schema/index"
)

// ImportJob is the durable metadata for one in-progress bill import. Runtime
// file keys deliberately replace local temporary paths so a job can be resumed
// by another process.
type ImportJob struct{ ent.Schema }

func (ImportJob) Annotations() []schema.Annotation {
	return []schema.Annotation{entsql.Annotation{Table: "import_jobs"}}
}

func (ImportJob) Fields() []ent.Field {
	return []ent.Field{
		field.String("id").Immutable(),
		field.String("provider"),
		field.String("original_filename"),
		field.String("input_filename").Optional(),
		field.String("input_file_key").Optional(),
		field.String("document_file_key").Optional(),
		field.String("generated_file_key").Optional(),
		field.String("deduped_file_key").Optional(),
		field.String("detection_provider"),
		field.String("detection_reason"),
		field.String("detection_confidence"),
		field.String("statement_hash"),
		field.String("date_start").Optional(),
		field.String("date_end").Optional(),
		field.Int("expected_entry_count").Optional().Nillable(),
		field.Time("created_at").Immutable(),
		field.Time("updated_at"),
	}
}

func (ImportJob) Indexes() []ent.Index {
	return []ent.Index{index.Fields("updated_at")}
}
