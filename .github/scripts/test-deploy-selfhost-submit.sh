#!/usr/bin/env bash
set -euo pipefail

submit_script="${1:-scripts/selfhost/beancount-ledger-deploy-submit}"
digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
valid="$(jq -cn \
  --arg digest "$digest" \
  '{schema: 1, host_contract: 2, repository: "qiaoborui/beancount-ledger-web",
    sha: "0123456789abcdef0123456789abcdef01234567", run_id: "123456789",
    run_attempt: "1", images: {
      server: ("ghcr.io/qiaoborui/beancount-ledger-web-server@sha256:" + $digest),
      indexer: ("ghcr.io/qiaoborui/beancount-ledger-web-indexer@sha256:" + $digest),
      agent: ("ghcr.io/qiaoborui/beancount-ledger-web-agent@sha256:" + $digest),
      frontend: ("ghcr.io/qiaoborui/beancount-ledger-web-frontend@sha256:" + $digest),
      zip_worker: ("ghcr.io/qiaoborui/beancount-ledger-web-zip-worker@sha256:" + $digest)}}')"

if ! "$submit_script" --validate-only <<< "$valid"; then
  echo "valid deployment manifest was rejected" >&2
  exit 1
fi

reject() {
  local name="$1"
  local payload="$2"
  if "$submit_script" --validate-only >/dev/null 2>&1 <<< "$payload"; then
    echo "invalid deployment manifest was accepted: ${name}" >&2
    return 1
  fi
}

reject extra-key "$(jq -c '.unexpected = true' <<< "$valid")"
reject stale-contract "$(jq -c '.host_contract = 1' <<< "$valid")"
reject wrong-repository "$(jq -c '.repository = "other/repository"' <<< "$valid")"
reject numeric-run-id "$(jq -c '.run_id = 123456789' <<< "$valid")"
reject oversized-run-id "$(jq -c '.run_id = "123456789012345678901"' <<< "$valid")"
reject mutable-tag "$(jq -c '.images.server = "ghcr.io/qiaoborui/beancount-ledger-web-server:latest"' <<< "$valid")"
reject swapped-component "$(jq -c '.images.server = .images.agent' <<< "$valid")"
reject missing-worker "$(jq -c 'del(.images.zip_worker)' <<< "$valid")"
reject oversized-payload "$(printf '%*s%s' 32769 '' "$valid")"
