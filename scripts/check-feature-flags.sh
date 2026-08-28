#!/usr/bin/env bash
# Dead-feature-flag gate: every flag registered in src/feature-flags.cpp
# must be (a) used by at least one FeatureFlag::<Member> call site outside
# its own module and (b) documented in README.md. Flags that fail either
# check are dead and must be wired or removed.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
status=0

# Enum members (one per registered flag) must have an external call site.
for member in $(sed -n '/enum class FeatureFlag {/,/};/p' src/feature-flags.hpp \
    | grep -oE '^  [A-Z][A-Za-z0-9]+,' | tr -d ' ,'); do
  uses=$(grep -Rl "FeatureFlag::${member}" src tests \
    --include='*.cpp' --include='*.mm' --include='*.hpp' \
    | grep -v 'src/feature-flags' | wc -l | tr -d ' ')
  if [[ "$uses" -eq 0 ]]; then
    printf 'check-feature-flags: FeatureFlag::%s has no call site\n' \
      "$member" >&2
    status=1
  fi
done

# Every registered name must be documented.
for flag in $(grep -oE 'QStringLiteral\("[a-z_0-9]+"\)' src/feature-flags.cpp \
    | grep -oE '"[a-z_0-9]+"' | grep -vE '"(true|false)"' | tr -d '"'); do
  if ! grep -qs "$flag" README.md; then
    printf 'check-feature-flags: %s is not documented in README.md\n' "$flag" >&2
    status=1
  fi
done

if (( status != 0 )); then
  printf 'check-feature-flags: wire the flag to a behavior or remove it\n' >&2
  exit 1
fi
printf 'check-feature-flags: all registered flags are wired and documented\n'
