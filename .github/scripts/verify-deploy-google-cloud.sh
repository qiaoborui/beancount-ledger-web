#!/usr/bin/env bash
set -euo pipefail

workflow="${1:-.github/workflows/deploy-google-cloud.yml}"
worker_step="$(awk '
  /^      - name: Deploy private ZIP worker$/ { capture = 1 }
  /^      - name: Deploy Cloud Run service$/ { capture = 0 }
  capture { print }
' "${workflow}")"

if [[ -z "${worker_step}" ]]; then
  echo "ZIP worker deployment step was not found" >&2
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
