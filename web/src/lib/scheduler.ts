import { gitCommitPullPush, gitPullRebase } from "./gitOps";

const globalForScheduler = globalThis as typeof globalThis & {
  __ledgerSchedulerStarted?: boolean;
  __ledgerSchedulerTimers?: NodeJS.Timeout[];
};

function intervalMs(name: string, fallbackMinutes: number) {
  const raw = process.env[name];
  if (!raw) return fallbackMinutes * 60 * 1000;
  const minutes = Number(raw);
  if (!Number.isFinite(minutes) || minutes <= 0) return 0;
  return minutes * 60 * 1000;
}

function enabled() {
  return process.env.LEDGER_GIT_SCHEDULER !== "false";
}

function runJob(name: string, job: () => string) {
  try {
    const output = job();
    console.log(`[ledger-scheduler] ${name} ok\n${output}`);
  } catch (error) {
    console.error(`[ledger-scheduler] ${name} failed`, error);
  }
}

export function startLedgerScheduler() {
  if (globalForScheduler.__ledgerSchedulerStarted || !enabled()) return;
  globalForScheduler.__ledgerSchedulerStarted = true;
  globalForScheduler.__ledgerSchedulerTimers = [];

  const pullMs = intervalMs("LEDGER_GIT_PULL_INTERVAL_MINUTES", 15);
  const commitMs = intervalMs("LEDGER_GIT_COMMIT_INTERVAL_MINUTES", 60);

  if (pullMs > 0) {
    const timer = setInterval(() => runJob("pull", gitPullRebase), pullMs);
    timer.unref?.();
    globalForScheduler.__ledgerSchedulerTimers.push(timer);
    setTimeout(() => runJob("startup-pull", gitPullRebase), 1500).unref?.();
  }

  if (commitMs > 0) {
    const timer = setInterval(() => runJob("commit-push", () => gitCommitPullPush("chore: autosave ledger").output), commitMs);
    timer.unref?.();
    globalForScheduler.__ledgerSchedulerTimers.push(timer);
  }

  console.log(`[ledger-scheduler] started pull=${pullMs / 60000}m commit=${commitMs / 60000}m`);
}
