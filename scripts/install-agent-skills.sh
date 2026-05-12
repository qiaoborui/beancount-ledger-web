#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/.agents/skills"
DEST="${AGENT_SKILLS_DIR:-$HOME/.agents/skills}"

if [[ ! -d "$SRC" ]]; then
  echo "Source skills directory not found: $SRC" >&2
  exit 1
fi

mkdir -p "$DEST"

for skill_dir in "$SRC"/*; do
  [[ -d "$skill_dir" ]] || continue
  skill="$(basename "$skill_dir")"
  target="$DEST/$skill"

  rm -rf "$target"
  mkdir -p "$target"
  cp -R "$skill_dir"/. "$target"/
  echo "Installed skill: $skill -> $target"
done

echo "Agent skills installed to: $DEST"
