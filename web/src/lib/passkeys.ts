import fs from "node:fs";
import { passkeysPathForUser } from "./ledgerPaths";

export type StoredPasskey = {
  id: string;
  publicKey: string;
  counter: number;
  transports?: AuthenticatorTransport[];
};

type PasskeyStore = {
  currentChallenge?: string;
  credentials: StoredPasskey[];
};

export function readPasskeyStoreForUser(userId: string): PasskeyStore {
  const file = passkeysPathForUser(userId);
  if (!fs.existsSync(file)) return { credentials: [] };
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

export function readPasskeyStore(): PasskeyStore {
  return readPasskeyStoreForUser("owner");
}

export function writePasskeyStoreForUser(userId: string, store: PasskeyStore) {
  fs.writeFileSync(passkeysPathForUser(userId), JSON.stringify(store, null, 2), { mode: 0o600 });
}

export function writePasskeyStore(store: PasskeyStore) {
  writePasskeyStoreForUser("owner", store);
}

export function setCurrentChallengeForUser(userId: string, challenge: string) {
  const store = readPasskeyStoreForUser(userId);
  store.currentChallenge = challenge;
  writePasskeyStoreForUser(userId, store);
}

export function setCurrentChallenge(challenge: string) {
  setCurrentChallengeForUser("owner", challenge);
}

export function consumeCurrentChallengeForUser(userId: string): string {
  const store = readPasskeyStoreForUser(userId);
  if (!store.currentChallenge) throw new Error("No active passkey challenge");
  const challenge = store.currentChallenge;
  delete store.currentChallenge;
  writePasskeyStoreForUser(userId, store);
  return challenge;
}

export function consumeCurrentChallenge(): string {
  return consumeCurrentChallengeForUser("owner");
}

export function savePasskeyForUser(userId: string, passkey: StoredPasskey) {
  const store = readPasskeyStoreForUser(userId);
  store.credentials = store.credentials.filter((cred) => cred.id !== passkey.id);
  store.credentials.push(passkey);
  writePasskeyStoreForUser(userId, store);
}

export function savePasskey(passkey: StoredPasskey) {
  savePasskeyForUser("owner", passkey);
}

export function updatePasskeyCounterForUser(userId: string, id: string, counter: number) {
  const store = readPasskeyStoreForUser(userId);
  store.credentials = store.credentials.map((cred) => cred.id === id ? { ...cred, counter } : cred);
  writePasskeyStoreForUser(userId, store);
}

export function updatePasskeyCounter(id: string, counter: number) {
  updatePasskeyCounterForUser("owner", id, counter);
}

export function listPasskeysForUser(userId: string) {
  return readPasskeyStoreForUser(userId).credentials;
}

export function listPasskeys() {
  return listPasskeysForUser("owner");
}

export function rpIDFromRequest(request: Request) {
  const host = request.headers.get("x-forwarded-host") ?? new URL(request.url).host;
  return host.split(":")[0];
}

export function originFromRequest(request: Request) {
  const proto = request.headers.get("x-forwarded-proto") ?? new URL(request.url).protocol.replace(":", "");
  const host = request.headers.get("x-forwarded-host") ?? new URL(request.url).host;
  return `${proto}://${host}`;
}
