import fs from "node:fs";
import path from "node:path";
import bcrypt from "bcryptjs";
import { runtimeRoot } from "./ledgerPaths";

export type StoredUser = {
  id: string;
  passwordHash: string;
  createdAt: string;
  updatedAt: string;
};

type UserStore = { version: 1; users: StoredUser[] };

function usersPath() {
  const dir = path.join(runtimeRoot(), "auth");
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  return path.join(dir, "users.json");
}

function emptyStore(): UserStore {
  return { version: 1, users: [] };
}

export function normalizeUserId(userId: string): string {
  const normalized = userId.trim().toLowerCase();
  if (!/^[a-z0-9][a-z0-9_.-]{1,62}$/.test(normalized)) throw new Error("用户名需为 2-63 位小写字母、数字、点、下划线或短横线，并以字母/数字开头");
  return normalized;
}

export function readUserStore(): UserStore {
  const file = usersPath();
  if (!fs.existsSync(file)) return emptyStore();
  try {
    const parsed = JSON.parse(fs.readFileSync(file, "utf8")) as UserStore;
    return { version: 1, users: Array.isArray(parsed.users) ? parsed.users : [] };
  } catch {
    return emptyStore();
  }
}

function writeUserStore(store: UserStore) {
  fs.writeFileSync(usersPath(), `${JSON.stringify(store, null, 2)}\n`, { mode: 0o600 });
}

export function hasLocalUsers() {
  return readUserStore().users.length > 0;
}

export function createLocalUser(userId: string, password: string): StoredUser {
  const id = normalizeUserId(userId);
  if (password.length < 8) throw new Error("密码至少需要 8 位");
  const store = readUserStore();
  if (store.users.some((user) => user.id === id)) throw new Error("用户已存在");
  const now = new Date().toISOString();
  const user: StoredUser = {
    id,
    passwordHash: bcrypt.hashSync(password, 12),
    createdAt: now,
    updatedAt: now,
  };
  store.users.push(user);
  writeUserStore(store);
  return user;
}

export async function verifyLocalUserPassword(userId: string, password: string): Promise<boolean> {
  const id = normalizeUserId(userId);
  const user = readUserStore().users.find((item) => item.id === id);
  if (!user) return false;
  return bcrypt.compare(password, user.passwordHash);
}
