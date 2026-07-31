package schema

import (
	"entgo.io/ent"
	"entgo.io/ent/dialect/entsql"
	"entgo.io/ent/schema"
	"entgo.io/ent/schema/field"
	"entgo.io/ent/schema/index"
)

// ImportPreviewWarning keeps preview warnings independently addressable and in
// their original order instead of embedding a JSON array in the preview row.
type ImportPreviewWarning struct{ ent.Schema }

func (ImportPreviewWarning) Annotations() []schema.Annotation {
	return []schema.Annotation{entsql.Annotation{Table: "import_preview_warnings"}}
}

func (ImportPreviewWarning) Fields() []ent.Field {
	return []ent.Field{
		field.String("id").Immutable(),
		field.String("import_id").Immutable(),
		field.Int("position").Immutable(),
		field.String("message"),
	}
}

func (ImportPreviewWarning) Indexes() []ent.Index {
	return []ent.Index{index.Fields("import_id", "position").Unique()}
}
