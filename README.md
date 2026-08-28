# Omasnap

A native Wayland screenshot and annotation overlay designed for Omarchy and Hyprland.
It captures the focused monitor before mapping an exclusive layer-shell surface, so the
editor never appears in its own screenshot. The editor retains annotations as movable,
resizable vector layers and preserves the monitor's native pixels on scaled displays.

[![Looping Omasnap demonstration](assets/omasnap.gif)](assets/omasnap.mp4)

## Features

- Freeform region, window, and full-monitor capture modes.
- A pointer-side readout that turns any drag into a ruler: the pointer position
  while the crosshair is idle, then the frame size in native export pixels while a
  region, a hovered window, or a crop handle is being sized.
- Window capture is a crop of the focused-monitor frame. Overlapping windows stay
  visible; there is no second clean-window recapture.
- Select/move/resize layers, mouse-wheel scaling, and eight external recropping handles.
- Arrows, straight lines, smoothed freehand strokes, translucent highlighter strokes,
  hollow or filled rectangles (optionally rounded) and ellipses, numbered markers,
  editable Neucha text (on a readability pill), and secure redaction with opaque or
  randomized non-spatial mosaic output.
- Per-layer preset or custom colors (including highlighter ink), undo/redo history,
  one-click whole-image or drag-region OCR (the recognized text is shown beside
  the image and copied to the clipboard),
  mesh-gradient backdrops, and rendered drop shadows.
- Cut tool: drag across a band of the image to remove it and collapse the gap, with a
  live preview and dashed seam marker while dragging; annotations shift to follow.
- Pin a finished capture as a bottom-right always-on-top layer surface, launched
  from the same `omasnap` executable and visible on every workspace.
- Crash-resistant working documents under `/run/user/<UID>/omasnap/` (falling back to
  a private `/tmp/omasnap-<UID>/`): the original source image plus a sidecar JSON
  operation log. Undo still works after a crash or `--file` reopen. Saving and
  copying write a normal flattened PNG to the clipboard or `~/Pictures/Screenshots`.
- Verified PNG clipboard output through `wl-copy`/`wl-paste`, plus timestamped files
  under `~/Pictures/Screenshots` by default.
- Open an image already on the clipboard directly in the annotation editor.
- Correct native-pixel export on fractional or integer-scaled monitors.

## Platform scope

This fork adds **macOS 14+ (Apple silicon)** as a second first-class target alongside the
original **Wayland + Hyprland** platform. Both share the same Qt editor, annotation
model, operation log, pins, and CLI; only thin per-platform backends differ
(`capture-linux.cpp` / `overlay-window-wayland.cpp` vs `*-macos.mm`), selected by CMake.

On Wayland, monitor/window discovery calls `hyprctl`, capture uses `ext-image-copy-capture`
in-process before the layer maps, and overlays are layer-shell surfaces.

On macOS, capture uses ScreenCaptureKit (`SCScreenshotManager`, macOS 14+), window
discovery uses `CGWindowListCopyWindowInfo`, and overlays/pins are borderless
always-on-top NSPanels that join all Spaces. OCR uses the Vision framework with no extra
dependencies. Screen Recording permission is requested on first capture: grant it in
System Settings > Privacy & Security > Screen Recording, then run omasnap again.
A stable code-signing identity avoids re-prompts after rebuilds:

```bash
cmake -S . -B build -G Ninja -DCMAKE_PREFIX_PATH="$(brew --prefix qt)" \
  -DOMASNAP_SIGN_IDENTITY="omasnap-dev"   # self-signed cert created once in Keychain Access
cmake --build build --parallel
open build/omasnap.app
```

macOS runtime behavior:

- `omasnap.app` is a menu-bar-less (`LSUIElement`) accessory app; the editor overlay and
  pinned captures float above normal windows on all Spaces.
- `omasnap --serve` registers global hotkeys (no extra permissions): ⌘⇧R region,
  ⌘⇧W window, ⌘⇧F fullscreen. Each spawns the regular one-shot CLI, so the
  toggle/dismiss instance behavior is identical to Hyprland bindings. Remap any
  combo via `OMASNAP_HOTKEY_REGION`/`_WINDOW`/`_FULLSCREEN` (e.g.
  `cmd+shift+9`; keys: a-z, 0-9, f1-f19, space, tab, return, esc, arrows).
  Alternatively wire
  your own launcher (Raycast/Hammerspoon/skhd) to the CLI modes below.
- Clipboard images persist after omasnap exits (PNG + TIFF flavors are written eagerly).

Wayland runtime commands used by the application:

- `hyprctl`
- `wl-copy` and `wl-paste`
- `tesseract`
- `omarchy-notification-send` when available; saved captures include a thumbnail and
  reopen in Omasnap when clicked. Notification failure does not invalidate output.

## Install on Omarchy

Clone the repository and run the Omarchy installer:

```bash
git clone https://github.com/tobi/omasnap.git
cd omasnap
./install-omarchy
```

The installer uses Omarchy's package helper for missing dependencies, builds in
`~/.cache/omasnap`, and installs under `~/.local`. It does not modify
Hyprland configuration.

### Hyprland binding

Paste this into a Lua config loaded after `require("default.hypr.omarchy")`:

```lua
hl.unbind("PRINT")
hl.unbind("F12")
hl.unbind("ALT + SHIFT + 4")

o.bind("PRINT", "Screenshot", "omasnap")
o.bind("F12", "Screenshot", "omasnap")
o.bind("ALT + SHIFT + 4", "Screenshot", "omasnap")

hl.layer_rule({
  match = { namespace = "^omasnap$" },
  no_anim = true,
  animation = "none",
  no_screen_share = true,
})
```

Each of these keys toggles: the first press opens the overlay, the next press dismisses it.

Apply and verify:

```bash
hyprctl reload
hyprctl configerrors
hyprctl binds -j | jq -c \
  '[.[] | select(.description == "Screenshot") | {modmask,key,description}]'
```

`omarchy plugin add` is intentionally not used. Omarchy plugins are Quickshell QML
extensions; they do not install native executables or system packages.

Set `OMASNAP_PREFIX` before running `install-omarchy` to use a prefix other than
`~/.local`.

### Manual Arch Linux build

Install the complete build/runtime dependency set:

```bash
sudo pacman -S --needed \
  base-devel cmake ninja pkgconf qt6-base layer-shell-qt \
  wayland wayland-protocols hyprland wl-clipboard \
  tesseract tesseract-data-eng
```

Build and install:

```bash
cmake -S . -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$HOME/.local"
cmake --build build --parallel
cmake --install build
```

The install step places:

- `~/.local/bin/omasnap`
- `~/.local/share/applications/omasnap.desktop`
- `~/.local/share/licenses/omasnap/Neucha-OFL.txt`

Ensure `~/.local/bin` is on `PATH`, then verify the installed CLI:

```bash
omasnap --version
omasnap --help
```

### Manual macOS build

Dependencies (Homebrew):

```bash
brew install cmake ninja qt
```

Build and run from `build/omasnap.app`. Signing with a stable self-signed identity
(created once via Keychain Access > Certificate Assistant) prevents Screen Recording
re-prompts on every rebuild:

```bash
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$(brew --prefix qt)" \
  -DOMASNAP_SIGN_IDENTITY="omasnap-dev"
cmake --build build --parallel
open build/omasnap.app
```

Headless verification is identical to Linux (`QT_QPA_PLATFORM=offscreen`; see
"Development and verification").

## CLI capture modes

Running without arguments opens freeform region selection:

```bash
omasnap
```

Explicit starting modes:

```bash
omasnap --capture-region
omasnap --capture-window
omasnap --capture-fullscreen
```

Compatibility positional names are also accepted:

```bash
omasnap region
omasnap windows
omasnap fullscreen
omasnap smart       # maps to region selection
```

These options choose what is initially selected; the editor still controls whether the
result is copied, saved, or both.

Quick output skips the annotation editor. Add `--copy` to copy only, `--save` to save
only, or both flags to copy and save. Region and window captures output after selection;
fullscreen captures output immediately. Quick output cannot be combined with `--file`,
`--clipboard`, or `--pin`.

### One instance, toggled by the same hotkey

Only one capture overlay runs at a time, guarded by a lock file in the runtime snapshot
directory. Starting omasnap while an overlay is open sends the running instance `SIGTERM`,
which it handles with a clean Qt shutdown; the new process then exits without capturing.
Pressing `PRINT` therefore opens the overlay and pressing it again dismisses it.

Every capture invocation dismisses this way, quick output included: `--copy`/`--save`
while an overlay is open closes the overlay and outputs nothing, rather than screenshotting
the overlay that is still on screen.

Editing an existing image is never cancelled this way: `--file`, `--clipboard`, or an
image path stops the running instance, waits up to two seconds for the lock, and opens the
editor on that image. That is how a pin's Edit button and a notification click always land
in the editor.

A lock left behind by a crashed instance is removed and reclaimed. A lock file that cannot
be read or written at all is reported on stderr instead of being mistaken for a running
instance.

Exit codes:

| Code | Meaning |
|---|---|
| `0` | Success, including dismissing a running overlay |
| `1` | Capture, image, or single-instance lock failure |
| `2` | Usage error |

### Edit an existing or clipboard image

Point omasnap at any readable image and it opens straight into the annotation editor
with the whole image selected, skipping the screen-capture step:

```bash
omasnap ~/Pictures/Screenshots/screenshot-2026-08-11_10-00-00.png
# or
omasnap --file /path/to/capture.png
```

To open the image currently on the Wayland clipboard:

```bash
omasnap --clipboard
```

The clipboard must offer readable image data. Text-only clipboard contents return an
error instead of opening an empty editor.

File URLs are accepted too. A saved capture notification's "Click to edit" action launches
`omasnap` on the finished screenshot, so it can be reopened and re-annotated. Captures copied
without saving are not retained on disk and therefore have no delayed edit action.

Environment overrides:

```bash
OMASNAP_SCREENSHOT_DIR="$HOME/Pictures/Captures" omasnap
OMASNAP_OCR_LANGS="eng+deu" omasnap
# Thai plus English:
OMASNAP_OCR_LANGS="tha+eng" omasnap
```

Install the corresponding Tesseract language data before adding a language to
`OMASNAP_OCR_LANGS`. When unset, omasnap falls back to Omarchy's
`OMARCHY_OCR_LANGS` (which commonly includes the user's script, e.g.
`tha+eng`), then to `eng`.

Runtime feature flags all default to enabled; disable them per invocation
with `OMASNAP_FEATURE_FLAGS` (comma-separated `name=0` or `!name`):

| Flag | Default | Disabled behavior |
|---|---|---|
| `ocr_scan_sweep` | on | OCR results appear immediately, without the scan-band animation |
| `desktop_notifications` | on | No capture notifications are sent |

```bash
OMASNAP_FEATURE_FLAGS="ocr_scan_sweep=0" omasnap
```

Observability variables (all optional, none are secrets; see
`.env.example` for the full list):

```bash
OMASNAP_TRACE_ID="abc123"      # inherited by pins and hotkey captures
OMASNAP_ANALYTICS=1            # opt-in local usage events (analytics.jsonl)
OMASNAP_METRICS_FILE=/tmp/m.json  # capture_ms / quick_output_ms samples
```

Every invocation logs `omasnap <version> trace=<id>` at startup, scrubs
credential-shaped values out of its log output, and writes a
`crash-<pid>.log` (signal, breadcrumbs, backtrace) beside the working
snapshots if it dies. Troubleshooting recipes live in
[docs/runbooks.md](docs/runbooks.md).

## Controls

### Capture selection

| Input | Action |
|---|---|
| Drag | Select a region, with its native pixel size shown at the pointer |
| `Space` | Toggle region/window selection |
| `SUPER + Arrow` | Move among windows in window mode |
| `Enter` | Capture the highlighted window |
| `Ctrl+A` | Select the full focused monitor |
| `Esc`, `Esc` | Dismiss |

### Annotation editor

| Input | Action |
|---|---|
| `V` | Select/move/resize layers; drag empty canvas for a marquee; wheel scales the selected layer |
| `A` | Arrow |
| `S` | Spotlight/loupe; press again to cycle ellipse, rectangle, rounded |
| `L` | Straight line |
| `F` | Freehand stroke |
| `I` | Eyedropper in the color popover · sample the image as the custom color |
| `C` | Numbered marker |
| `R` | Rectangle; hover the shape button for rectangle, ellipse, and fill controls; `Alt`+wheel rounds corners |
| `E` | Ellipse; shares the shape submenu and filled/hollow toggle |
| `D` | Redact; press again to toggle randomized pixelation or solid redaction |
| `X` | Cut out a band; drag to preview the crossed-out strip, then release to remove and collapse it |
| `T` | Neucha text on a cream readability pill; Enter adds a line, clicking away keeps the text; press T again to toggle the pill |
| `O` | Recognize and copy all text in the current image |
| `B` | Cycle backdrop |
| `1`–`8` | Set annotation color; `7` is black and `8` is white |
| Wheel | Scale selected layer, magnify the spotlight under the cursor, or change active tool size (`Alt`+wheel: rectangle corner radius or spotlight border); while just viewing a zoomed capture, scroll it like a document |
| `Shift`+wheel | Scroll a zoomed capture sideways (a wide stitch); never changes the zoom |
| `Ctrl`+wheel · middle-drag | Zoom about the cursor · pan by dragging |
| `+` / `-` / `0` (also with `Ctrl`) | Zoom in / out / fit |
| Hold `Shift` while dragging | Make rectangles, ellipses, and spotlights 1:1; snap lines and arrows to 45°; while dragging a selected layer's handle, keep a rectangle, redaction or spotlight's aspect ratio (lines and arrows: 45°) |
| Hold `Alt` while dragging | Center rectangles, ellipses, and spotlights on the press point; add `Shift` for a centered square/circle |
| `←` `↑` `→` `↓` | Nudge the selected layer 1 px; hold `Shift` for 10 px (a held key is one undo step). With nothing selected, pan a zoomed capture |
| Double-click text | Reopen text editing |
| `Delete` | Delete selected layer |
| `Alt+D` | Duplicate selected layer (offset down-left, or away from a nearby edge); the copy becomes the selection |
| `Ctrl+Z` | Undo |
| `Ctrl+Shift+Z`, `Ctrl+Y` | Redo |
| `Ctrl+C` | Copy PNG only |
| `Ctrl+S` | Save PNG only |
| `Enter` | Copy and save |
| `P` | Pin the capture on screen and close the editor |
| `Esc` | Return to Select; press again to close |
| Right-click | Return to Select; cancel active drawing |

### Pinned captures

`P` renders the current capture, writes it to a `pin-<pid>-<n>-<random>.png` under
the runtime snapshot directory, and launches the same `omasnap` executable in
detached pin mode. Active pins stack from the bottom-right and can be dragged
by the image background. The layer stays visible on every workspace without
compositor window rules. It preserves the image
aspect ratio, with a maximum width of one third of the screen and a maximum height of one
half.

Pinning neither touches the clipboard nor writes to the screenshot directory; it is a
fourth output alongside copy, save, and copy-and-save. `P` closes the editor and releases
the single-instance lock immediately. Pins from separate captures accumulate as independent
processes.

Hover the pin to reveal its controls:

| Input on a pin | Action |
|---|---|
| Edit button | Reopen the full-resolution PNG in Omasnap and replace the pin |
| Link button | Copy the source file path |
| Copy button, `Ctrl+C` | Copy the full-resolution PNG |
| Double-wide top-left drag handle | Drag the PNG into a file-capable drop target |
| Wheel | Resize within the screen caps, preserving aspect ratio |
| Close button, `Esc`, middle-click | Close |

Image and path copying use `wl-copy` rather than `QClipboard`, so clipboard data remains
available after the pin is closed. No font-based symbol set or compositor-specific window
rule is required; the controls use the same vector icon renderer as the annotation toolbar.

Creation tools return to Select after one placement without selecting the new layer. In
Select mode, arrows and lines show only their two endpoint handles; other layers show a
selection boundary. The eight blue/white handles outside the image recrop its corners or
edges.

## Development and verification

```bash
make check
```

The smoke executable exercises region/window/fullscreen startup modes, capture selection,
working-document persistence (source plus op-log JSON), annotation tools, undo/redo
replay, vector movement and scaling, text editing, OCR, native-DPI output,
endpoint-only line selection, external crop handles, and the native-pixel
measurement readout on a scaled monitor.

Each standalone suite is also registered as its own CTest entry
(`ctest --test-dir build`), so the suite can run randomized and in parallel:

```bash
ctest --test-dir build --parallel 2 --schedule-random --output-on-failure
```

Repository guards run before every push (`pre-commit install` once) and in CI:

```bash
make guards     # TODO scan, 5 MB file budget, unused deps, feature flags, AGENTS.md paths
make format     # clang-format (see .clang-format)
make docs       # Doxygen HTML reference into build/docs/html
scripts/flamegraph.sh   # perf flame graph of the smoke suite (Linux)
```

`.github/workflows/` covers more than the build: `build-linux.yml` runs the
same `make check` build, interaction smoke, and available static-analysis
checks in a pinned Arch Linux container (ccache-cached), stages the CMake
installation, uploads a versioned Linux artifact, and runs the headless smoke
suite on a macOS runner (`macos-latest`, Homebrew Qt) so both platforms stay
green on every push. `quality.yml` adds complexity/duplication reports and
Doxygen docs; `coverage.yml` enforces a line-coverage gate;
`codeql.yml` runs C/C++ SAST; `pr-review.yml` posts a clang-tidy + format
review comment on pull requests; `alert.yml` files a `ci`-labeled issue when
main goes red. A `v*` tag attaches both artifacts to the corresponding GitHub
release (with generated release notes). Dependency pinning and update policy:
[docs/dependency-policy.md](docs/dependency-policy.md). Operational runbooks:
[docs/runbooks.md](docs/runbooks.md).

## Acknowledgements

The capture and annotation workflow is inspired by three excellent screenshot tools:

- [Shottr](https://shottr.cc/) — fast region/window capture, OCR, and polished backdrops.
- [Satty](https://github.com/Satty-org/Satty) — a focused, Wayland-native annotation workflow.
- [Flameshot](https://github.com/flameshot-org/flameshot) — selection-first capture and an
  approachable annotation toolbar.

Thanks to their authors and contributors for establishing the interaction patterns that made
this project possible. Omasnap is an independent implementation and is not
affiliated with those projects.

## Project history

This standalone repository was extracted with `git filter-repo` from the original Omarchy
system-customization repository. The former `omasnap/` directory was promoted to
the repository root while retaining its relevant commit history.

The bundled Neucha font is distributed under the SIL Open Font License; its license is in
`assets/OFL.txt` and is installed with the application.
