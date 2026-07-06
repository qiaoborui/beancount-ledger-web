import { fetchJson, readJson } from "@/lib/clientFetch";

export type QuickUnlockMode = "numeric" | "text";

const configKey = "ledger_quick_unlock_config";
const iterations = 210_000;

type QuickUnlockConfig = {
  version: 1;
  deviceId: string;
  mode: QuickUnlockMode;
  salt: string;
  iterations: number;
  tokenIv: string;
  tokenCiphertext: string;
  createdAt: number;
};

type QuickUnlockRegisterResponse = {
  deviceId: string;
  token: string;
};

function browserStorage() {
  if (typeof window !== "undefined") return window.localStorage;
  return globalThis.localStorage ?? null;
}

function readConfig(): QuickUnlockConfig | null {
  try {
    const raw = browserStorage()?.getItem(configKey);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Partial<QuickUnlockConfig>;
    if (parsed.version !== 1 || !parsed.deviceId || !parsed.mode || !parsed.salt || !parsed.tokenIv || !parsed.tokenCiphertext) return null;
    if (parsed.mode !== "numeric" && parsed.mode !== "text") return null;
    return {
      version: 1,
      deviceId: parsed.deviceId,
      mode: parsed.mode,
      salt: parsed.salt,
      iterations: parsed.iterations || iterations,
      tokenIv: parsed.tokenIv,
      tokenCiphertext: parsed.tokenCiphertext,
      createdAt: parsed.createdAt || Date.now(),
    };
  } catch {
    return null;
  }
}

function writeConfig(config: QuickUnlockConfig) {
  browserStorage()?.setItem(configKey, JSON.stringify(config));
}

export function removeQuickLedgerUnlock() {
  try {
    browserStorage()?.removeItem(configKey);
  } catch {
    // Storage may be unavailable in private mode.
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

async function encryptText(text: string, secret: string, config: Pick<QuickUnlockConfig, "salt" | "iterations">) {
  const subtle = requireSubtleCrypto();
  const iv = randomBytes(12);
  const key = await deriveKey(secret, base64ToBytes(config.salt), config.iterations);
  const ciphertext = await subtle.encrypt({ name: "AES-GCM", iv: arrayBuffer(iv) }, key, new TextEncoder().encode(text));
  return { iv: bytesToBase64(iv), ciphertext: bytesToBase64(new Uint8Array(ciphertext)) };
}

async function decryptText(ciphertext: string, iv: string, secret: string, config: Pick<QuickUnlockConfig, "salt" | "iterations">) {
  const subtle = requireSubtleCrypto();
  const key = await deriveKey(secret, base64ToBytes(config.salt), config.iterations);
  const plaintext = await subtle.decrypt({ name: "AES-GCM", iv: arrayBuffer(base64ToBytes(iv)) }, key, arrayBuffer(base64ToBytes(ciphertext)));
  return new TextDecoder().decode(plaintext);
}

export function preferredQuickUnlockMode(): QuickUnlockMode {
  if (typeof window === "undefined") return "text";
  if (window.matchMedia("(pointer: coarse)").matches || window.matchMedia("(max-width: 640px)").matches) return "numeric";
  return "text";
}

export function getQuickLedgerUnlockMode(): QuickUnlockMode {
  return readConfig()?.mode ?? preferredQuickUnlockMode();
}

export function hasQuickLedgerUnlock() {
  return Boolean(readConfig());
}

export function quickUnlockSecretIsValid(secret: string, mode: QuickUnlockMode) {
  if (secret.length === 0) return false;
  return mode === "text" || /^\d+$/.test(secret);
}

function defaultDeviceName(mode: QuickUnlockMode) {
  if (typeof navigator === "undefined") return mode === "numeric" ? "Mobile browser" : "Desktop browser";
  const platform = navigator.platform || "Browser";
  return `${platform} ${mode === "numeric" ? "numeric" : "text"} unlock`;
}

export async function enableQuickLedgerUnlock(secret: string, mode: QuickUnlockMode) {
  if (!quickUnlockSecretIsValid(secret, mode)) throw new Error(mode === "numeric" ? "请输入数字解锁码" : "请输入本机解锁口令");
  const registered = await fetchJson<QuickUnlockRegisterResponse>("/api/quick-unlock/register", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ mode, name: defaultDeviceName(mode) }),
  });
  const configBase = { version: 1 as const, deviceId: registered.deviceId, mode, salt: bytesToBase64(randomBytes(16)), iterations, createdAt: Date.now() };
  const encrypted = await encryptText(registered.token, secret, configBase);
  writeConfig({ ...configBase, tokenIv: encrypted.iv, tokenCiphertext: encrypted.ciphertext });
}

export async function unlockWithQuickLedgerSecret(secret: string) {
  const config = readConfig();
  if (!config) throw new Error("还没有设置本机快速解锁");
  if (!quickUnlockSecretIsValid(secret, config.mode)) throw new Error(config.mode === "numeric" ? "请输入数字解锁码" : "请输入本机解锁口令");
  const token = await decryptText(config.tokenCiphertext, config.tokenIv, secret, config);
  const verify = await fetch("/api/quick-unlock/verify", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ deviceId: config.deviceId, token }),
  });
  const data = await readJson<{ error?: string }>(verify);
  if (!verify.ok) throw new Error(data.error || "快速解锁失败");
}

export async function revokeQuickLedgerUnlock() {
  const config = readConfig();
  removeQuickLedgerUnlock();
  if (!config) return;
  const res = await fetch("/api/quick-unlock/revoke", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ deviceId: config.deviceId }),
  });
  if (!res.ok) {
    const data = await readJson<{ error?: string }>(res);
    throw new Error(data.error || "撤销快速解锁失败");
  }
}
