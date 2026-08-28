# Runbooks

Operational playbooks for omasnap: local troubleshooting, release
verification, and CI failure triage. The tool is a single offline binary, so
"production" means a tagged release plus the CI pipeline that builds it.

## Runtime troubleshooting

**Screen Recording permission (macOS) loops on every rebuild.** Sign with a
stable identity so the TCC grant survives rebuilds:

```bash
scripts/macos-dev-cert.sh   # once
cmake -S . -B build -G Ninja -DCMAKE_PREFIX_PATH="$(brew --prefix qt)" \
  -DOMASNAP_SIGN_IDENTITY="omasnap-dev"
```

**A capture overlay will not open.** A stale single-instance lock (crashed
process) is reclaimed automatically; if `omasnap` reports a lock error, check
`/run/user/<UID>/omasnap/omasnap.instance` (or `/tmp/omasnap-<UID>/`) and the
`crash-<pid>.log` files beside it. Each crash log carries the signal, the
session trace id, the breadcrumb ring, and a backtrace.

**Following one capture across processes.** Every invocation logs
`omasnap <version> trace=<id>` at startup. Pins and hotkey-spawned captures
inherit `OMASNAP_TRACE_ID`, so `grep trace=<id>` over logs, crash files, and
analytics events reconstructs the whole session.

**OCR returns nothing (Wayland).** `tesseract` must be installed with the
requested language data; check `OMASNAP_OCR_LANGS` / `OMARCHY_OCR_LANGS`
(documented in `.env.example`).

**Clipboard output missing after quit (Wayland).** `wl-copy` must be on
`PATH`; omasnap deliberately avoids `QClipboard` so data survives the
process. Notification failure is non-fatal by design; disable notifications
entirely with `OMASNAP_FEATURE_FLAGS=desktop_notifications=0`.

**Performance.** Set `OMASNAP_METRICS_FILE=/tmp/m.json`, run a capture, and
read `capture_ms` / `quick_output_ms`. For deep dives: `scripts/flamegraph.sh`
(Linux) or Instruments > Time Profiler on `build/omasnap.app` (macOS).

## Release verification

1. Confirm the tag's **Build Linux** workflow run is green on both the Arch
   and macOS jobs (Actions → the `v*` run). This is the deploy health check.
2. Open the GitHub release: both artifacts
   (`omasnap-<version>-archlinux-x86_64.tar.gz`,
   `omasnap-<version>-macos-arm64.zip`) must be attached.
3. Spot-check locally: download the artifact, extract, run
   `omasnap --version` and one `--capture-fullscreen --copy`.
4. File the omarchy-pkgs PR (see AGENTS.md, "Release process").

Where to check deploy impact: the workflow run page (timing and failures),
the release page (asset downloads), and omarchy-pkgs PR comments.

## CI failure triage

`alert.yml` opens a `ci`-labeled issue automatically when a workflow fails on
main. Triage in order:

1. Read the failing job's log from the linked run.
2. `quality` failures are guard scripts — run `make guards` locally to
   reproduce (todo scan, file budget, unused deps, feature flags, AGENTS.md
   paths, formatting of changed files).
3. `build` failures: reproduce with `make check` on Arch, or the macOS
   commands in AGENTS.md.
4. `coverage` failures mean the line coverage dropped below the gate
   (`.github/workflows/coverage.yml` `MIN_LINE_COVERAGE`); run the lcov
   commands from the workflow locally to inspect.
5. Close the issue with the fixing PR; the alert workflow reopens a fresh
   issue only for new failures.
