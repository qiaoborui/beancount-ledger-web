import crypto from "node:crypto";

const PREFIX = "v1";

function encryptionSecret(): string {
  const secret = process.env.GIT_TOKEN_ENCRYPTION_KEY || process.env.AUTH_SECRET || process.env.APP_PASSWORD;
  if (!secret) throw new Error("GIT_TOKEN_ENCRYPTION_KEY, AUTH_SECRET, or APP_PASSWORD is required to encrypt Git tokens");
  return secret;
}

function key(): Buffer {
  return crypto.createHash("sha256").update(encryptionSecret()).digest();
}

export function encryptToken(token: string): string {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", key(), iv);
  const ciphertext = Buffer.concat([cipher.update(token, "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();
  return [PREFIX, iv.toString("base64url"), tag.toString("base64url"), ciphertext.toString("base64url")].join(":");
}

export function decryptToken(encrypted: string): string {
  const [version, ivRaw, tagRaw, ciphertextRaw] = encrypted.split(":");
  if (version !== PREFIX || !ivRaw || !tagRaw || !ciphertextRaw) throw new Error("Invalid encrypted token format");
  const decipher = crypto.createDecipheriv("aes-256-gcm", key(), Buffer.from(ivRaw, "base64url"));
  decipher.setAuthTag(Buffer.from(tagRaw, "base64url"));
  return Buffer.concat([decipher.update(Buffer.from(ciphertextRaw, "base64url")), decipher.final()]).toString("utf8");
}
