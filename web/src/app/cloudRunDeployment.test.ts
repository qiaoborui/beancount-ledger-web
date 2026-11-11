import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const ciWorkflow = readFileSync(new URL("../../../.github/workflows/ci.yml", import.meta.url), "utf8");
const dockerfile = readFileSync(new URL("../../../docker/Dockerfile", import.meta.url), "utf8");

describe("Container build", () => {
  it("builds the existing same-origin standalone image", () => {
    expect(dockerfile).toContain("FROM server AS standalone");
    expect(dockerfile).toContain("ENV SERVE_STATIC=true");
    expect(dockerfile).toContain("COPY --from=web-builder /app/web/dist /app/web-dist");
    expect(dockerfile).toContain("mkdir -p /app/agent/.bub");
    expect(dockerfile).toContain("chown ledger:ledger /app/agent/.bub");
  });

  it("keeps CI reusable without building production images", () => {
    expect(ciWorkflow).toContain("workflow_call:");
    expect(ciWorkflow).toContain("reusable_call:");
    expect(ciWorkflow).toContain('INPUT_REUSABLE_CALL: ${{ inputs.reusable_call }}');
    expect(ciWorkflow).toContain('if [[ "${INPUT_REUSABLE_CALL}" == "true" ]]');
    expect(ciWorkflow).not.toContain("github.event_name != 'workflow_call'");
    expect(ciWorkflow).not.toContain('github.event_name }}" == "workflow_call"');
    expect(ciWorkflow).toContain("go test ./...");
    expect(ciWorkflow).toContain("pnpm run typecheck");
    expect(ciWorkflow).toContain("pnpm run test");
    expect(ciWorkflow).not.toContain("name: Server image");
  });
});
