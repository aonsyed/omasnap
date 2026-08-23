/** @fileoverview Layer-shell implementation of the overlay/pin window seam. */
#include "overlay-window.hpp"

#ifndef Q_OS_MACOS

#include <LayerShellQt/Window>

#include <QGuiApplication>
#include <QMargins>
#include <QPoint>
#include <QRect>
#include <QScreen>
#include <QSize>
#include <QWidget>
#include <QWindow>

void overlayPlatformPreinit() {
  qputenv("QT_WAYLAND_SHELL_INTEGRATION", "layer-shell");
  QGuiApplication::setDesktopFileName(QStringLiteral("omasnap"));
}

bool configureCaptureOverlay(QWidget &editor, QScreen *screen) {
  QWindow *window = editor.windowHandle();
  LayerShellQt::Window *layerWindow =
      window ? LayerShellQt::Window::get(window) : nullptr;
  if (!window || !layerWindow)
    return false;
  layerWindow->setScope(QStringLiteral("omasnap"));
  layerWindow->setScreen(screen);
  layerWindow->setLayer(LayerShellQt::Window::LayerOverlay);
  LayerShellQt::Window::Anchors anchors;
  anchors.setFlag(LayerShellQt::Window::AnchorTop);
  anchors.setFlag(LayerShellQt::Window::AnchorBottom);
  anchors.setFlag(LayerShellQt::Window::AnchorLeft);
  anchors.setFlag(LayerShellQt::Window::AnchorRight);
  layerWindow->setAnchors(anchors);
  layerWindow->setExclusiveZone(-1);
  layerWindow->setKeyboardInteractivity(
      LayerShellQt::Window::KeyboardInteractivityExclusive);
  layerWindow->setActivateOnShow(true);
  return true;
}

bool configurePinWindow(QWidget &pin, const QPoint &topLeft,
                        const QSize &availableSize) {
  static_cast<void>(pin.winId());
  QWindow *handle = pin.windowHandle();
  LayerShellQt::Window *layer =
      handle ? LayerShellQt::Window::get(handle) : nullptr;
  if (!handle || !layer)
    return false;

  layer->setScope(QStringLiteral("omasnap-pin"));
  LayerShellQt::Window::Anchors anchors;
  anchors.setFlag(LayerShellQt::Window::AnchorBottom);
  anchors.setFlag(LayerShellQt::Window::AnchorRight);
  layer->setAnchors(anchors);
  layer->setMargins(
      QMargins(0, 0, availableSize.width() - topLeft.x() - pin.width(),
               availableSize.height() - topLeft.y() - pin.height()));
  layer->setExclusiveZone(0);
  layer->setDesiredSize(pin.size());
  layer->setKeyboardInteractivity(
      LayerShellQt::Window::KeyboardInteractivityOnDemand);
  layer->setActivateOnShow(false);
  layer->setLayer(LayerShellQt::Window::LayerOverlay);
  return true;
}

void positionPinWindow(QWidget &pin, const QPoint &topLeft,
                       const QSize &availableSize) {
  if (QWindow *handle = pin.windowHandle()) {
    if (LayerShellQt::Window *layer = LayerShellQt::Window::get(handle)) {
      layer->setMargins(QMargins(
          0, 0, availableSize.width() - topLeft.x() - pin.width(),
          availableSize.height() - topLeft.y() - pin.height()));
    }
  }
}

#endif // !Q_OS_MACOS
