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

#include <limits>
#include <optional>

namespace {

constexpr int kMaxOnlineDisplays = 16;
constexpr int64_t kCaptureTimeoutNs = 5LL * NSEC_PER_SEC;

QRect toQRect(const CGRect &rect) {
  return QRect(qRound(rect.origin.x), qRound(rect.origin.y),
               qRound(rect.size.width), qRound(rect.size.height));
}

/** Renders a CGImage into an upright ARGB32_Premultiplied image. */
bool cgImageToQImage(CGImageRef cgImage, QImage &image) {
  const size_t width = CGImageGetWidth(cgImage);
  const size_t height = CGImageGetHeight(cgImage);
  if (width == 0 || height == 0 ||
      width > size_t(std::numeric_limits<int>::max()) ||
      height > size_t(std::numeric_limits<int>::max()))
    return false;

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
    dispatch_semaphore_t done = dispatch_semaphore_create(0);

    __block SCShareableContent *content = nil;
    [SCShareableContent
        getShareableContentExcludingDesktopWindows:NO
                               onScreenWindowsOnly:YES
                                 completionHandler:^(
                                     SCShareableContent *result,
                                     NSError *shareError) {
                                   // The result only lives for SCK's internal
                                   // autorelease pool; keep it across the
                                   // handoff to this thread.
                                   content = [result retain];
                                   static_cast<void>(shareError);
                                   dispatch_semaphore_signal(done);
                                 }];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
                                                    kCaptureTimeoutNs)) != 0) {
      error = QStringLiteral("Screen capture timed out");
      [content release];
      return false;
    }
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
      [content release];
      return false;
    }
    [filter release];
    [configuration release];
    [content release];
    content = nil;
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

void *beginWindowDiscoveryImpl() { return nullptr; }

QVector<WindowTarget> finishWindowDiscoveryImpl(void *handle,
                                                const MonitorInfo &monitor) {
  static_cast<void>(handle);
  QVector<WindowTarget> targets;
  @autoreleasepool {
    CFArrayRef windowList = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    if (!windowList)
      return targets;

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

void cancelWindowDiscoveryImpl(void *handle) { static_cast<void>(handle); }

#endif // __APPLE__
