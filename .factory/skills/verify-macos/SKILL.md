---
name: verify-macos
description: Build omasnap on macOS and run the full headless verification suite offscreen
---

# Verify on macOS

From the repository root (dependencies: Xcode CLT, Homebrew
`cmake ninja qt`):

```bash
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$(brew --prefix qt)"
cmake --build build --parallel
QT_QPA_PLATFORM=offscreen ctest --test-dir build --output-on-failure
```

All tests must pass. For a working overlay (not headless), build with
`-DOMASNAP_SIGN_IDENTITY="omasnap-dev"` (one-time:
`scripts/macos-dev-cert.sh`), then `open build/omasnap.app` and run one
`--capture-region` to confirm the Screen Recording grant.

Guard scripts run too: `make guards` (todo scan, file budget, unused deps,
feature flags, AGENTS.md paths).
