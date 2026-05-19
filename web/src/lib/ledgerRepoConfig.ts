import fs from "node:fs";
import { ledgerRootForUser, repoConfigPathForUser } from "./ledgerPaths";

export type UserLedgerRepoConfig = {
  provider: "github" | "git";
  owner?: string;
  repo?: string;
  branch?: string;
  remoteUrl: string;
  localPath: string;
  encryptedToken?: string;
  tokenUsername?: string;
  initializedAt?: string;
  lastSyncedAt?: string;
};

export type PublicUserLedgerRepoConfig = Omit<UserLedgerRepoConfig, "encryptedToken"> & {
  hasToken: boolean;
};

export function publicLedgerRepoConfig(config: UserLedgerRepoConfig): PublicUserLedgerRepoConfig {
  const { encryptedToken: _encryptedToken, ...safe } = config;
  return { ...safe, hasToken: Boolean(_encryptedToken) };
}

export function readLedgerRepoConfig(userId: string): UserLedgerRepoConfig | null {
  const file = repoConfigPathForUser(userId);
  if (!fs.existsSync(file)) return null;
  const parsed = JSON.parse(fs.readFileSync(file, "utf8")) as UserLedgerRepoConfig;
  return { ...parsed, localPath: parsed.localPath || ledgerRootForUser(userId) };
}

export function writeLedgerRepoConfig(userId: string, config: UserLedgerRepoConfig): UserLedgerRepoConfig {
  const next = { ...config, localPath: config.localPath || ledgerRootForUser(userId) };
  fs.writeFileSync(repoConfigPathForUser(userId), `${JSON.stringify(next, null, 2)}\n`, { mode: 0o600 });
  return next;
}

export function deleteLedgerRepoConfig(userId: string) {
  const file = repoConfigPathForUser(userId);
  if (fs.existsSync(file)) fs.rmSync(file);
}
