package schema

import (
	"entgo.io/ent"
	"entgo.io/ent/dialect/entsql"
	"entgo.io/ent/schema"
	"entgo.io/ent/schema/field"
	"entgo.io/ent/schema/index"
)

// GmailPendingImport keeps an independently actionable bill-import review item.
type GmailPendingImport struct{ ent.Schema }

func (GmailPendingImport) Annotations() []schema.Annotation {
	return []schema.Annotation{entsql.Annotation{Table: "gmail_pending_imports"}}
}
func (GmailPendingImport) Fields() []ent.Field {
	return []ent.Field{
		field.String("id").Immutable(), field.String("import_id").Optional(), field.String("source_key").Optional(), field.String("message_id"), field.String("thread_id").Optional(),
		field.String("sender"), field.String("subject"), field.Time("received_at").Optional().Nillable(), field.String("filename"), field.String("provider").Optional(), field.Int("candidate_count"),
		field.String("status"), field.String("error").Optional(), field.Time("created_at").Immutable(), field.Time("updated_at"), field.Int64("stored_bytes"), field.String("output_file").Optional(),
	}
}
func (GmailPendingImport) Indexes() []ent.Index {
	return []ent.Index{index.Fields("source_key"), index.Fields("import_id"), index.Fields("status", "updated_at"), index.Fields("created_at")}
}
