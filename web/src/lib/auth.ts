import { SignJWT, jwtVerify } from "jose";
import { cookies } from "next/headers";
import bcrypt from "bcryptjs";

const COOKIE_NAME = "ledger_session";
const SENSITIVE_COOKIE_NAME = "ledger_sensitive_until";
const SENSITIVE_UNLOCK_MAX_AGE_SECONDS = 15 * 60;

export function isAuthDisabled(): boolean {
  const raw = process.env.LEDGER_AUTH_DISABLED?.trim().toLowerCase();
  return raw === "1" || raw === "true" || raw === "yes" || raw === "on";
}

function secret(): Uint8Array {
  const raw = process.env.AUTH_SECRET || process.env.APP_PASSWORD;
  if (!raw) throw new Error("AUTH_SECRET or APP_PASSWORD is required");
  return new TextEncoder().encode(raw);
}

export async function verifyPassword(password: string): Promise<boolean> {
  const configured = process.env.APP_PASSWORD;
  if (!configured) throw new Error("APP_PASSWORD is required");
  if (configured.startsWith("$2a$") || configured.startsWith("$2b$") || configured.startsWith("$2y$")) {
    return bcrypt.compare(password, configured);
  }
  return password === configured;
}

export async function createSessionToken(): Promise<string> {
  return new SignJWT({ sub: "owner" })
    .setProtectedHeader({ alg: "HS256" })
    .setIssuedAt()
    .setExpirationTime("30d")
    .sign(secret());
}

export async function isAuthenticated(): Promise<boolean> {
  if (isAuthDisabled()) return true;
  const jar = await cookies();
  const token = jar.get(COOKIE_NAME)?.value;
  if (!token) return false;
  try {
    await jwtVerify(token, secret());
    return true;
  } catch {
    return false;
  }
}

export async function requireAuth(): Promise<void> {
  if (!(await isAuthenticated())) {
    throw new Response("Unauthorized", { status: 401 });
  }
}

export async function isSensitiveUnlocked(): Promise<boolean> {
  if (isAuthDisabled()) return true;
  const jar = await cookies();
  const raw = jar.get(SENSITIVE_COOKIE_NAME)?.value;
  const until = raw ? Number(raw) : 0;
  return Number.isFinite(until) && until > Date.now();
}

export async function requireSensitiveUnlock(): Promise<void> {
  await requireAuth();
  if (!(await isSensitiveUnlocked())) {
    throw new Response("Sensitive data is locked", { status: 423 });
  }
}

export async function setSensitiveUnlockCookie() {
  const jar = await cookies();
  jar.set(SENSITIVE_COOKIE_NAME, String(Date.now() + SENSITIVE_UNLOCK_MAX_AGE_SECONDS * 1000), {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    path: "/",
    maxAge: SENSITIVE_UNLOCK_MAX_AGE_SECONDS,
  });
}

export async function clearSensitiveUnlockCookie() {
  const jar = await cookies();
  jar.delete(SENSITIVE_COOKIE_NAME);
}

export async function setSessionCookie(token: string) {
  const jar = await cookies();
  jar.set(COOKIE_NAME, token, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    path: "/",
    maxAge: 60 * 60 * 24 * 30,
  });
}

export async function clearSessionCookie() {
  const jar = await cookies();
  jar.delete(COOKIE_NAME);
  jar.delete(SENSITIVE_COOKIE_NAME);
}
