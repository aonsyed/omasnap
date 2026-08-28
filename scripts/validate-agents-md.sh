#!/usr/bin/env bash
# AGENTS.md consistency gate: every repo path the guide mentions must exist,
# and the documented build/test targets must still be defined in the
# Makefile. Run by CI (make guards) so the guide cannot drift silently.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
status=0

while IFS= read -r path; do
  # The guide uses `foo.cpp/.hpp` as shorthand for the file pair.
  if [[ "$path" == */.hpp ]]; then
    path="${path%/.hpp}"
  fi
  if [[ ! -e "$path" ]]; then
    printf 'validate-agents-md: mentioned path is missing: %s\n' "$path" >&2
    status=1
  fi
done < <(grep -oE '`(src|tests|cmake|macos|scripts|docs|assets)/[A-Za-z0-9_./-]+`' \
    AGENTS.md | tr -d '`' | sort -u)

for target in configure build check smoke lint format docs; do
  if ! grep -qsE "^${target}:" Makefile; then
    printf 'validate-agents-md: documented make target missing: %s\n' \
      "$target" >&2
    status=1
  fi
done

if (( status != 0 )); then
  printf 'validate-agents-md: update AGENTS.md to match the repository\n' >&2
  exit 1
fi
printf 'validate-agents-md: every documented path and target exists\n'
