/** @fileoverview macOS NSPanel implementation of the overlay/pin window seam. */
#include "overlay-window.hpp"

#ifdef __APPLE__

#import <AppKit/AppKit.h>

#include <QGuiApplication>
#include <QPoint>
#include <QRect>
#include <QScreen>
#include <QSize>
#include <QWidget>

namespace {

/** Native window backing a Qt widget (winId() is the content NSView). */
NSWindow *nativeWindow(QWidget &widget) {
  static_cast<void>(widget.winId()); // Force native-handle creation.
  NSView *view = reinterpret_cast<NSView *>(widget.winId());
  return view.window;
}

/**
 * Converts a Qt global top-left-origin point rect into a Cocoa bottom-left-
 * origin frame. Cocoa coordinates are anchored at the primary screen's
 * bottom-left corner, whose top edge sits at primaryHeight in Qt's space.
 */
NSRect cocoaFrame(const QRect &qtFrame) {
  const QRect primary =
      QGuiApplication::primaryScreen()
          ? QGuiApplication::primaryScreen()->geometry()
          : QRect(0, 0, qtFrame.width(), qtFrame.height());
  NSRect frame;
  frame.origin.x = qtFrame.x();
  frame.origin.y = primary.height() - qtFrame.y() - qtFrame.height();
  frame.size.width = qtFrame.width();
  frame.size.height = qtFrame.height();
  return frame;
}

/** Shared styling: frameless, translucent, above everything, on all Spaces,
 *  never hidden when the owning app deactivates. */
void styleOverlayWindow(NSWindow *window, bool movable) {
  window.styleMask = NSWindowStyleMaskBorderless;
  // Above the menu bar and every regular window; ScreenCaptureKit frames are
  // taken before this maps, so shielding-level placement photographs nothing.
  window.level = CGShieldingWindowLevel();
  window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                              NSWindowCollectionBehaviorFullScreenAuxiliary |
                              NSWindowCollectionBehaviorIgnoresCycle;
  window.opaque = NO;
  window.backgroundColor = [NSColor clearColor];
  window.hasShadow = NO;
  window.movable = movable ? YES : NO;
  window.hidesOnDeactivate = NO;
  window.releasedWhenClosed = NO;
  window.restorable = NO;
  window.acceptsMouseMovedEvents = YES;
}

} // namespace

void overlayPlatformPreinit() {}

bool configureCaptureOverlay(QWidget &editor, QScreen *screen) {
  NSWindow *window = nativeWindow(editor);
  if (!window)
    return false;

  styleOverlayWindow(window, /*movable=*/false);

  // Qt already positioned the widget onto `screen`; keep them consistent.
  if (screen)
    [window setFrame:cocoaFrame(screen->geometry()) display:NO];

  // The editor must own the keyboard immediately, like layer-shell's
  // exclusive interactivity, without requiring a click first.
  [window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
  return true;
}

bool configurePinWindow(QWidget &pin, const QPoint &topLeft,
                        const QSize &availableSize) {
  NSWindow *window = nativeWindow(pin);
  if (!window)
    return false;

  styleOverlayWindow(window, /*movable=*/false);
  // Pins float above normal windows but below a live capture overlay.
  window.level = CGShieldingWindowLevel() - 1;

  const QScreen *screen =
      pin.screen() ? pin.screen() : QGuiApplication::primaryScreen();
  const QRect available = screen
                              ? screen->availableGeometry()
                              : QRect(QPoint(), availableSize);
  const QRect qtFrame(available.topLeft() + topLeft, pin.size());
  [window setFrame:cocoaFrame(qtFrame) display:NO];
  [window orderFrontRegardless];
  return true;
}

void positionPinWindow(QWidget &pin, const QPoint &topLeft,
                       const QSize &availableSize) {
  NSWindow *window = nativeWindow(pin);
  if (!window)
    return;
  const QScreen *screen =
      pin.screen() ? pin.screen() : QGuiApplication::primaryScreen();
  const QRect available = screen
                              ? screen->availableGeometry()
                              : QRect(QPoint(), availableSize);
  const QRect qtFrame(available.topLeft() + topLeft, pin.size());
  [window setFrame:cocoaFrame(qtFrame) display:YES];
}

#endif // __APPLE__
