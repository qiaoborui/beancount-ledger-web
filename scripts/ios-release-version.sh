#!/usr/bin/env bash
# Print "<version> <build>" for the release tag on the commit being packaged.
#
# The release tag is the only place a version is declared: project.yml is not
# edited per release, and nothing is written back after packaging. The build
# number is derived from the version as MAJOR*10000 + MINOR*100 + PATCH, so a
# newer release always carries a higher build (SideStore and AltStore only offer
# a higher one as an update) and re-running the same tag yields the same number.
#
# Usage: bash scripts/ios-release-version.sh [REPOSITORY_ROOT]
set -euo pipefail

repo_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Only exact vX.Y.Z tags without leading zeros count, so the tag reads the same
# as the version inside the app. Tags are compared as version numbers, never by
# commit date, so re-tagging an older commit cannot move the release backwards.
release_tags() {
  grep -E '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n
}

version="$(git -C "$repo_root" tag --points-at HEAD | release_tags | tail -n 1 || true)"
if [[ -z "$version" ]]; then
  echo "HEAD has no release tag. Tag the commit to ship with 'git tag -a v<MAJOR>.<MINOR>.<PATCH>' and package from that tag." >&2
  exit 1
fi
newest="$(git -C "$repo_root" tag --list | release_tags | tail -n 1)"
if [[ "$version" != "$newest" ]]; then
  echo "v$version is not the newest release tag (v$newest); only the newest release can be packaged." >&2
  exit 1
fi

IFS=. read -r major minor patch <<<"$version"
if (( minor > 99 || patch > 99 )); then
  echo "v$version: MINOR and PATCH must stay below 100 for the derived build number to keep increasing." >&2
  exit 1
fi
echo "$version $(( major * 10000 + minor * 100 + patch ))"
