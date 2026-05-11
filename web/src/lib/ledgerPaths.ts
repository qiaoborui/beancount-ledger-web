import fs from "node:fs";
import path from "node:path";

export function appRoot(): string {
  return path.resolve(process.cwd(), "..");
}

export function ledgerRoot(): string {
  return path.resolve(process.env.LEDGER_ROOT ?? path.join(appRoot(), "examples", "minimal-ledger"));
}

export function runtimeRoot(): string {
  return path.resolve(process.env.RUNTIME_DIR ?? path.join(ledgerRoot(), ".runtime"));
}

function ensureRuntimeDir(): string {
  const dir = runtimeRoot();
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  return dir;
}

export function mainBeanPath(): string {
  return path.join(ledgerRoot(), "main.bean");
}

export function transactionsDir(): string {
  return path.join(ledgerRoot(), "transactions");
}

export function transactionFileForYear(year: number): string {
  return path.join(transactionsDir(), `${year}.bean`);
}

export function budgetsBeanPath(): string {
  return path.join(ledgerRoot(), "budgets.bean");
}

export function accountsBeanPath(): string {
  return path.join(ledgerRoot(), "accounts.bean");
}

export function notificationsPath(): string {
  return path.join(ensureRuntimeDir(), "notifications.json");
}

export function webPushSubscriptionsPath(): string {
  return path.join(ensureRuntimeDir(), "webpush-subscriptions.json");
}

export function passkeysPath(): string {
  return path.join(ensureRuntimeDir(), "passkeys.json");
}

export function ledgerWriteLockPath(): string {
  return path.join(ensureRuntimeDir(), "ledger-write.lock");
}
