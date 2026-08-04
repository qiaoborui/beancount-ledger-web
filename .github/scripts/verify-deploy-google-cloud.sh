#!/usr/bin/env bash
set -euo pipefail

workflow="${1:-.github/workflows/deploy-google-cloud.yml}"
if ! grep -Fq 'workflow_run:' "${workflow}" || ! grep -Fq 'workflows: [CI]' "${workflow}"; then
  echo "Cloud Run deployment must wait for a successful CI workflow" >&2
  exit 1
fi

if ! grep -Fq 'gh run download "${CI_RUN_ID}" --repo "${GITHUB_REPOSITORY}" --name cloud-run-plan' "${workflow}"; then
  echo "Cloud Run deployment must use CI's published change plan" >&2
  exit 1
fi

zip_build_step="$(awk '
  /^      - name: Build and push ZIP worker image$/ { capture = 1 }
  /^      - name: Deploy private ZIP worker$/ { capture = 0 }
  capture { print }
' "${workflow}")"

if [[ "${zip_build_step}" != *"if: \${{ needs.plan.outputs.zip_worker == 'true' }}"* ]]; then
  echo "ZIP worker image build must be conditional" >&2
  exit 1
fi

worker_step="$(awk '
  /^      - name: Deploy private ZIP worker$/ { capture = 1 }
  /^      - name: Deploy Cloud Run service$/ { capture = 0 }
  capture { print }
' "${workflow}")"

if [[ -z "${worker_step}" ]]; then
  echo "ZIP worker deployment step was not found" >&2
  exit 1
fi

if [[ "${worker_step}" != *"if: \${{ needs.plan.outputs.zip_worker == 'true' }}"* ]]; then
  echo "ZIP worker deployment must be conditional" >&2
  exit 1
fi

for required in \
  'gcloud run deploy' \
  'gcloud run services set-iam-policy' \
  'gcloud run services get-iam-policy' \
  'gcloud run services describe'; do
  if [[ "${worker_step}" != *"${required}"* ]]; then
    echo "ZIP worker deployment step is missing: ${required}" >&2
    exit 1
  fi
done

if [[ "${worker_step}" == *'gcloud auth print-identity-token'* ]]; then
  echo "ZIP worker deployment must not mint an identity token from WIF credentials" >&2
  exit 1
fi

deploy_step="$(awk '
  /^      - name: Deploy Cloud Run service$/ { capture = 1 }
  /^      - name: Verify candidate and promote traffic$/ { capture = 0 }
  capture { print }
' "${workflow}")"

for required in \
  'legacy_migration_required=false' \
  'legacy_environment_present=' \
  '.configSource // empty' \
  '--set-secrets="${candidate_secret_mappings}"'; do
  if [[ "${deploy_step}" != *"${required}"* ]]; then
    echo "Cloud Run candidate deployment is missing runtime migration guard: ${required}" >&2
    exit 1
  fi
done

verify_step="$(awk '
  /^      - name: Verify candidate and promote traffic$/ { capture = 1 }
  /^      - name: Restore failed promotion$/ { capture = 0 }
  capture { print }
' "${workflow}")"

for required in \
  'steps.deploy-candidate.outputs.legacy_migration_required' \
  '--remove-env-vars=LEDGER_GITHUB_OWNER,LEDGER_GITHUB_REPO,LEDGER_GIT_BRANCH' \
  '--set-secrets="${platform_secret_mappings}"' \
  'Cloud Run service is not using database runtime configuration'; do
  if [[ "${verify_step}" != *"${required}"* ]]; then
    echo "Cloud Run promotion is missing database runtime verification: ${required}" >&2
    exit 1
  fi
done

if [[ "${verify_step}" == *'--remove-secrets='* ]]; then
  echo "Cloud Run secret cleanup must use one set-secrets replacement operation" >&2
  exit 1
fi
