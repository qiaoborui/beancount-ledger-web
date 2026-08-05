#!/usr/bin/env bash
set -euo pipefail

package="${1:?package name is required}"
version="${2:?image digest is required}"

: "${GCP_PROJECT_ID:?GCP_PROJECT_ID is required}"
: "${GCP_REGION:?GCP_REGION is required}"
: "${ARTIFACT_REPOSITORY:?ARTIFACT_REPOSITORY is required}"

if [[ ! "$package" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
  echo "invalid Artifact Registry package name: ${package}" >&2
  exit 1
fi
if [[ ! "$version" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "invalid Artifact Registry version digest: ${version}" >&2
  exit 1
fi

tag_args=(
  --project="${GCP_PROJECT_ID}"
  --location="${GCP_REGION}"
  --repository="${ARTIFACT_REPOSITORY}"
  --package="${package}"
)
existing_tags="$(gcloud artifacts tags list "${tag_args[@]}" --filter='name:latest' --format='value(name)')"

tag_action=create
if grep -Fxq latest <<< "${existing_tags}"; then
  tag_action=update
fi

gcloud artifacts tags "${tag_action}" latest \
  "${tag_args[@]}" \
  --version="${version}" \
  --quiet
