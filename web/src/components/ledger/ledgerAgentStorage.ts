import { apiEndpointLedgerScope } from "@/lib/apiEndpoints";
import { readIndexedCache, writeIndexedCache } from "@/lib/indexedLedgerCache";
import type { AgentArtifact, AgentToolEvent } from "@/lib/ledgerAgentStream";

export type MessageItem = { kind: "message"; id: string; role: "user" | "assistant"; content: string };
export type ToolItem = { kind: "tool"; id: string; tool: AgentToolEvent };
export type ArtifactItem = { kind: "artifact"; id: string; artifact: AgentArtifact };
export type TimelineItem = MessageItem | ToolItem | ArtifactItem;
export type AgentSession = { id: string; serverSessionId: string; title: string; archived: boolean; createdAt: number; updatedAt: number; timelineState: "available" | "missing"; timeline: TimelineItem[] };
export type StoredAgentWorkspace = { activeSessionId: string; sessions: AgentSession[]; deletedServerSessionIds: string[]; savedAt?: number };

type IndexedAgentWorkspace = StoredAgentWorkspace & {
  version: 1;
  ledgerScope: string;
  savedAt: number;
};

const metadataKeyPrefix = "ledger.agent.workspace.v2";
const indexedKeyPrefix = "ledger.agent.workspace.v3";
const workspaceWriteChains = new Map<string, Promise<boolean>>();

export function agentWorkspaceStorageKeys(ledgerScope = apiEndpointLedgerScope()) {
  return {
    metadata: `${metadataKeyPrefix}:${ledgerScope}`,
    indexed: `${indexedKeyPrefix}:${ledgerScope}`,
  };
}

export function readStoredAgentMetadata(ledgerScope = apiEndpointLedgerScope()): StoredAgentWorkspace | null {
  if (typeof window === "undefined") return null;
  try {
    const raw = window.localStorage.getItem(agentWorkspaceStorageKeys(ledgerScope).metadata);
    return raw ? restoreStoredAgentWorkspace(JSON.parse(raw)) : null;
  } catch {
    return null;
  }
}

export async function readStoredAgent(ledgerScope = apiEndpointLedgerScope()): Promise<StoredAgentWorkspace | null> {
  const keys = agentWorkspaceStorageKeys(ledgerScope);
  await workspaceWriteChains.get(keys.indexed)?.catch(() => undefined);
  const metadata = readStoredAgentMetadata(ledgerScope);
  const indexed = restoreStoredAgentWorkspace(await readIndexedCache<IndexedAgentWorkspace>(keys.indexed));
  if (!indexed) return metadata;
  if (!metadata) return indexed;

  const deleted = new Set([...indexed.deletedServerSessionIds, ...metadata.deletedServerSessionIds]);
  const indexedIsNewer = (indexed.savedAt ?? 0) >= (metadata.savedAt ?? 0);
  const primary = indexedIsNewer ? indexed : metadata;
  const secondary = indexedIsNewer ? metadata : indexed;
  const indexedTimelineMayBeStale = (metadata.savedAt ?? 0) > (indexed.savedAt ?? 0);
  const sessions: AgentSession[] = [];
  const positionsByID = new Map<string, number>();
  const positionsByServerID = new Map<string, number>();
  for (const session of [...primary.sessions, ...secondary.sessions]) {
    if (session.serverSessionId && deleted.has(session.serverSessionId)) continue;
    const position = positionsByID.get(session.id) ?? (session.serverSessionId ? positionsByServerID.get(session.serverSessionId) : undefined);
    if (position == null) {
      positionsByID.set(session.id, sessions.length);
      if (session.serverSessionId) positionsByServerID.set(session.serverSessionId, sessions.length);
      sessions.push(session);
      continue;
    }
    const authoritative = sessions[position];
    sessions[position] = {
      ...session,
      ...authoritative,
      timelineState: indexedTimelineMayBeStale ? "missing" : (authoritative.timelineState === "available" || session.timelineState === "available" ? "available" : "missing"),
      timeline: authoritative.timeline.length ? authoritative.timeline : session.timeline,
    };
  }
  const preferredActiveSessionId = primary.activeSessionId || secondary.activeSessionId;
  const activeSessionId = sessions.some((session) => session.id === preferredActiveSessionId) ? preferredActiveSessionId : sessions[0]?.id ?? "";
  return { activeSessionId, sessions, deletedServerSessionIds: Array.from(deleted), savedAt: Math.max(indexed.savedAt ?? 0, metadata.savedAt ?? 0) };
}

export function writeStoredAgent(value: StoredAgentWorkspace, ledgerScope = apiEndpointLedgerScope()) {
  if (typeof window === "undefined") return Promise.resolve(false);
  const keys = agentWorkspaceStorageKeys(ledgerScope);
  const savedAt = Date.now();
  const deleted = Array.from(new Set(value.deletedServerSessionIds.filter(Boolean)));
  // Session retention is user-managed through archive/delete. Never evict a
  // complete conversation merely because a count or quota threshold was hit.
  const sessions = value.sessions.filter((session) => !session.serverSessionId || !deleted.includes(session.serverSessionId));
  const snapshot: IndexedAgentWorkspace = {
    version: 1,
    ledgerScope,
    savedAt,
    activeSessionId: sessions.some((session) => session.id === value.activeSessionId) ? value.activeSessionId : sessions[0]?.id ?? "",
    sessions,
    deletedServerSessionIds: deleted,
  };
  let metadataStored = false;
  try {
    window.localStorage.setItem(keys.metadata, JSON.stringify({
      version: snapshot.version,
      savedAt,
      activeSessionId: snapshot.activeSessionId,
      deletedServerSessionIds: deleted,
      sessions: sessions.map((session) => ({
        id: session.id,
        serverSessionId: session.serverSessionId,
        title: session.title || timelineTitle(session.timeline),
        archived: session.archived,
        createdAt: session.createdAt,
        updatedAt: session.updatedAt,
        timelineState: session.timelineState,
        timeline: [],
      })),
    }));
    metadataStored = true;
  } catch {
    // IndexedDB remains the durable source when localStorage is unavailable.
  }

  const previous = workspaceWriteChains.get(keys.indexed) ?? Promise.resolve(true);
  const next = previous.then(
    async () => (await writeIndexedCache(keys.indexed, snapshot)) || metadataStored,
    async () => (await writeIndexedCache(keys.indexed, snapshot)) || metadataStored,
  );
  workspaceWriteChains.set(keys.indexed, next);
  return next;
}

export function restoreStoredAgentWorkspace(value: unknown): StoredAgentWorkspace | null {
  if (!value || typeof value !== "object") return null;
  const candidate = value as Record<string, unknown>;
  if ("version" in candidate && candidate.version !== 1) return null;
  const sessions = restoreSessions(candidate.sessions);
  if (!sessions.length && (Array.isArray(candidate.timeline) || Array.isArray(candidate.messages) || typeof candidate.sessionId === "string")) {
    const now = Date.now();
    const serverSessionId = typeof candidate.sessionId === "string" ? candidate.sessionId : "";
    const timeline = restoreTimeline(candidate.timeline ?? candidate.messages);
    sessions.push({
      id: `legacy-${serverSessionId || now}`,
      serverSessionId,
      title: timelineTitle(timeline),
      archived: false,
      createdAt: now,
      updatedAt: now,
      timelineState: "available",
      timeline,
    });
  }
  if (!sessions.length) return null;
  const deletedServerSessionIds = Array.isArray(candidate.deletedServerSessionIds)
    ? candidate.deletedServerSessionIds.filter((item): item is string => typeof item === "string" && Boolean(item))
    : [];
  const filtered = sessions.filter((session) => !session.serverSessionId || !deletedServerSessionIds.includes(session.serverSessionId));
  if (!filtered.length) return null;
  const activeSessionId = typeof candidate.activeSessionId === "string" && filtered.some((session) => session.id === candidate.activeSessionId)
    ? candidate.activeSessionId
    : filtered[0].id;
  const savedAt = typeof candidate.savedAt === "number" && Number.isFinite(candidate.savedAt) ? candidate.savedAt : 0;
  return { activeSessionId, sessions: filtered, deletedServerSessionIds, savedAt };
}

export function restoreSessions(value: unknown): AgentSession[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((item) => {
    if (!item || typeof item !== "object") return [];
    const session = item as Record<string, unknown>;
    if (typeof session.id !== "string") return [];
    const timeline = restoreTimeline(session.timeline);
    const createdAt = typeof session.createdAt === "number" && Number.isFinite(session.createdAt) ? session.createdAt : Date.now();
    const updatedAt = typeof session.updatedAt === "number" && Number.isFinite(session.updatedAt) ? session.updatedAt : createdAt;
    return [{
      id: session.id,
      serverSessionId: typeof session.serverSessionId === "string" ? session.serverSessionId : "",
      title: typeof session.title === "string" ? session.title.trim() : timelineTitle(timeline),
      archived: session.archived === true,
      createdAt,
      updatedAt,
      timelineState: session.timelineState === "available" || timeline.length > 0 ? "available" : "missing",
      timeline,
    }];
  });
}

export function restoreTimeline(value: unknown): TimelineItem[] {
  if (!Array.isArray(value)) return [];
  return value.filter((item): item is TimelineItem => {
    if (!item || typeof item !== "object") return false;
    const candidate = item as Record<string, unknown>;
    if (typeof candidate.id !== "string") return false;
    if (candidate.kind === "message") return (candidate.role === "user" || candidate.role === "assistant") && typeof candidate.content === "string";
    if (candidate.kind === "tool") {
      const tool = candidate.tool;
      return Boolean(tool && typeof tool === "object" && typeof (tool as Record<string, unknown>).id === "string" && typeof (tool as Record<string, unknown>).name === "string" && typeof (tool as Record<string, unknown>).title === "string" && ["running", "completed", "error"].includes(String((tool as Record<string, unknown>).status)));
    }
    if (candidate.kind === "artifact") {
      const artifact = candidate.artifact;
      return Boolean(artifact && typeof artifact === "object" && typeof (artifact as Record<string, unknown>).id === "string" && typeof (artifact as Record<string, unknown>).type === "string" && typeof (artifact as Record<string, unknown>).title === "string" && "data" in (artifact as Record<string, unknown>));
    }
    return false;
  });
}

export function timelineTitle(timeline: TimelineItem[]) {
  const firstPrompt = timeline.find((item): item is MessageItem => item.kind === "message" && item.role === "user");
  return firstPrompt?.content.trim() || "";
}
