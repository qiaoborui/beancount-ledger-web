import { afterEach, describe, expect, it, vi } from "vitest";
import { createAgentAccessToken, listAgentAccessTokens, revokeAgentAccessToken } from "./agentAccessTokens";

describe("Agent access token API", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("keeps plaintext tokens confined to the create response", async () => {
    const fetchMock = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      if (init?.method === "POST") return new Response(JSON.stringify({ token: "blw_agent_secret", credential: { id: "token-1", name: "MacBook", createdAt: "2026-08-05T00:00:00Z", expiresAt: "2026-11-03T00:00:00Z" } }), { status: 201 });
      return new Response(JSON.stringify({ tokens: [{ id: "token-1", name: "MacBook", createdAt: "2026-08-05T00:00:00Z", expiresAt: "2026-11-03T00:00:00Z" }] }), { status: 200 });
    });
    vi.stubGlobal("fetch", fetchMock);

    const created = await createAgentAccessToken("MacBook");
    const listed = await listAgentAccessTokens();

    expect(created.token).toBe("blw_agent_secret");
    expect(JSON.stringify(listed)).not.toContain("blw_agent_secret");
  });

  it("uses DELETE without sending the plaintext token", async () => {
    const fetchMock = vi.fn(async () => new Response(null, { status: 204 }));
    vi.stubGlobal("fetch", fetchMock);

    await revokeAgentAccessToken("token-1");

    expect(fetchMock).toHaveBeenCalledWith(expect.stringContaining("/api/agent/access-tokens/token-1"), expect.objectContaining({ method: "DELETE" }));
  });
});
