import { deleteIndexedCache, readIndexedCache, writeIndexedCache } from "@/lib/indexedLedgerCache";
import { timeRangeCacheKey } from "@/lib/timeRange";
import type { TimeRange } from "@/lib/timeRange";
import type { LedgerCache } from "./types";
import { apiEndpointLedgerScope, apiEndpointPreviousLedgerScope, apiEndpointStorageKeyForLedgerScope } from "@/lib/apiEndpoints";

const configKey = "ledger_offline_unlock_config";
const encryptedCachePrefix = "ledger_encrypted_cache:";
const verifierPayload = "beancount-ledger-web:offline-unlock";
const legacyEncryptedCacheScopeKey = "ledger_encrypted_cache_legacy_scope:v1";
const iterations = 210_000;

type OfflineUnlockConfig = {
  version: 1;
  salt: string;
  iterations: number;
  verifierIv: string;
  verifierCiphertext: string;
};

type EncryptedCacheRecord = {
  version: 1;
  valuationCurrency: string;
  savedAt: number;
  iv: string;
  ciphertext: string;
};

const sessionSecrets = new Map<string, string>();

function browserStorage() {
  if (typeof window !== "undefined") return window.localStorage;
  return globalThis.localStorage ?? null;
}

function scopedConfigKey(ledgerScope: string) {
  return apiEndpointStorageKeyForLedgerScope(configKey, ledgerScope);
}

function readConfig(ledgerScope = apiEndpointLedgerScope()): OfflineUnlockConfig | null {
  try {
    const storage = browserStorage();
    const key = scopedConfigKey(ledgerScope);
    const scoped = storage?.getItem(key);
    const previousScope = apiEndpointPreviousLedgerScope();
    const previousKey = previousScope ? scopedConfigKey(previousScope) : undefined;
    const previous = previousKey ? storage?.getItem(previousKey) : null;
    const raw = scoped ?? previous ?? storage?.getItem(configKey);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Partial<OfflineUnlockConfig>;
    if (parsed.version !== 1 || !parsed.salt || !parsed.verifierIv || !parsed.verifierCiphertext) return null;
    const config = { version: 1, salt: parsed.salt, iterations: parsed.iterations || iterations, verifierIv: parsed.verifierIv, verifierCiphertext: parsed.verifierCiphertext } satisfies OfflineUnlockConfig;
    if (!scoped && storage) {
      try {
        const serialized = JSON.stringify(config);
        storage.setItem(key, serialized);
        if (storage.getItem(key) === serialized) {
          if (previousKey && previous) storage.removeItem(previousKey);
          storage.removeItem(configKey);
          if (previousScope) {
            const previousSecret = sessionSecrets.get(previousScope);
            if (previousSecret) {
              sessionSecrets.set(ledgerScope, previousSecret);
              sessionSecrets.delete(previousScope);
            }
          }
        }
      } catch {
        // Keep using the legacy config until scoped storage is writable.
      }
    }
    return config;
  } catch {
    return null;
  }
}

function writeConfig(config: OfflineUnlockConfig, ledgerScope = apiEndpointLedgerScope()) {
  try {
    browserStorage()?.setItem(scopedConfigKey(ledgerScope), JSON.stringify(config));
  } catch {
    // Local storage may be unavailable in private mode.
  }
}

function bytesToBase64(bytes: Uint8Array) {
  if (typeof btoa === "function") {
    let value = "";
    for (const byte of bytes) value += String.fromCharCode(byte);
    return btoa(value);
  }
  return Buffer.from(bytes).toString("base64");
}

function base64ToBytes(value: string) {
  if (typeof atob === "function") {
    const decoded = atob(value);
    return Uint8Array.from(decoded, (char) => char.charCodeAt(0));
  }
  return Uint8Array.from(Buffer.from(value, "base64"));
}

function randomBytes(length: number) {
  const bytes = new Uint8Array(length);
  crypto.getRandomValues(bytes);
  return bytes;
}

function arrayBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

function requireSubtleCrypto() {
  if (typeof crypto === "undefined" || !crypto.subtle) throw new Error("当前浏览器不支持本地加密");
  return crypto.subtle;
}

async function deriveKey(secret: string, salt: Uint8Array, rounds: number) {
  const subtle = requireSubtleCrypto();
  const source = await subtle.importKey("raw", new TextEncoder().encode(secret), "PBKDF2", false, ["deriveKey"]);
  return subtle.deriveKey(
    { name: "PBKDF2", hash: "SHA-256", salt: arrayBuffer(salt), iterations: rounds },
    source,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

async function encryptText(text: string, secret: string, config: Pick<OfflineUnlockConfig, "salt" | "iterations">) {
  const subtle = requireSubtleCrypto();
  const iv = randomBytes(12);
  const key = await deriveKey(secret, base64ToBytes(config.salt), config.iterations);
  const ciphertext = await subtle.encrypt({ name: "AES-GCM", iv: arrayBuffer(iv) }, key, new TextEncoder().encode(text));
  return { iv: bytesToBase64(iv), ciphertext: bytesToBase64(new Uint8Array(ciphertext)) };
}

async function decryptText(ciphertext: string, iv: string, secret: string, config: Pick<OfflineUnlockConfig, "salt" | "iterations">) {
  const subtle = requireSubtleCrypto();
  const key = await deriveKey(secret, base64ToBytes(config.salt), config.iterations);
  const plaintext = await subtle.decrypt({ name: "AES-GCM", iv: arrayBuffer(base64ToBytes(iv)) }, key, arrayBuffer(base64ToBytes(ciphertext)));
  return new TextDecoder().decode(plaintext);
}

function encryptedCacheKey(range: TimeRange, valuationCurrency: string, ledgerScope: string) {
  return apiEndpointStorageKeyForLedgerScope(encryptedCachePrefix + timeRangeCacheKey(range, valuationCurrency), ledgerScope);
}

function legacyEncryptedCacheBelongsToScope(ledgerScope: string) {
  const storage = browserStorage();
  if (!storage) return false;
  try {
    const claimed = storage.getItem(legacyEncryptedCacheScopeKey);
    if (claimed) {
      if (claimed === ledgerScope) return true;
      if (claimed === apiEndpointPreviousLedgerScope() && ledgerScope.startsWith("cluster:")) {
        storage.setItem(legacyEncryptedCacheScopeKey, ledgerScope);
        return storage.getItem(legacyEncryptedCacheScopeKey) === ledgerScope;
      }
      return false;
    }
    storage.setItem(legacyEncryptedCacheScopeKey, ledgerScope);
    return storage.getItem(legacyEncryptedCacheScopeKey) === ledgerScope;
  } catch {
    return false;
  }
}

export function hasOfflineLedgerUnlock() {
  return Boolean(readConfig());
}

export async function enableOfflineLedgerUnlock(secret: string) {
  if (secret.trim().length < 6) throw new Error("离线解锁码至少 6 位");
  const ledgerScope = apiEndpointLedgerScope();
  const configBase = { version: 1 as const, salt: bytesToBase64(randomBytes(16)), iterations };
  const verifier = await encryptText(verifierPayload, secret, configBase);
  writeConfig({ ...configBase, verifierIv: verifier.iv, verifierCiphertext: verifier.ciphertext }, ledgerScope);
  sessionSecrets.set(ledgerScope, secret);
}

export async function verifyOfflineLedgerUnlock(secret: string, ledgerScope = apiEndpointLedgerScope()) {
  const config = readConfig(ledgerScope);
  if (!config) throw new Error("还没有设置离线解锁码");
  const text = await decryptText(config.verifierCiphertext, config.verifierIv, secret, config);
  if (text !== verifierPayload) throw new Error("离线解锁码不正确");
  sessionSecrets.set(ledgerScope, secret);
}

export async function writeEncryptedLedgerCache(range: TimeRange, cache: LedgerCache, valuationCurrency: string, ledgerScope = apiEndpointLedgerScope()) {
  const config = readConfig(ledgerScope);
  const sessionSecret = sessionSecrets.get(ledgerScope);
  if (!config || !sessionSecret) return false;
  const encrypted = await encryptText(JSON.stringify(cache), sessionSecret, config);
  const record: EncryptedCacheRecord = { version: 1, valuationCurrency, savedAt: Date.now(), iv: encrypted.iv, ciphertext: encrypted.ciphertext };
  await writeIndexedCache(encryptedCacheKey(range, valuationCurrency, ledgerScope), record);
  return true;
}

export async function readEncryptedLedgerCache(range: TimeRange, valuationCurrency: string, secret: string, ledgerScope = apiEndpointLedgerScope()): Promise<LedgerCache | null> {
  const config = readConfig(ledgerScope);
  if (!config) throw new Error("还没有设置离线解锁码");
  const scopedKey = encryptedCacheKey(range, valuationCurrency, ledgerScope);
  let record = await readIndexedCache<EncryptedCacheRecord>(scopedKey);
  const previousScope = apiEndpointPreviousLedgerScope();
  if (!record && previousScope) {
    const previousKey = encryptedCacheKey(range, valuationCurrency, previousScope);
    const previous = await readIndexedCache<EncryptedCacheRecord>(previousKey);
    if (previous && await writeIndexedCache(scopedKey, previous)) await deleteIndexedCache(previousKey);
    record = previous;
  }
  if (!record && legacyEncryptedCacheBelongsToScope(ledgerScope)) {
    const legacyKey = encryptedCachePrefix + timeRangeCacheKey(range, valuationCurrency);
    const legacy = await readIndexedCache<EncryptedCacheRecord>(legacyKey);
    if (legacy && await writeIndexedCache(scopedKey, legacy)) {
      await deleteIndexedCache(legacyKey);
    }
    record = legacy;
  }
  if (!record?.ciphertext || !record.iv) return null;
  const text = await decryptText(record.ciphertext, record.iv, secret, config);
  await verifyOfflineLedgerUnlock(secret, ledgerScope);
  return JSON.parse(text) as LedgerCache;
}
