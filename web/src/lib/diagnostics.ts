type LogFields = Record<string, string | number | boolean | null | undefined>;

function timingLogsDisabled() {
  const raw = process.env.LEDGER_TIMING_LOGS_DISABLED?.trim().toLowerCase();
  return raw === "1" || raw === "true" || raw === "yes" || raw === "on";
}

export function logDuration(name: string, startedAt: number, fields: LogFields = {}) {
  if (timingLogsDisabled()) return;
  const elapsedMs = Date.now() - startedAt;
  console.info(`[ledger] ${name}`, { ...fields, elapsedMs });
}
