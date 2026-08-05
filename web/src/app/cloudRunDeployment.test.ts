import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const deploymentWorkflow = readFileSync(new URL("../../../.github/workflows/deploy-google-cloud.yml", import.meta.url), "utf8");
const ciWorkflow = readFileSync(new URL("../../../.github/workflows/ci.yml", import.meta.url), "utf8");
const imagePublishingWorkflow = readFileSync(new URL("../../../.github/workflows/publish-images.yml", import.meta.url), "utf8");
const artifactTagUpdater = readFileSync(new URL("../../../.github/scripts/update-artifact-latest-tag.sh", import.meta.url), "utf8");
const dockerfile = readFileSync(new URL("../../../docker/Dockerfile", import.meta.url), "utf8");

describe("Cloud Run deployment", () => {
  it("builds the existing same-origin standalone image", () => {
    expect(deploymentWorkflow).toContain("target: standalone");
    expect(dockerfile).toContain("FROM server AS standalone");
    expect(dockerfile).toContain("ENV SERVE_STATIC=true");
    expect(dockerfile).toContain("COPY --from=web-builder /app/web/dist /app/web-dist");
    expect(dockerfile).toContain("mkdir -p /app/agent/.bub");
    expect(dockerfile).toContain("chown ledger:ledger /app/agent/.bub");
  });

  it("runs checks and production image builds in parallel before deployment", () => {
    expect(ciWorkflow).toContain("workflow_call:");
    expect(ciWorkflow).toContain("reusable_call:");
    expect(ciWorkflow).toContain('INPUT_REUSABLE_CALL: ${{ inputs.reusable_call }}');
    expect(ciWorkflow).toContain('if [[ "${INPUT_REUSABLE_CALL}" == "true" ]]');
    expect(ciWorkflow).not.toContain("github.event_name != 'workflow_call'");
    expect(ciWorkflow).not.toContain('github.event_name }}" == "workflow_call"');
    expect(ciWorkflow).toContain("go test ./...");
    expect(ciWorkflow).toContain("pnpm run typecheck");
    expect(ciWorkflow).toContain("pnpm run test");
    expect(deploymentWorkflow).toContain("push:\n    branches: [main]");
    expect(deploymentWorkflow).not.toContain("workflow_run:");
    expect(deploymentWorkflow).toContain("uses: ./.github/workflows/ci.yml");
    expect(deploymentWorkflow).toContain("reusable_call: true");
    expect(deploymentWorkflow).toContain("needs: [plan, checks, build-standalone, build-agent, build-zip-worker]");
    expect(deploymentWorkflow).toContain("needs.checks.result == 'success'");
    expect(deploymentWorkflow).toContain("name: Verify current main commit");
    expect(deploymentWorkflow).toContain("vars.GCP_BUILD_SERVICE_ACCOUNT");
    expect(deploymentWorkflow).toContain("environment: google-cloud-production");
    expect(deploymentWorkflow).not.toContain("gcloud artifacts docker tags add");
    expect(deploymentWorkflow.match(/\.github\/scripts\/update-artifact-latest-tag\.sh/g)).toHaveLength(3);
    expect(artifactTagUpdater).toContain("gcloud artifacts tags list");
    expect(artifactTagUpdater).toContain("grep -Fxq latest");
    expect(artifactTagUpdater).toContain("tag_action=create");
    expect(artifactTagUpdater).toContain("tag_action=update");
    expect(artifactTagUpdater).toContain('gcloud artifacts tags "${tag_action}" latest');
    expect(deploymentWorkflow.indexOf("build-standalone:")).toBeLessThan(deploymentWorkflow.indexOf("deploy:"));
    expect(deploymentWorkflow.indexOf("checks:")).toBeLessThan(deploymentWorkflow.indexOf("deploy:"));
  });

  it("publishes multi-architecture GHCR images outside the deployment critical path", () => {
    expect(ciWorkflow).not.toContain("name: Server image");
    expect(imagePublishingWorkflow).toContain("workflow_run:");
    expect(imagePublishingWorkflow).toContain("workflows: [Deploy Google Cloud]");
    expect(imagePublishingWorkflow).toContain("platforms: linux/amd64,linux/arm64");
    expect(imagePublishingWorkflow).toContain("type=raw,value=latest");
    expect(imagePublishingWorkflow).toContain("type=raw,value=sha-${{ needs.plan.outputs.short_sha }}");
    expect(imagePublishingWorkflow).toContain("cancel-in-progress: false");
    expect(imagePublishingWorkflow).toContain("--status success --limit 100");
    expect(imagePublishingWorkflow).toContain('gh run download "$previous_run_id"');
    expect(imagePublishingWorkflow).toContain('git diff --name-only "$base_sha" "$source_sha"');
    expect(imagePublishingWorkflow).toContain("name: container-publish-state");
  });

  it("deploys an immutable image with bounded request-based scaling", () => {
    expect(deploymentWorkflow).toContain("needs.build-standalone.outputs.digest");
    expect(deploymentWorkflow).toContain("needs.build-agent.outputs.digest");
    expect(deploymentWorkflow).toContain("needs.build-zip-worker.outputs.digest");
    expect(deploymentWorkflow).toContain("--cpu-throttling");
    expect(deploymentWorkflow).toContain("--concurrency=8");
    expect(deploymentWorkflow).toContain("--min-instances=0");
    expect(deploymentWorkflow).toContain("--max-instances=2");
    expect(deploymentWorkflow).toContain("--timeout=900s");
    expect(deploymentWorkflow).toContain("--no-traffic");
    expect(deploymentWorkflow).toContain("candidate_url");
    expect(deploymentWorkflow).toContain("--to-revisions=\"${candidate_revision}=100\"");
    expect(deploymentWorkflow).toContain("steps.deploy-candidate.outputs.revision_tag != ''");
    expect(deploymentWorkflow).toContain("--to-revisions=\"${PREVIOUS_TRAFFIC}\"");
    expect(deploymentWorkflow).toContain("cannot prove ownership of the unsuccessful first Cloud Run deployment");
    expect(deploymentWorkflow).toContain("failed to remove the unsuccessful first Cloud Run deployment");
    expect(deploymentWorkflow).toContain("name: Remove candidate traffic tag");
    expect(deploymentWorkflow).toContain("--remove-tags=\"${REVISION_TAG}\"");
    expect(deploymentWorkflow).toContain("traffic restoration did not match");
    expect(deploymentWorkflow).toContain("CLOUD_RUN_SECRET_MAPPINGS must define");
  });

  it("keeps Telegram polling alive and its token out of the public service", () => {
    expect(deploymentWorkflow).toContain("agent_runtime_args=(--cpu-throttling --min-instances=0)");
    expect(deploymentWorkflow).toContain("agent_runtime_args=(--no-cpu-throttling --min-instances=1)");
    expect(deploymentWorkflow).toContain("telegram_secret_mapped=false");
    expect(deploymentWorkflow).toContain("telegram_allow_list_configured=false");
    expect(deploymentWorkflow).toContain(
      "CLOUD_RUN_SECRET_MAPPINGS must define BUB_TELEGRAM_TOKEN when a Telegram allow-list is configured",
    );
    expect(deploymentWorkflow).toContain("BUB_TELEGRAM_ALLOW_USERS or BUB_TELEGRAM_ALLOW_CHATS is required when Telegram is enabled");
    const telegramExclusions = deploymentWorkflow.match(/\$1 != "BUB_TELEGRAM_TOKEN"/g) ?? [];
    expect(telegramExclusions).toHaveLength(2);
  });

  it("pins every third-party action to a full commit SHA", () => {
    const actionRefs = [...deploymentWorkflow.matchAll(/uses:\s+[^\s@]+@([^\s#]+)/g)].map((match) => match[1]);
    expect(actionRefs.length).toBeGreaterThan(0);
    expect(actionRefs.every((ref) => /^[0-9a-f]{40}$/.test(ref))).toBe(true);
  });
});
