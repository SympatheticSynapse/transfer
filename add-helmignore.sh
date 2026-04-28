#!/usr/bin/env bash
# Usage: ./add_helmignore.sh <search_root> <source_helmignore>
#
#   search_root      - directory to search recursively (default: current dir)
#   source_helmignore - path to the .helmignore file to copy in (required)

set -euo pipefail

SEARCH_ROOT="${1:-.}"
SOURCE_HELMIGNORE="${2:-}"

# ── Validate arguments ────────────────────────────────────────────────────────
if [[ -z "$SOURCE_HELMIGNORE" ]]; then
  echo "Error: no source .helmignore specified." >&2
  echo "Usage: $0 <search_root> <source_helmignore>" >&2
  exit 1
fi

if [[ ! -f "$SOURCE_HELMIGNORE" ]]; then
  echo "Error: source file not found: $SOURCE_HELMIGNORE" >&2
  exit 1
fi

# ── Main loop ─────────────────────────────────────────────────────────────────
found=0
copied=0

while IFS= read -r chart_yaml; do
  dir="$(dirname "$chart_yaml")"
  ((found++))

  if [[ ! -f "$dir/.helmignore" ]]; then
    cp "$SOURCE_HELMIGNORE" "$dir/.helmignore"
    echo "Copied .helmignore → $dir"
    ((copied++))
  else
    echo "Skipped (already exists) → $dir"
  fi
done < <(find "$SEARCH_ROOT" -type f -name "Chart.yaml")

echo ""
echo "Done. Found $found chart(s), copied .helmignore into $copied."
