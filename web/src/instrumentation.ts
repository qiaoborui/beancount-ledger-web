export async function register() {
  if (process.env.NEXT_RUNTIME === "nodejs") {
    const { startLedgerScheduler } = await import("./lib/scheduler");
    startLedgerScheduler();
  }
}
