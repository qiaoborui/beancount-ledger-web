import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const deploymentWorkflow = readFileSync(new URL("../../../.github/workflows/deploy-google-cloud.yml", import.meta.url), "utf8");
const dockerfile = readFileSync(new URL("../../../docker/Dockerfile", import.meta.url), "utf8");

describe("Cloud Run deployment", () => {
  it("builds the existing same-origin standalone image", () => {
    expect(deploymentWorkflow).toContain("target: standalone");
    expect(dockerfile).toContain("FROM server AS standalone");
    expect(dockerfile).toContain("ENV SERVE_STATIC=true");
    expect(dockerfile).toContain("COPY --from=web-builder /app/web/dist /app/web-dist");
  });

  it("runs required checks before Google Cloud authentication", () => {
    expect(deploymentWorkflow).toContain("environment: google-cloud-production");
    expect(deploymentWorkflow.indexOf("go test ./...")).toBeLessThan(deploymentWorkflow.indexOf("Authenticate to Google Cloud"));
    expect(deploymentWorkflow.indexOf("pnpm run typecheck")).toBeLessThan(deploymentWorkflow.indexOf("Authenticate to Google Cloud"));
    expect(deploymentWorkflow.indexOf("pnpm run test")).toBeLessThan(deploymentWorkflow.indexOf("Authenticate to Google Cloud"));
  });

  it("deploys an immutable image with bounded request-based scaling", () => {
    expect(deploymentWorkflow).toContain("steps.build-image.outputs.digest");
    expect(deploymentWorkflow).toContain("--cpu-throttling");
    expect(deploymentWorkflow).toContain("--concurrency=8");
    expect(deploymentWorkflow).toContain("--min-instances=0");
    expect(deploymentWorkflow).toContain("--max-instances=2");
    expect(deploymentWorkflow).toContain("--timeout=900s");
    expect(deploymentWorkflow).toContain("--no-traffic");
    expect(deploymentWorkflow).toContain("candidate_url");
    expect(deploymentWorkflow).toContain("--to-revisions=\"${candidate_revision}=100\"");
    expect(deploymentWorkflow).toContain("if: ${{ always() && steps.deploy-candidate.outputs.revision_tag != '' }}");
    expect(deploymentWorkflow).toContain("--to-revisions=\"${PREVIOUS_TRAFFIC}\"");
    expect(deploymentWorkflow).toContain("cannot prove ownership of the unsuccessful first Cloud Run deployment");
    expect(deploymentWorkflow).toContain("failed to remove the unsuccessful first Cloud Run deployment");
    expect(deploymentWorkflow).toContain("name: Remove candidate traffic tag");
    expect(deploymentWorkflow).toContain("--remove-tags=\"${REVISION_TAG}\"");
    expect(deploymentWorkflow).toContain("traffic restoration did not match");
    expect(deploymentWorkflow).toContain("CLOUD_RUN_SECRET_MAPPINGS must define");
  });

  it("pins every third-party action to a full commit SHA", () => {
    const actionRefs = [...deploymentWorkflow.matchAll(/uses:\s+[^\s@]+@([^\s#]+)/g)].map((match) => match[1]);
    expect(actionRefs.length).toBeGreaterThan(0);
    expect(actionRefs.every((ref) => /^[0-9a-f]{40}$/.test(ref))).toBe(true);
  });
});
