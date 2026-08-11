import { afterEach, describe, expect, it, vi } from "vitest";

const indexedCacheState = vi.hoisted(() => ({ values: new Map<string, unknown>() }));

vi.mock("@/lib/indexedLedgerCache", () => ({
  readIndexedCache: vi.fn(async (key: string) => indexedCacheState.values.get(key) ?? null),
  writeIndexedCache: vi.fn(async (key: string, value: unknown) => {
    indexedCacheState.values.set(key, value);
    return true;
  }),
}));

import { agentWorkspaceStorageKeys, readStoredAgent, restoreSessions, writeStoredAgent, type StoredAgentWorkspace } from "./ledgerAgentStorage";

function memoryStorage(initial: Record<string, string> = {}) {
  const values = new Map(Object.entries(initial));
  const storage = {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => values.set(key, value),
    removeItem: (key: string) => values.delete(key),
    clear: () => values.clear(),
    key: (index: number) => Array.from(values.keys())[index] ?? null,
    get length() {
      return values.size;
    },
  } satisfies Storage;
  vi.stubGlobal("window", { localStorage: storage } as unknown as Window & typeof globalThis);
  return values;
}

const scope = "cluster:test-ledger";

function workspace(timelineState: "available" | "missing" = "available"): StoredAgentWorkspace {
  return {
    activeSessionId: "local-1",
    deletedServerSessionIds: [],
    sessions: [{
      id: "local-1",
      serverSessionId: "server-1",
      title: "分析支出",
      archived: false,
      createdAt: 1,
      updatedAt: 2,
      timelineState,
      timeline: [
        { kind: "message", id: "message-1", role: "user", content: "分析支出" },
        { kind: "tool", id: "tool-1", tool: { id: "tool-1", name: "run_bql", title: "运行 BQL", status: "completed", output: { rowCount: 2 } } },
        { kind: "artifact", id: "artifact-1", artifact: { id: "artifact-1", type: "table", title: "结果", data: { rows: [] } } },
      ],
    }],
  };
}

describe("ledger Agent local storage", () => {
  afterEach(() => {
    indexedCacheState.values.clear();
    vi.clearAllMocks();
    vi.unstubAllGlobals();
  });

  it("restores complete IndexedDB timelines while localStorage supplies metadata immediately", async () => {
    const keys = agentWorkspaceStorageKeys(scope);
    const full = workspace();
    memoryStorage({
      [keys.metadata]: JSON.stringify({
        activeSessionId: "local-1",
        sessions: [{ ...full.sessions[0], timelineState: "missing", timeline: [] }],
      }),
    });
    indexedCacheState.values.set(keys.indexed, { version: 1, ledgerScope: scope, savedAt: 3, ...full });

    const restored = await readStoredAgent(scope);

    expect(restored?.sessions[0]).toMatchObject({ timelineState: "available", timeline: [{ kind: "message" }, { kind: "tool" }, { kind: "artifact" }] });
  });

  it("persists every timeline item in IndexedDB and only small metadata in localStorage", async () => {
    const values = memoryStorage();
    const keys = agentWorkspaceStorageKeys(scope);
    const full = workspace();

    await writeStoredAgent(full, scope);

    expect((indexedCacheState.values.get(keys.indexed) as StoredAgentWorkspace).sessions[0].timeline).toHaveLength(3);
    const metadata = JSON.parse(values.get(keys.metadata) ?? "{}");
    expect(metadata.sessions[0]).toMatchObject({ title: "分析支出", timelineState: "available", timeline: [] });
  });

  it("persists titles, archive state, and the active session locally", async () => {
    const values = memoryStorage();
    const keys = agentWorkspaceStorageKeys(scope);
    const full = workspace();
    full.sessions[0] = { ...full.sessions[0], title: "已归档分析", archived: true };

    await writeStoredAgent(full, scope);

    const metadata = JSON.parse(values.get(keys.metadata) ?? "{}");
    expect(metadata).toMatchObject({ activeSessionId: "local-1", sessions: [{ title: "已归档分析", archived: true }] });
    expect(await readStoredAgent(scope)).toMatchObject({ activeSessionId: "local-1", sessions: [{ title: "已归档分析", archived: true }] });
  });

  it("migrates metadata-only sessions without mistaking them for intentionally empty sessions", async () => {
    const keys = agentWorkspaceStorageKeys(scope);
    memoryStorage({
      [keys.metadata]: JSON.stringify({
        activeSessionId: "legacy",
        sessions: [{ id: "legacy", serverSessionId: "server-legacy", title: "旧会话", createdAt: 1, updatedAt: 2, timeline: [] }],
      }),
    });

    const restored = await readStoredAgent(scope);
    const fresh = restoreSessions([{ id: "fresh", serverSessionId: "server-fresh", title: "", createdAt: 3, updatedAt: 3, timelineState: "available", timeline: [] }]);

    expect(restored?.sessions[0].timelineState).toBe("missing");
    expect(fresh[0].timelineState).toBe("available");
  });

  it("keeps deletion tombstones authoritative over stale IndexedDB sessions", async () => {
    const keys = agentWorkspaceStorageKeys(scope);
    const full = workspace();
    memoryStorage({
      [keys.metadata]: JSON.stringify({
        activeSessionId: "replacement",
        deletedServerSessionIds: ["server-1"],
        sessions: [{ id: "replacement", serverSessionId: "server-2", title: "新会话", createdAt: 4, updatedAt: 4, timelineState: "available", timeline: [] }],
      }),
    });
    indexedCacheState.values.set(keys.indexed, { version: 1, ledgerScope: scope, savedAt: 3, ...full });

    const restored = await readStoredAgent(scope);

    expect(restored?.sessions.map((session) => session.serverSessionId)).toEqual(["server-2"]);
    expect(restored?.deletedServerSessionIds).toEqual(["server-1"]);
  });

  it("keeps sessions from a newer IndexedDB snapshot when localStorage metadata is stale", async () => {
    const keys = agentWorkspaceStorageKeys(scope);
    const full = workspace();
    const secondSession = {
      ...full.sessions[0],
      id: "local-2",
      serverSessionId: "server-2",
      title: "新增会话",
      timeline: [{ kind: "message" as const, id: "message-2", role: "user" as const, content: "新增会话" }],
    };
    memoryStorage({
      [keys.metadata]: JSON.stringify({
        savedAt: 1,
        activeSessionId: "local-1",
        sessions: [{ ...full.sessions[0], timelineState: "missing", timeline: [] }],
      }),
    });
    indexedCacheState.values.set(keys.indexed, { version: 1, ledgerScope: scope, savedAt: 2, ...full, activeSessionId: "local-2", sessions: [...full.sessions, secondSession] });

    const restored = await readStoredAgent(scope);

    expect(restored?.activeSessionId).toBe("local-2");
    expect(restored?.sessions.map((session) => session.id)).toEqual(["local-1", "local-2"]);
    expect(restored?.sessions[1].timeline).toEqual(secondSession.timeline);
  });

  it("requests recovery when newer metadata shows that the durable timeline write was missed", async () => {
    const keys = agentWorkspaceStorageKeys(scope);
    const full = workspace();
    memoryStorage({
      [keys.metadata]: JSON.stringify({
        savedAt: 2,
        activeSessionId: "local-1",
        sessions: [{ ...full.sessions[0], updatedAt: 3, timelineState: "available", timeline: [] }],
      }),
    });
    indexedCacheState.values.set(keys.indexed, { version: 1, ledgerScope: scope, savedAt: 1, ...full });

    const restored = await readStoredAgent(scope);

    expect(restored?.sessions[0]).toMatchObject({ timelineState: "missing", timeline: [{ kind: "message" }, { kind: "tool" }, { kind: "artifact" }] });
  });

  it("does not discard old sessions or their timelines by count", () => {
    const sessions = restoreSessions(Array.from({ length: 40 }, (_, index) => ({
      id: `local-${index}`,
      serverSessionId: `server-${index}`,
      createdAt: index,
      updatedAt: index,
      timelineState: "available",
      timeline: [{ kind: "message", id: `message-${index}`, role: "user", content: `会话 ${index}` }],
    })));

    expect(sessions).toHaveLength(40);
    expect(sessions[39].timeline).toHaveLength(1);
  });
});
