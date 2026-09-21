#ifndef BEANCOUNT_RUNTIME_H
#define BEANCOUNT_RUNTIME_H

/// Returns NULL on success, or an owned UTF-8 error string.
char *BRInitialize(const char *bundle_path);
/// Returns owned UTF-8 JSON containing errors and the canonical read model.
char *BRValidate(const char *workspace_path, const char *entry_file);
/// Runs the same full validation, returning owned errors-only JSON (no read model).
char *BRValidateOnly(const char *workspace_path, const char *entry_file);
/// Maximum returned BRExportStream JSON size in UTF-8 bytes, excluding NUL.
#define BR_EXPORT_STREAM_MAX_RESPONSE_BYTES 1024
/// Export bounded-v1 JSONL directly to derived_directory/spool_name, exclusively.
/// Caller must initialize Python, freeze the source generation and supply an
/// existing owned 0700 directory outside the ledger with iOS data protection
/// already applied. All directory components must be non-symlinks. Paths are
/// absolute; entry_file is workspace-relative; spool_name is a fresh ASCII
/// basename (1-128 characters: alphanumeric first, then alphanumeric, '.', '_',
/// '-'). No directory is created and no existing spool is overwritten.
/// Returns owned NUL-terminated UTF-8 JSON, <= the limit above, with either
/// {"ok":true,"summary":{records,directives,postings,source_digest,sha256}} or
/// {"ok":false,"error":{"code":...,"message":...}} with fixed public errors.
/// No private paths/exception text or snapshot is returned. NULL means allocation
/// failure. Free every non-NULL return with BRFree, including error responses.
/// On success the caller owns spool consumption/deletion; on failure never use
/// the spool. The exporter removes its own partial inode on export failure.
/// A completed spool can remain if response allocation fails; caller must reap
/// abandoned generations in its protected directory (never unrelated files).
/// Python still holds the canonical O(N) AST; only export transport is bounded.
char *BRExportStream(const char *workspace_path, const char *entry_file,
                     const char *derived_directory, const char *spool_name);
/// Frees strings returned by any BR function; NULL is allowed.
void BRFree(char *value);

#endif
