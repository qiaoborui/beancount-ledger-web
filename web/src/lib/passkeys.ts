import fs from "node:fs";
import { passkeysPath } from "./ledgerPaths";

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

export function readPasskeyStore(): PasskeyStore {
  const file = passkeysPath();
  if (!fs.existsSync(file)) return { credentials: [] };
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

export function writePasskeyStore(store: PasskeyStore) {
  fs.writeFileSync(passkeysPath(), JSON.stringify(store, null, 2), { mode: 0o600 });
}

export function setCurrentChallenge(challenge: string) {
  const store = readPasskeyStore();
  store.currentChallenge = challenge;
  writePasskeyStore(store);
}

export function consumeCurrentChallenge(): string {
  const store = readPasskeyStore();
  if (!store.currentChallenge) throw new Error("No active passkey challenge");
  const challenge = store.currentChallenge;
  delete store.currentChallenge;
  writePasskeyStore(store);
  return challenge;
}

export function savePasskey(passkey: StoredPasskey) {
  const store = readPasskeyStore();
  store.credentials = store.credentials.filter((cred) => cred.id !== passkey.id);
  store.credentials.push(passkey);
  writePasskeyStore(store);
}

export function updatePasskeyCounter(id: string, counter: number) {
  const store = readPasskeyStore();
  store.credentials = store.credentials.map((cred) => cred.id === id ? { ...cred, counter } : cred);
  writePasskeyStore(store);
}

export function listPasskeys() {
  return readPasskeyStore().credentials;
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
