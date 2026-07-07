import { readIndexedCache, writeIndexedCache } from "@/lib/indexedLedgerCache";
import { timeRangeCacheKey } from "@/lib/timeRange";
import type { TimeRange } from "@/lib/timeRange";
import type { LedgerCache } from "./types";

const configKey = "ledger_offline_unlock_config";
const encryptedCachePrefix = "ledger_encrypted_cache:";
const verifierPayload = "beancount-ledger-web:offline-unlock";
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

let sessionSecret: string | null = null;

function browserStorage() {
  if (typeof window !== "undefined") return window.localStorage;
  return globalThis.localStorage ?? null;
}

function readConfig(): OfflineUnlockConfig | null {
  try {
    const raw = browserStorage()?.getItem(configKey);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Partial<OfflineUnlockConfig>;
    if (parsed.version !== 1 || !parsed.salt || !parsed.verifierIv || !parsed.verifierCiphertext) return null;
    return { version: 1, salt: parsed.salt, iterations: parsed.iterations || iterations, verifierIv: parsed.verifierIv, verifierCiphertext: parsed.verifierCiphertext };
  } catch {
    return null;
  }
}

function writeConfig(config: OfflineUnlockConfig) {
  try {
    browserStorage()?.setItem(configKey, JSON.stringify(config));
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

function encryptedCacheKey(range: TimeRange, valuationCurrency: string) {
  return encryptedCachePrefix + timeRangeCacheKey(range, valuationCurrency);
}

export function hasOfflineLedgerUnlock() {
  return Boolean(readConfig());
}

export async function enableOfflineLedgerUnlock(secret: string) {
  if (secret.trim().length < 6) throw new Error("离线解锁码至少 6 位");
  const configBase = { version: 1 as const, salt: bytesToBase64(randomBytes(16)), iterations };
  const verifier = await encryptText(verifierPayload, secret, configBase);
  writeConfig({ ...configBase, verifierIv: verifier.iv, verifierCiphertext: verifier.ciphertext });
  sessionSecret = secret;
}

export async function verifyOfflineLedgerUnlock(secret: string) {
  const config = readConfig();
  if (!config) throw new Error("还没有设置离线解锁码");
  const text = await decryptText(config.verifierCiphertext, config.verifierIv, secret, config);
  if (text !== verifierPayload) throw new Error("离线解锁码不正确");
  sessionSecret = secret;
}

export async function writeEncryptedLedgerCache(range: TimeRange, cache: LedgerCache, valuationCurrency: string) {
  const config = readConfig();
  if (!config || !sessionSecret) return false;
  const encrypted = await encryptText(JSON.stringify(cache), sessionSecret, config);
  const record: EncryptedCacheRecord = { version: 1, valuationCurrency, savedAt: Date.now(), iv: encrypted.iv, ciphertext: encrypted.ciphertext };
  await writeIndexedCache(encryptedCacheKey(range, valuationCurrency), record);
  return true;
}

export async function readEncryptedLedgerCache(range: TimeRange, valuationCurrency: string, secret: string): Promise<LedgerCache | null> {
  const config = readConfig();
  if (!config) throw new Error("还没有设置离线解锁码");
  const record = await readIndexedCache<EncryptedCacheRecord>(encryptedCacheKey(range, valuationCurrency));
  if (!record?.ciphertext || !record.iv) return null;
  const text = await decryptText(record.ciphertext, record.iv, secret, config);
  await verifyOfflineLedgerUnlock(secret);
  return JSON.parse(text) as LedgerCache;
}
