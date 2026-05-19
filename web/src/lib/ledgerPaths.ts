import fs from "node:fs";
import path from "node:path";

export type LedgerContext = { userId: string };

const DEFAULT_USER_ID = "owner";

export function appRoot(): string {
  return path.resolve(process.cwd(), "..");
}

export function defaultUserId(): string {
  return DEFAULT_USER_ID;
}

function legacyLedgerRoot(): string {
  return path.resolve(process.env.LEDGER_ROOT ?? path.join(appRoot(), "examples", "minimal-ledger"));
}

function baseRuntimeRoot(): string {
  return path.resolve(process.env.RUNTIME_DIR ?? path.join(legacyLedgerRoot(), ".runtime"));
}

export function usersRoot(): string {
  return path.join(baseRuntimeRoot(), "users");
}

export function userWorkspaceRoot(userId: string): string {
  return path.join(usersRoot(), safeUserId(userId));
}

export function ledgerRootForUser(userId: string): string {
  // Preserve the existing single-user deployment behavior for the legacy owner.
  if (safeUserId(userId) === DEFAULT_USER_ID && process.env.LEDGER_ROOT) return legacyLedgerRoot();
  return path.join(userWorkspaceRoot(userId), "ledger");
}

export function runtimeRootForUser(userId: string): string {
  // Preserve existing runtime behavior for the legacy owner when RUNTIME_DIR is explicitly configured.
  if (safeUserId(userId) === DEFAULT_USER_ID && process.env.RUNTIME_DIR) return baseRuntimeRoot();
  return path.join(userWorkspaceRoot(userId), "runtime");
}

export function ensureRuntimeDirForUser(userId: string): string {
  const dir = runtimeRootForUser(userId);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  return dir;
}

export function ensureLedgerRootForUser(userId: string): string {
  const dir = ledgerRootForUser(userId);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  return dir;
}

function safeUserId(userId: string): string {
  const normalized = userId.trim() || DEFAULT_USER_ID;
  if (!/^[A-Za-z0-9_.-]+$/.test(normalized)) throw new Error("Invalid user id");
  return normalized;
}

export function mainBeanPathForUser(userId: string): string {
  return path.join(ledgerRootForUser(userId), "main.bean");
}

export function transactionsDirForUser(userId: string): string {
  return path.join(ledgerRootForUser(userId), "transactions");
}

export function transactionFileForDateForUser(userId: string, date: string): string {
  const match = date.match(/^(\d{4})-(\d{2})-\d{2}$/);
  if (!match) throw new Error(`Invalid ledger date: ${date}`);
  return path.join(transactionsDirForUser(userId), match[1], `${match[2]}.bean`);
}

export function budgetsBeanPathForUser(userId: string): string {
  return path.join(ledgerRootForUser(userId), "budgets.bean");
}

export function accountsBeanPathForUser(userId: string): string {
  return path.join(ledgerRootForUser(userId), "accounts.bean");
}

export function notificationsPathForUser(userId: string): string {
  return path.join(ensureRuntimeDirForUser(userId), "notifications.json");
}

export function webPushSubscriptionsPathForUser(userId: string): string {
  return path.join(ensureRuntimeDirForUser(userId), "webpush-subscriptions.json");
}

export function passkeysPathForUser(userId: string): string {
  return path.join(ensureRuntimeDirForUser(userId), "passkeys.json");
}

export function ledgerWriteLockPathForUser(userId: string): string {
  return path.join(ensureRuntimeDirForUser(userId), "ledger-write.lock");
}

export function repoConfigPathForUser(userId: string): string {
  return path.join(ensureRuntimeDirForUser(userId), "repo-config.json");
}

// Backward-compatible owner wrappers.
export function ledgerRoot(): string {
  return ledgerRootForUser(DEFAULT_USER_ID);
}

export function runtimeRoot(): string {
  return runtimeRootForUser(DEFAULT_USER_ID);
}

export function mainBeanPath(): string {
  return mainBeanPathForUser(DEFAULT_USER_ID);
}

export function transactionsDir(): string {
  return transactionsDirForUser(DEFAULT_USER_ID);
}

export function transactionFileForDate(date: string): string {
  return transactionFileForDateForUser(DEFAULT_USER_ID, date);
}

export function budgetsBeanPath(): string {
  return budgetsBeanPathForUser(DEFAULT_USER_ID);
}

export function accountsBeanPath(): string {
  return accountsBeanPathForUser(DEFAULT_USER_ID);
}

export function notificationsPath(): string {
  return notificationsPathForUser(DEFAULT_USER_ID);
}

export function webPushSubscriptionsPath(): string {
  return webPushSubscriptionsPathForUser(DEFAULT_USER_ID);
}

export function passkeysPath(): string {
  return passkeysPathForUser(DEFAULT_USER_ID);
}

export function ledgerWriteLockPath(): string {
  return ledgerWriteLockPathForUser(DEFAULT_USER_ID);
}
