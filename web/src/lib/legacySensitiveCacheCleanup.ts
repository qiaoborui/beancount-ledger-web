import { deleteIndexedCachesByPrefixes } from "./indexedLedgerCache";

const cleanupCompletedKey = "ledger_legacy_sensitive_cache_cleanup:v1";
const legacyConfigPrefix = "ledger_offline_unlock_config";
const legacyEncryptedCachePrefix = "ledger_encrypted_cache:";
const legacyEncryptedCacheScopeKey = "ledger_encrypted_cache_legacy_scope:v1";

type CleanupStorage = Pick<Storage, "getItem" | "setItem" | "removeItem" | "key" | "length">;

function browserStorage() {
  return typeof window === "undefined" ? null : window.localStorage;
}

export async function purgeLegacySensitiveCacheStorage(
  storage: CleanupStorage | null = browserStorage(),
  deleteIndexed = deleteIndexedCachesByPrefixes,
) {
  if (!storage) return false;
  try {
    if (storage.getItem(cleanupCompletedKey) === "1") return true;
    const keys = Array.from({ length: storage.length }, (_, index) => storage.key(index)).filter((key): key is string => Boolean(key));
    for (const key of keys) {
      if (key.startsWith(legacyConfigPrefix) || key.startsWith(legacyEncryptedCachePrefix) || key === legacyEncryptedCacheScopeKey) {
        storage.removeItem(key);
      }
    }
    if (!await deleteIndexed([legacyEncryptedCachePrefix])) return false;
    storage.setItem(cleanupCompletedKey, "1");
    return storage.getItem(cleanupCompletedKey) === "1";
  } catch {
    return false;
  }
}
