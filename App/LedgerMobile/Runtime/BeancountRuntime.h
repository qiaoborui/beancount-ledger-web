#ifndef BEANCOUNT_RUNTIME_H
#define BEANCOUNT_RUNTIME_H

/// Returns NULL on success, or an owned UTF-8 error string.
char *BRInitialize(const char *bundle_path);
/// Returns owned UTF-8 JSON containing errors and the canonical read model.
char *BRValidate(const char *workspace_path, const char *entry_file);
/// Runs the same full validation, returning owned errors-only JSON (no read model).
char *BRValidateOnly(const char *workspace_path, const char *entry_file);
void BRFree(char *value);

#endif
