#ifndef BEANCOUNT_RUNTIME_H
#define BEANCOUNT_RUNTIME_H

/// Returns NULL on success, or an owned UTF-8 error string.
char *BRInitialize(const char *bundle_path);
/// Returns owned UTF-8 JSON containing canonical validation errors.
char *BRValidate(const char *workspace_path, const char *entry_file);
void BRFree(char *value);

#endif
