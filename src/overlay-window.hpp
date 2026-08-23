/** @fileoverview Declares the platform window seam for overlays and pins.
 *
 * Implemented once per platform: `overlay-window-wayland.cpp` configures
 * layer-shell surfaces; `overlay-window-macos.mm` styles borderless always-
 * on-top NSPanels. Callers stay platform-agnostic.
 */
#pragma once

class QPoint;
class QSize;
class QScreen;
class QWidget;

/** Runs before QApplication is constructed for platform environment wiring. */
void overlayPlatformPreinit();

/** Configures `editor` as the fullscreen capture overlay covering its screen.
 *  The widget must already have a native handle (`winId()` called). Returns
 *  false when the platform overlay surface could not be created. */
[[nodiscard]] bool configureCaptureOverlay(QWidget &editor, QScreen *screen);

/** Configures `pin` as an always-on-top pin surface placed at `topLeft`,
 *  relative to its screen's availableGeometry topLeft, sized `pin.size()`.
 *  The widget must already have a native handle. */
[[nodiscard]] bool configurePinWindow(QWidget &pin, const QPoint &topLeft,
                                      const QSize &availableSize);

/** Repositions a mapped pin window using the same coordinates as
 *  configurePinWindow. */
void positionPinWindow(QWidget &pin, const QPoint &topLeft,
                       const QSize &availableSize);
