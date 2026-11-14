package mobileagent

// objectParameters is the single object-parameter schema builder of this
// package. The required names are variadic so call sites stay short.
//
// It always normalizes an empty required list: encoding/json marshals a nil
// []string as null, and the model side rejects "required": null with
// "at '/required': got null, want array" before the tool is ever called (that
// is exactly how list_saved_conversations broke). The key is omitted when
// nothing is mandatory — the same schema as an empty array, but never null.
//
// Every tool schema in this package goes through it so no schema can serialize
// a null field.
func objectParameters(properties map[string]any, required ...string) map[string]any {
	if properties == nil {
		properties = map[string]any{}
	}
	schema := map[string]any{"type": "object", "properties": properties, "additionalProperties": false}
	if len(required) > 0 {
		schema["required"] = required
	}
	return schema
}
