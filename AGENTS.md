# Omasnap — Agent Guide

Omasnap is a super fast, native screenshot and annotation overlay. It captures
region, window, or full monitor, then opens an annotation editor with vector
layers (arrows, lines, freehand, highlighter, rectangles, ellipses, numbered
markers, text, OCR). Finished captures go to clipboard,
`~/Pictures/Screenshots`, or a pinned always-on-top surface.

## Project principles

- **Speed first.** The tool must feel instant: capture, annotate, copy. No
  startup bloat, no settings UI, no wizards.
- **Dual platform, one product.** This fork keeps the original Wayland +
  Hyprland target (Omarchy primary integration) fully intact and adds native
  **macOS** as a second target. Platform differences live only in thin
  per-platform translation units behind the seam headers
  (`src/capture-platform.hpp`, `src/overlay-window.hpp`); shared code never
  branches on platform. Linux behavior stays byte-for-byte identical to
  upstream so changes remain mergeable.
- **No backwards compatibility.** Break keybindings, CLI flags, file formats,
  or internals whenever it keeps the code simpler or the tool faster. Do not
  add compatibility shims, deprecation aliases, or migration code.
- **Platform-native plumbing.** Linux uses Hyprland discovery (`hyprctl`),
  `ext-image-copy-capture`, layer-shell overlays, `wl-copy`/`wl-paste`,
  tesseract OCR, and `omarchy-notification-send`. macOS uses ScreenCaptureKit,
  `CGWindowListCopyWindowInfo`, borderless always-on-top NSPanels,
  NSPasteboard (PNG + TIFF flavors), Vision OCR, osascript notifications, and
  Carbon `RegisterEventHotKey` for `--serve`.
- **Single binary.** Everything (capture, editor, pin mode, `--serve`
  hotkeys) runs from the one executable.

## Repository layout

| Path | Purpose |
|---|---|
| `src/main.cpp` | CLI parsing, single-instance lock, mode dispatch (capture / edit file / pin / serve) |
| `src/instance-lock.cpp/.hpp` | Single-instance handover: cancel a running overlay, or stop it and take over for `--file` |
| `src/capture.cpp/.hpp` | Shared rendering, operation-log persistence, orchestration |
| `src/capture-platform.hpp` | Per-platform backend seam (probe/grab/discovery/clipboard/OCR/notification) |
| `src/capture-linux.cpp` | Wayland/Hyprland implementations of the seam |
| `src/surface-capture.cpp` | In-process output capture via `ext-image-copy-capture` (Linux only) |
| `src/capture-macos.mm` | NSScreen probe + ScreenCaptureKit grab + CGWindowList discovery |
| `src/clipboard-macos.mm`, `src/notify-macos.mm`, `src/ocr-macos.mm` | macOS clipboard, notification, Vision OCR backends |
| `src/editor.cpp/.hpp` | Annotation editor: tools, vector layers, operation-log undo/redo, export |
| `src/pin.cpp/.hpp` | Pinned-capture surfaces (bottom-right, all workspaces/Spaces) |
| `src/overlay-window.hpp` + `overlay-window-wayland.cpp` / `overlay-window-macos.mm` | Overlay/pin window seam: layer-shell vs NSPanel |
| `src/serve.cpp/.hpp`, `src/hotkeys-macos.mm` | Resident global-hotkey server (macOS) |
| `cmake/MacPackaging.cmake`, `macos/Info.plist.in` | App bundle, plist, codesign |
| `src/icons.cpp/.hpp` | Vector icon renderer for toolbar and pin controls |
| `src/cli-path.cpp/.hpp` | Command-line image target resolution |
| `src/eyedropper.cpp/.hpp` | Display-to-source color sampling |
| `src/pin-file.cpp/.hpp`, `src/pin-layout.cpp/.hpp` | Pin file lifecycle and layout helpers |
| `tests/*-smoke.cpp/.hpp` | Headless Qt Test coverage, including offscreen region-click, async-capture, and single-instance handover checks |
| `install-omarchy` | Omarchy installer (deps via `omarchy-pkg-add`, installs to `~/.local`) |
| `CMakeLists.txt` | Build definition; **the version lives here** (`project(omasnap VERSION ...)`) |

## Build and verify

Linux (Arch/Omarchy):

```bash
make check
```

macOS (Apple silicon, Homebrew):

```bash
brew install cmake ninja qt
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$(brew --prefix qt)"
cmake --build build --parallel
QT_QPA_PLATFORM=offscreen ctest --test-dir build --output-on-failure
```

`make check` configures and builds the project, runs the complete headless
offscreen Qt smoke suite (including simulated region clicks and asynchronous
capture), runs `clang-tidy`, and runs `clazy-standalone`/`qmllint` when those
tools are available. The same headless suite passes on both platforms;
platform-specific tests (Wayland cleanup, fake `wl-paste` clipboard fixtures)
are compiled/guarded out on macOS, and macOS-specific suites run everywhere.

Always run the full suite after behavioral changes. CI
(`.github/workflows/build-linux.yml`) builds and smokes Arch Linux plus a
`macos-latest` runner on every push and PR, attaching versioned artifacts for
both platforms on tags.

Dependencies (Arch): `base-devel cmake ninja pkgconf qt6-base layer-shell-qt
wayland wayland-protocols wl-clipboard tesseract tesseract-data-eng`.
Dependencies (macOS): Xcode CLT, `cmake ninja qt`; Screen Recording permission
granted once in System Settings.

## Release process

1. Bump `project(omasnap VERSION ...)` in `CMakeLists.txt`.
2. Run the full verification on both platforms.
3. Commit, tag `v<version>`, push main and the tag. The GitHub workflow
   attaches Linux and macOS artifacts to the release automatically.
4. **Update omarchy-pkgs on every new version release.** In the
   [omarchy-pkgs](https://github.com/omacom-io/omarchy-pkgs) fork
   (`pkgbuilds/omasnap/`):
   - Set `pkgver` in `PKGBUILD` to the new version.
   - Replace `sha256sums` with the hash of
     `https://github.com/tobi/omasnap/archive/refs/tags/v<version>.tar.gz`
     (`curl -sL <url> | sha256sum`).
   - Commit on a branch and open a PR to `omacom-io/omarchy-pkgs`.

See `README.md` for user-facing features, keybindings, install instructions,
and the macOS permission/signing notes — keep it in sync when behavior
changes.
