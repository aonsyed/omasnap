/** @fileoverview macOS display probe, pixel grab (ScreenCaptureKit), and
 *  window discovery for the capture seam. */
#include "capture-platform.hpp"

#ifdef __APPLE__

#include <AppKit/AppKit.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ScreenCaptureKit/ScreenCaptureKit.h>

#include <QGuiApplication>
#include <QScreen>

#include <unistd.h>

#include <cstring>
#include <condition_variable>
#include <limits>
#include <mutex>
#include <optional>
#include <thread>

namespace {

constexpr int kMaxOnlineDisplays = 16;
constexpr int64_t kCaptureTimeoutNs = 5LL * NSEC_PER_SEC;

/** SCShareableContent costs ~30 ms to fetch and only depends on TCC, not on
 *  the capture target, so the (instant) monitor probe kicks the fetch off and
 *  the grab joins it instead of paying the round trip serially. */
SCShareableContent *takePrefetchedShareableContent() {
  static std::mutex mutex;
  static std::condition_variable ready;
  static SCShareableContent *prefetched = nil;
  static bool fetchStarted = false;
  static bool fetchComplete = false;

  std::unique_lock<std::mutex> lock(mutex);
  if (!fetchStarted) {
    fetchStarted = true;
    lock.unlock();
    @autoreleasepool {
      dispatch_semaphore_t done = dispatch_semaphore_create(0);
      __block SCShareableContent *fetched = nil;
      [SCShareableContent
          getShareableContentExcludingDesktopWindows:NO
                                 onScreenWindowsOnly:YES
                                   completionHandler:^(
                                       SCShareableContent *result,
                                       NSError *error) {
                                     fetched = [result retain];
                                     static_cast<void>(error);
                                     dispatch_semaphore_signal(done);
                                   }];
      dispatch_semaphore_wait(
          done, dispatch_time(DISPATCH_TIME_NOW, kCaptureTimeoutNs));
      lock.lock();
      prefetched = fetched;
      fetchComplete = true;
      lock.unlock();
      ready.notify_all();
    }
  } else {
    ready.wait_for(lock, std::chrono::seconds(5),
                   [&] { return fetchComplete; });
  }
  return prefetched; // Retained once for the process lifetime.
}

/** Starts the prefetch without blocking; called from the fast probe path. */
void prefetchShareableContent() {
  static std::once_flag once;
  std::call_once(once, [] {
    std::thread([] { (void)takePrefetchedShareableContent(); }).detach();
  });
}

QRect toQRect(const CGRect &rect) {
  return QRect(qRound(rect.origin.x), qRound(rect.origin.y),
               qRound(rect.size.width), qRound(rect.size.height));
}

/** Renders a CGImage into an upright ARGB32_Premultiplied image.
 *  Fast path: ScreenCaptureKit delivers 8bpc little-endian BGRA premultiplied
 *  rasters; those are byte-compatible with QImage::Format_ARGB32_Premultiplied
 *  and copy without a compositing pass. */
bool cgImageToQImage(CGImageRef cgImage, QImage &image) {
  const size_t width = CGImageGetWidth(cgImage);
  const size_t height = CGImageGetHeight(cgImage);
  if (width == 0 || height == 0 ||
      width > size_t(std::numeric_limits<int>::max()) ||
      height > size_t(std::numeric_limits<int>::max()))
    return false;

  const bool byteCompatible =
      CGImageGetBitsPerComponent(cgImage) == 8 &&
      CGImageGetBitsPerPixel(cgImage) == 32 &&
      (CGImageGetBitmapInfo(cgImage) & kCGBitmapByteOrderMask) ==
          kCGBitmapByteOrder32Little &&
      CGImageGetAlphaInfo(cgImage) == kCGImageAlphaPremultipliedFirst;
  if (byteCompatible) {
    CFDataRef raster =
        CGDataProviderCopyData(CGImageGetDataProvider(cgImage));
    if (raster) {
      const size_t stride = CGImageGetBytesPerRow(cgImage);
      const uchar *bytes = CFDataGetBytePtr(raster);
      const size_t needed = stride * (height - 1) + width * 4;
      if (static_cast<size_t>(CFDataGetLength(raster)) >= needed) {
        if (stride == width * 4) {
          image = QImage(bytes, int(width), int(height), int(stride),
                         QImage::Format_ARGB32_Premultiplied)
                      .copy(); // Single memcpy; detaches from the CF buffer.
        } else {
          QImage direct(int(width), int(height),
                        QImage::Format_ARGB32_Premultiplied);
          for (size_t y = 0; y < height; ++y)
            memcpy(direct.scanLine(int(y)), bytes + y * stride, width * 4);
          image = direct;
        }
        CFRelease(raster);
        return true;
      }
      CFRelease(raster);
    }
  }

  QImage result(int(width), int(height), QImage::Format_ARGB32_Premultiplied);
  // Qt's ARGB32_Premultiplied memory layout matches a little-endian BGRA
  // premultiplied bitmap context. ScreenCaptureKit frames draw upright into
  // this buffer without a flip; a manual CTM flip inverts them (verified
  // empirically against marked-frame captures).
  CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  const auto alphaAndOrder = static_cast<uint32_t>(
                                   static_cast<uint32_t>(
                                       kCGImageAlphaPremultipliedFirst) |
                                   static_cast<uint32_t>(
                                       kCGBitmapByteOrder32Little));
  CGContextRef context =
      CGBitmapContextCreate(result.bits(), width, height, 8,
                            result.bytesPerLine(), colorSpace, alphaAndOrder);
  CGColorSpaceRelease(colorSpace);
  if (!context)
    return false;
  CGContextDrawImage(
      context, CGRectMake(0.0, 0.0, CGFloat(width), CGFloat(height)), cgImage);
  CGContextRelease(context);
  image = result;
  return true;
}

/** Matches a monitor to its display via global point-space bounds; center-point
 *  containment first, exact rect match as fallback, pixel-size sanity check to
 *  pick between candidates. */
std::optional<CGDirectDisplayID> findDisplayForMonitor(const MonitorInfo &monitor) {
  CGDirectDisplayID onlineDisplays[kMaxOnlineDisplays];
  uint32_t displayCount = 0;
  if (CGGetOnlineDisplayList(kMaxOnlineDisplays, onlineDisplays,
                             &displayCount) != kCGErrorSuccess ||
      displayCount == 0)
    return {};

  const QPointF center(monitor.geometry.center());
  std::optional<CGDirectDisplayID> centerMatch;
  std::optional<CGDirectDisplayID> looseMatch;
  for (uint32_t index = 0; index < displayCount; ++index) {
    const CGDirectDisplayID displayId = onlineDisplays[index];
    const QRect bounds = toQRect(CGDisplayBounds(displayId));
    const bool containsCenter = bounds.contains(center.toPoint());
    if (!containsCenter && bounds != monitor.geometry)
      continue;
    const bool sizeMatches =
        CGDisplayPixelsWide(displayId) ==
            size_t(monitor.pixelSize.width()) &&
        CGDisplayPixelsHigh(displayId) ==
            size_t(monitor.pixelSize.height());
    if (containsCenter && sizeMatches)
      return displayId;
    if (containsCenter && !centerMatch)
      centerMatch = displayId;
    if (!looseMatch)
      looseMatch = displayId;
  }
  if (centerMatch)
    return centerMatch;
  return looseMatch;
}

API_AVAILABLE(macos(14.0))
bool grabWithScreenCaptureKitOnQueue(CGDirectDisplayID displayId,
                                     const QSize &pixelSize, QImage &image,
                                     QString &error) {
  @autoreleasepool {
    // Fetched concurrently with process startup by the monitor probe.
    SCShareableContent *content = takePrefetchedShareableContent();
    if (!content) {
      error = QStringLiteral("Could not capture display");
      return false;
    }

    SCDisplay *display = nil;
    for (SCDisplay *candidate in content.displays) {
      if (candidate.displayID == displayId) {
        display = candidate;
        break;
      }
    }
    if (!display) {
      error = QStringLiteral("Could not capture display");
      return false;
    }

    SCContentFilter *filter =
        [[SCContentFilter alloc] initWithDisplay:display
                           excludingApplications:@[]
                                exceptingWindows:@[]];
    SCStreamConfiguration *configuration = [[SCStreamConfiguration alloc] init];
    // Native backing-store pixels, not point dimensions: the editor expects
    // source.size() == previewSize * scale for pixel-exact Retina exports.
    configuration.width = static_cast<NSInteger>(pixelSize.width());
    configuration.height = static_cast<NSInteger>(pixelSize.height());
    configuration.showsCursor = NO;

    __block CGImageRef captured = nullptr;
    __block NSError *captureError = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [SCScreenshotManager captureImageWithFilter:filter
                                  configuration:configuration
                              completionHandler:^(CGImageRef result,
                                                  NSError *screenshotError) {
                                captured = result;
                                if (captured)
                                  CFRetain(captured);
                                captureError = [screenshotError retain];
                                dispatch_semaphore_signal(done);
                              }];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
                                                    kCaptureTimeoutNs)) != 0) {
      error = QStringLiteral("Screen capture timed out");
      [filter release];
      [configuration release];
      return false;
    }
    [filter release];
    [configuration release];
    if (!captured || captureError) {
      [captureError release];
      if (captured)
        CFRelease(captured);
      error = QStringLiteral("Could not capture display");
      return false;
    }
    [captureError release];

    const bool converted = cgImageToQImage(captured, image);
    CFRelease(captured);
    if (!converted)
      error = QStringLiteral("Could not capture display");
    return converted;
  }
}

/** ScreenCaptureKit expects to service its callbacks off its own internal
 *  machinery, so drive it from a dedicated serial queue and block the calling
 *  worker thread until the grab finishes. */
API_AVAILABLE(macos(14.0))
bool grabWithScreenCaptureKit(CGDirectDisplayID displayId,
                              const QSize &pixelSize, QImage &image,
                              QString &error) {
  static dispatch_queue_t sckQueue;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sckQueue = dispatch_queue_create("omasnap.sck.capture", DISPATCH_QUEUE_SERIAL);
  });
  __block bool success = false;
  dispatch_sync(sckQueue, ^{
    success = grabWithScreenCaptureKitOnQueue(displayId, pixelSize, image, error);
  });
  return success;
}

// CGDisplayCreateImage is obsoleted (compile-time unavailable) on modern SDKs
// yet still exported for binary compatibility, so bind to its symbol directly;
// the pre-14 fallback below is the only caller and stays runtime-gated.
extern "C" CGImageRef __nullable legacyDisplayCreateImage(CGDirectDisplayID display)
    __asm__("_CGDisplayCreateImage");

/** Pre-14 fallback: deprecated but functional single-shot display readback. */
bool grabWithDisplayCreateImage(CGDirectDisplayID displayId, QImage &image,
                                QString &error) {
  CGImageRef captured = legacyDisplayCreateImage(displayId);
  if (!captured) {
    error = QStringLiteral("Could not capture display");
    return false;
  }
  const bool converted = cgImageToQImage(captured, image);
  CFRelease(captured);
  if (!converted)
    error = QStringLiteral("Could not capture display");
  return converted;
}

} // namespace

bool probeFocusedMonitorImpl(MonitorInfo &monitor, QString &error) {
  // The probe is the first capture step and costs microseconds; use it to
  // hide the ~30 ms SCShareableContent fetch behind process startup.
  prefetchShareableContent();

  // CGEventGetLocation reports global top-left point coordinates, the same
  // space Qt uses for screen geometry.
  CGEventRef event = CGEventCreate(nullptr);
  const CGPoint pointer = event ? CGEventGetLocation(event) : CGPointMake(0, 0);
  if (event)
    CFRelease(event);
  const QPoint pointerPos(qRound(pointer.x), qRound(pointer.y));

  QScreen *screen = nullptr;
  for (QScreen *candidate : QGuiApplication::screens()) {
    if (candidate->geometry().contains(pointerPos)) {
      screen = candidate;
      break;
    }
  }
  if (!screen)
    screen = QGuiApplication::primaryScreen();
  if (!screen) {
    error = QStringLiteral("No display available");
    return false;
  }

  monitor.name = screen->name();
  monitor.geometry = screen->geometry();
  monitor.scale = screen->devicePixelRatio();
  monitor.pixelSize = {qRound(monitor.geometry.width() * monitor.scale),
                       qRound(monitor.geometry.height() * monitor.scale)};
  monitor.workspaceId = 0;
  return true;
}

bool grabMonitorPixelsImpl(const MonitorInfo &monitor, QImage &image,
                           QString &error) {
  // TCC gate first: without screen recording permission every capture path
  // returns black frames or fails outright. CGRequestScreenCaptureAccess is
  // what makes macOS show the consent dialog (and offer to open System
  // Settings); preflight alone never prompts.
  if (!CGPreflightScreenCaptureAccess()) {
    static_cast<void>(CGRequestScreenCaptureAccess());
    error = QStringLiteral(
                "Screen recording permission is required. Approve omasnap in "
                "System Settings > Privacy & Security > Screen Recording, "
                "then quit and reopen it.");
    return false;
  }

  const std::optional<CGDirectDisplayID> displayId =
      findDisplayForMonitor(monitor);
  if (!displayId) {
    error = QStringLiteral("Could not find the focused display");
    return false;
  }

  if (@available(macOS 14.0, *))
    return grabWithScreenCaptureKit(*displayId, monitor.pixelSize, image, error);
  return grabWithDisplayCreateImage(*displayId, image, error);
}

void *beginWindowDiscoveryImpl() {
  // Snapshot the on-screen window list before the pixel grab so discovery
  // overlaps the capture, mirroring the Wayland path's hyprctl overlap.
  const CFArrayRef windowList = CGWindowListCopyWindowInfo(
      kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
  return const_cast<void *>(static_cast<const void *>(windowList));
}

QVector<WindowTarget> finishWindowDiscoveryImpl(void *handle,
                                                const MonitorInfo &monitor) {
  QVector<WindowTarget> targets;
  CFArrayRef windowList = static_cast<CFArrayRef>(handle);
  if (!windowList)
    return targets;
  @autoreleasepool {

    // kCGWindowBounds shares Qt's global top-left point space with
    // monitor.geometry; translate into monitor-relative coordinates and drop
    // windows that fall outside the capture.
    const QRect clip(QPoint(), monitor.geometry.size());
    for (NSDictionary *info in (__bridge NSArray *)windowList) {
      NSNumber *ownerPid = info[(NSString *)kCGWindowOwnerPID];
      if (ownerPid.intValue == getpid())
        continue;
      NSNumber *layer = info[(NSString *)kCGWindowLayer];
      if (layer.intValue != 0)
        continue;
      NSNumber *windowNumber = info[(NSString *)kCGWindowNumber];
      if (!windowNumber)
        continue;
      CGRect bounds = CGRectNull;
      if (!CGRectMakeWithDictionaryRepresentation(
              (__bridge CFDictionaryRef)info[(NSString *)kCGWindowBounds],
              &bounds))
        continue;

      QRect rect = toQRect(bounds).translated(-monitor.geometry.topLeft());
      rect = rect.intersected(clip);
      if (rect.isEmpty())
        continue;

      NSString *name = info[(NSString *)kCGWindowName];
      NSString *ownerName = info[(NSString *)kCGWindowOwnerName];

      WindowTarget target;
      target.rect = rect;
      target.stableId = QString::number(windowNumber.unsignedIntValue);
      target.title = name.length > 0 ? QString::fromNSString(name)
                     : ownerName.length > 0 ? QString::fromNSString(ownerName)
                                            : QStringLiteral("window");
      targets.append(target);
    }
    CFRelease(windowList);
  }
  return targets;
}

void cancelWindowDiscoveryImpl(void *handle) {
  if (handle)
    CFRelease(static_cast<CFArrayRef>(handle));
}

QByteArray encodePngImpl(const QImage &image) {
  if (image.isNull())
    return {};
  @autoreleasepool {
    // Un-premultiply in Qt before handing pixels to CoreGraphics: PNG stores
    // straight alpha, and Qt's and CG's premultiplied<->straight rounding
    // differ by an LSB on semi-transparent pixels. One Qt-side conversion
    // makes the round trip bit-identical for every pixel (verified
    // pixel-exhaustively, including alpha gradients).
    const QImage straight = image.format() == QImage::Format_ARGB32
                                ? image
                                : image.convertToFormat(QImage::Format_ARGB32);
    CGImageRef cgImage = straight.toCGImage();
    if (!cgImage)
      return QByteArray();

    // ~6x faster than libpng on multi-megapixel captures, still lossless.
    CFMutableDataRef memory = CFDataCreateMutable(kCFAllocatorDefault, 0);
    CGImageDestinationRef destination = CGImageDestinationCreateWithData(
        memory, CFSTR("public.png"), 1, nullptr);
    if (!destination) {
      CFRelease(memory);
      CFRelease(cgImage);
      return {};
    }
    CGImageDestinationAddImage(destination, cgImage, nullptr);
    const bool finalized = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CFRelease(cgImage);
    if (!finalized) {
      CFRelease(memory);
      return {};
    }
    const QByteArray png(reinterpret_cast<const char *>(CFDataGetBytePtr(memory)),
                         int(CFDataGetLength(memory)));
    CFRelease(memory);
    // ImageIO embeds an iCCP profile; Qt's libpng writer does not. A tagged
    // decode makes QImage::operator== fail against untagged peers even with
    // identical pixels, so strip color-metadata chunks for byte parity with
    // the Linux output.
    static const char *const kColorChunks[] = {"iCCP", "sRGB", "gAMA", "cHRM"};
    QByteArray stripped;
    stripped.reserve(png.size());
    stripped.append(png.constData(), 8); // PNG signature
    const uchar *cursor =
        reinterpret_cast<const uchar *>(png.constData());
    const uchar *const end = cursor + png.size();
    cursor += 8;
    while (cursor + 8 <= end) {
        const quint32 length = (quint32(cursor[0]) << 24) |
                               (quint32(cursor[1]) << 16) |
                               (quint32(cursor[2]) << 8) | quint32(cursor[3]);
        const char *const type = reinterpret_cast<const char *>(cursor + 4);
        const size_t total = size_t(length) + 12;
        if (cursor + total > end)
            break;
        bool colorChunk = false;
        for (const char *known : kColorChunks)
          colorChunk = colorChunk || memcmp(type, known, 4) == 0;
        if (!colorChunk)
            stripped.append(reinterpret_cast<const char *>(cursor),
                            int(total));
        cursor += total;
        if (memcmp(type, "IEND", 4) == 0)
            break;
    }
    return stripped == png ? png : stripped;
  }
}

#endif // __APPLE__
