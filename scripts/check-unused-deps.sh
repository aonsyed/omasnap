#!/usr/bin/env bash
# Unused-dependency gate: every library linked into omasnap-core must show
# at least one header or symbol usage in the shared sources. Keeps the CMake
# link list honest without a language-specific dependency analyzer.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
status=0

check() {
  local library="$1" pattern="$2"
  if ! grep -RqsE "$pattern" src tests; then
    printf 'check-unused-deps: %s is linked but unused (pattern: %s)\n' \
      "$library" "$pattern" >&2
    status=1
  fi
}

check 'Qt6::Concurrent' 'QtConcurrent|QFuture'
check 'Qt6::Core'       'QCoreApplication|QString'
check 'Qt6::Gui'        'QImage|QPainter'
check 'Qt6::Widgets'    'QWidget|QApplication'
check 'Qt6::Test'       'QtTest|QTest'
if [[ "$(uname -s)" != Darwin ]]; then
  check 'PkgConfig::WaylandClient' 'wayland-client|wl_'
  check 'LayerShellQt::Interface'  'LayerShellQt|layershell'
fi

if (( status != 0 )); then
  printf 'check-unused-deps: drop the library from CMakeLists.txt or use it\n' >&2
  exit 1
fi
printf 'check-unused-deps: every linked library is used\n'
