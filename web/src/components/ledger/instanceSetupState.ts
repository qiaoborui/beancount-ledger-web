import { fetchJson } from "@/lib/clientFetch";

export type IndexerDiagnostics = {
  reachable: boolean;
  attempts: number;
  firstIndexSucceeded: boolean;
  lastAttempt?: string;
  lastSuccess?: string;
  lastError?: string;
  lastRevision?: number;
};

export type InstanceSetupStatus = {
  setupRequired: boolean;
  setupComplete?: boolean;
  configSource?: string;
  readiness?: {
    state: "setup_required" | "indexing" | "ready" | "database_error" | "indexer_unavailable" | "indexer_error";
    active?: boolean;
    error?: string;
    indexer?: IndexerDiagnostics;
  };
  operations?: {
    logsCommand?: string;
    recoverInstallCodeCommand?: string;
  };
};

export type InstanceSetupGateState =
  | { kind: "checking" }
  | { kind: "required"; status: InstanceSetupStatus }
  | { kind: "ready"; status: InstanceSetupStatus }
  | { kind: "unavailable"; error: string };

type SetupStatusFetcher = () => Promise<InstanceSetupStatus>;

export async function loadInstanceSetupState(fetcher: SetupStatusFetcher = () => fetchJson<InstanceSetupStatus>("/api/setup/status", { cache: "no-store" }, undefined, { kind: "health" })): Promise<InstanceSetupGateState> {
  try {
    const status = await fetcher();
    if (typeof status.setupRequired !== "boolean") throw new Error("Setup status response is incomplete");
    return status.setupRequired ? { kind: "required", status } : { kind: "ready", status };
  } catch (cause) {
    return { kind: "unavailable", error: cause instanceof Error ? cause.message : "Setup status request failed" };
  }
}
