#!/usr/bin/env bash
# Development profiling on Linux: records the smoke suite (or a live run)
# with perf and renders an interactive flame graph.
#
#   scripts/flamegraph.sh                       # profile the smoke suite
#   scripts/flamegraph.sh -- ./build/omasnap    # profile a live run
#
# Output: build/flamegraph.svg. macOS: use Instruments > Time Profiler on
# build/omasnap.app (see docs/runbooks.md).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
mkdir -p build

if ! command -v perf >/dev/null 2>&1; then
  printf 'flamegraph: perf is required (linux-tools / perf package)\n' >&2
  exit 1
fi
flame_dir="build/FlameGraph"
if [[ ! -d "$flame_dir" ]]; then
  git clone --depth 1 https://github.com/brendangregg/FlameGraph "$flame_dir"
fi

perf record -F 99 -g -o build/perf.data -- "${@:-./build/omasnap-smoke build/omasnap-smoke-output}"
perf script -i build/perf.data | "$flame_dir/stackcollapse-perf.pl" \
  | "$flame_dir/flamegraph.pl" > build/flamegraph.svg
printf 'flamegraph: wrote build/flamegraph.svg\n'
