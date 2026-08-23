/** @fileoverview macOS clipboard backend: NSPasteboard image reads/writes. */
#include "capture-platform.hpp"

#ifdef __APPLE__

#include <QClipboard>
#include <QGuiApplication>
#include <QImage>
#include <QMimeData>
#include <QVariant>

#import <AppKit/AppKit.h>
#import <CoreServices/CoreServices.h>

namespace {

/** Shared MIME preference order as UTI strings; mirrors capture-platform.hpp. */
NSArray<NSString *> *preferredImageTypes() {
  return @[
    @"public.png",
    @"public.jpeg",
    @"public.webp",
    @"org.webmproject.webp", // legacy WebP UTI some apps still publish
    @"com.microsoft.bmp",
    @"public.bmp"
  ];
}

/** Decodes `data`; returns a null QImage when the bytes are not an image. */
QImage decodePasteboardData(NSData *data) {
  if (!data.length)
    return {};
  return QImage::fromData(reinterpret_cast<const uchar *>(data.bytes),
                          static_cast<qsizetype>(data.length));
}

} // namespace

bool loadClipboardImageImpl(QImage &image, QString &error) {
  image = QImage();
  @autoreleasepool {
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    NSArray<NSString *> *offered = [pasteboard types];
    if (!offered)
      offered = @[];

    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    for (NSString *type in preferredImageTypes())
      if ([offered containsObject:type])
        [candidates addObject:type];
    for (NSString *type in offered) {
      if ([candidates containsObject:type])
        continue;
      // Cmd+Shift+Ctrl+4 screenshots land here via public.tiff.
      // Legacy CoreServices API keeps UniformTypeIdentifiers unlinked.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
      if (UTTypeConformsTo((__bridge CFStringRef)type, CFSTR("public.image")))
#pragma clang diagnostic pop
        [candidates addObject:type];
    }

    bool receivedImageData = false;
    for (NSString *type in candidates) {
      NSData *data = [pasteboard dataForType:type];
      if (!data)
        continue;
      receivedImageData = true;
      const QImage decoded = decodePasteboardData(data);
      if (!decoded.isNull()) {
        image = decoded;
        return true;
      }
    }

    // Final fallback: let Qt resolve whatever image flavor it understands.
    if (!receivedImageData && QGuiApplication::instance()) {
      const QMimeData *mime = QGuiApplication::clipboard()->mimeData();
      const QVariant imageData = mime ? mime->imageData() : QVariant();
      if (imageData.isValid()) {
        receivedImageData = true;
        QImage decoded;
        if (imageData.canConvert<QImage>())
          decoded = qvariant_cast<QImage>(imageData);
        else if (imageData.canConvert<QByteArray>())
          decoded = QImage::fromData(qvariant_cast<QByteArray>(imageData));
        if (!decoded.isNull()) {
          image = decoded;
          return true;
        }
      }
    }

    if ([candidates count] == 0 && !receivedImageData) {
      error = QStringLiteral("Clipboard does not contain an image");
      return false;
    }
    if (!receivedImageData) {
      error = QStringLiteral("Could not read clipboard image");
      return false;
    }
    error = QStringLiteral("Clipboard image could not be decoded");
    return false;
  }
}

bool copyPngToClipboardImpl(const QByteArray &png, QString &error) {
  @autoreleasepool {
    NSData *pngData =
        [NSData dataWithBytes:png.constData()
                       length:static_cast<NSUInteger>(png.size())];
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithData:pngData];
    NSData *tiffData = [rep TIFFRepresentation];

    NSMutableArray<NSString *> *types =
        [NSMutableArray arrayWithObject:NSPasteboardTypePNG];
    if (tiffData)
      [types addObject:NSPasteboardTypeTIFF];

    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    // declareTypes + eager setData keeps the bytes alive after process exit.
    if (![pasteboard declareTypes:types owner:nil]) {
      error = QStringLiteral(
          "Could not persist clipboard: pasteboard declaration failed");
      return false;
    }
    BOOL written = [pasteboard setData:pngData forType:NSPasteboardTypePNG];
    if (written && tiffData)
      written = [pasteboard setData:tiffData forType:NSPasteboardTypeTIFF];
    if (!written) {
      error = QStringLiteral(
          "Could not persist clipboard: pasteboard write failed");
      return false;
    }
    return true;
  }
}

bool copyTextToClipboardImpl(const QString &text, QString &error) {
  @autoreleasepool {
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    NSString *payload =
        [[NSString alloc] initWithCharacters:reinterpret_cast<const unichar *>(
                                                 text.utf16())
                                      length:static_cast<NSUInteger>(
                                                 text.size())];
    [pasteboard clearContents];
    if (![pasteboard setString:payload forType:NSPasteboardTypeString]) {
      error = QStringLiteral(
          "Could not persist clipboard: pasteboard write failed");
      return false;
    }
    return true;
  }
}

#endif // __APPLE__
