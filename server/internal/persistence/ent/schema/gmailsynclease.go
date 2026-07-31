package schema

import (
	"entgo.io/ent"
	"entgo.io/ent/dialect/entsql"
	"entgo.io/ent/schema"
	"entgo.io/ent/schema/field"
)

// GmailSyncLease coordinates one active synchronization across application instances.
type GmailSyncLease struct{ ent.Schema }

func (GmailSyncLease) Annotations() []schema.Annotation {
	return []schema.Annotation{entsql.Annotation{Table: "gmail_sync_leases"}}
}
func (GmailSyncLease) Fields() []ent.Field {
	return []ent.Field{field.String("id").StorageKey("name").Immutable(), field.String("owner"), field.Time("expires_at")}
}
