#!/usr/bin/env bash
set -euo pipefail

readonly GOMOBILE_VERSION="v0.0.0-20260908204917-8b95e45f8d3e"
readonly XTEXT_VERSION="v0.40.0"
readonly IOS_MIN_VERSION="17.0"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
server_root="${repo_root}/server"
build_root="${server_root}/.build/ledgercore"
tool_bin="${server_root}/.build/gomobile/${GOMOBILE_VERSION}/bin"
output="${build_root}/LedgerCore.xcframework"

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode-beta.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
fi

mkdir -p "${tool_bin}" "${build_root}"
if [[ ! -x "${tool_bin}/gomobile" || ! -x "${tool_bin}/gobind" ]]; then
  GOBIN="${tool_bin}" go install "golang.org/x/mobile/cmd/gomobile@${GOMOBILE_VERSION}"
  GOBIN="${tool_bin}" go install "golang.org/x/mobile/cmd/gobind@${GOMOBILE_VERSION}"
fi

export PATH="${tool_bin}:${PATH}"
staging_dir="$(mktemp -d "${build_root}/staging.XXXXXX")"
trap 'rm -rf "${staging_dir}"' EXIT
source_root="${staging_dir}/source"

mkdir -p "${source_root}/internal"
cp -R "${server_root}/mobilecore" "${source_root}/mobilecore"
cp -R "${server_root}/mobilegit" "${source_root}/mobilegit"
cp -R "${server_root}/mobilereadindex" "${source_root}/mobilereadindex"
cp -R "${server_root}/internal/." "${source_root}/internal/"
cp "${server_root}/go.mod" "${server_root}/go.sum" "${source_root}/"

cd "${source_root}"
go mod edit -go=1.26.0
go mod edit \
  -require="golang.org/x/mobile@${GOMOBILE_VERSION}" \
  -require="golang.org/x/text@${XTEXT_VERSION}" \
  -tool=golang.org/x/mobile/cmd/gobind
go mod download golang.org/x/mobile golang.org/x/text
go get -tool "golang.org/x/mobile/cmd/gobind@${GOMOBILE_VERSION}"

"${tool_bin}/gomobile" bind \
  -target=ios,iossimulator \
  -iosversion="${IOS_MIN_VERSION}" \
  -ldflags="-s -w" \
  -trimpath \
  -o "${staging_dir}/LedgerCore.xcframework" \
  ./mobilecore ./mobilegit ./mobilereadindex

rm -rf "${output}"
mv "${staging_dir}/LedgerCore.xcframework" "${output}"
printf '%s\n' "${output}"
