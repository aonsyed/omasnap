#!/usr/bin/env bash
# Technical-debt gate: TODO/FIXME markers are allowed only when they
# reference an issue (TODO(#123), FIXME(aonsyed/omasnap#45), TODO(PR-7)).
# Bare markers rot, so they fail this check.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
status=0
count=0

while IFS=: read -r file line text; do
  count=$((count + 1))
  reference="$(printf '%s' "$text" | grep -oE '(#[0-9]+|[A-Za-z]+-[0-9]+)' || true)"
  if [[ -z "$reference" ]]; then
    printf 'scan-todos: %s:%s has no issue reference: %s\n' \
      "$file" "$line" "$text" >&2
    status=1
  fi
done < <(grep -RInE '(TODO|FIXME)' src tests scripts docs \
  --exclude=scan-todos.sh 2>/dev/null || true)

if (( status != 0 )); then
  printf 'scan-todos: add an issue reference or resolve the marker\n' >&2
  exit 1
fi
printf 'scan-todos: %d marker(s), all issue-referenced\n' "$count"
