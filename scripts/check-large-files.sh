#!/usr/bin/env bash
# Fails when any tracked file exceeds the 5 MB budget. Demo media in assets/
# stays under it on purpose; anything larger belongs on a release or CDN.
set -euo pipefail

readonly budget_bytes=$((5 * 1024 * 1024))
cd "$(git rev-parse --show-toplevel)"

status=0
while IFS= read -r -d '' file; do
  size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file")
  if (( size > budget_bytes )); then
    printf 'check-large-files: %s is %s bytes (budget %s)\n' \
      "$file" "$size" "$budget_bytes" >&2
    status=1
  fi
done < <(git ls-files -z)

if (( status != 0 )); then
  printf 'check-large-files: move large binaries to a release artifact or LFS\n' >&2
  exit 1
fi
printf 'check-large-files: every tracked file is within the 5 MB budget\n'
