/** @fileoverview Declares the per-platform capture backend seam.
 *
 * Every symbol here has exactly one definition per platform:
 * `capture-linux.cpp` (+ Wayland helpers) on Linux, and `capture-macos.mm`
 * / `clipboard-macos.mm` / `notify-macos.mm` / `ocr-macos.mm` on macOS.
 * Shared orchestration lives in capture.cpp and calls only these seams, so
 * platform behavior stays isolated to one translation unit per concern.
 */
#pragma once

#include "capture.hpp"

/** Probes the focused display into `monitor`. */
[[nodiscard]] bool probeFocusedMonitorImpl(MonitorInfo &monitor,
                                           QString &error);
/** Grabs the named display's pixels at native resolution. Pure I/O and image
 *  work: safe on any thread, must complete synchronously before any overlay
 *  window maps. */
[[nodiscard]] bool grabMonitorPixelsImpl(const MonitorInfo &monitor,
                                         QImage &image, QString &error);
/** Starts window discovery so it can overlap the pixel grab. Returns an
 *  opaque handle (may be null); always pair with finish/cancel. */
[[nodiscard]] void *beginWindowDiscoveryImpl();
/** Drains the discovery handle into window targets relative to `monitor`.
 *  Consumes (frees) the handle. */
[[nodiscard]] QVector<WindowTarget> finishWindowDiscoveryImpl(
    void *handle, const MonitorInfo &monitor);
/** Abandons a discovery handle after a failed grab without waiting on it. */
void cancelWindowDiscoveryImpl(void *handle);

/** Reads the current clipboard image honoring the shared MIME preference
 *  order (png, jpeg, webp, bmp, then other image types). */
[[nodiscard]] bool loadClipboardImageImpl(QImage &image, QString &error);
/** Places PNG bytes on the clipboard where they survive this process. */
[[nodiscard]] bool copyPngToClipboardImpl(const QByteArray &png,
                                          QString &error);
/** Places UTF-8 text on the clipboard where it survives this process. */
[[nodiscard]] bool copyTextToClipboardImpl(const QString &text,
                                           QString &error);
/** Recognizes text in `image`; empty result means no text found. */
[[nodiscard]] QString recognizeTextImpl(const QImage &image, QString &error);
/** Best-effort fire-and-forget capture notification. */
void sendCaptureNotificationImpl(const QString &message,
                                 const QString &imagePath);
/** Encodes `image` as lossless PNG using the platform's fastest encoder.
 *  Pixels must survive the round trip bit-identically. */
[[nodiscard]] QByteArray encodePngImpl(const QImage &image);
