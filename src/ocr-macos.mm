/** @fileoverview macOS OCR backend: synchronous Vision-framework text
 *  recognition mirroring the Linux tesseract behavior. */
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <Vision/Vision.h>

asm(".linker_option \"-framework\"\n"
    ".linker_option \"Vision\"\n");

#include "capture-platform.hpp"

#ifdef __APPLE__

#include <QHash>
#include <QList>
#include <QRectF>
#include <QStringList>
#include <algorithm>

static QString visionLanguage(const QString &codeRaw) {
  static const QHash<QString, QString> table{
      {QStringLiteral("eng"), QStringLiteral("en-US")},
      {QStringLiteral("deu"), QStringLiteral("de-DE")},
      {QStringLiteral("fra"), QStringLiteral("fr-FR")},
      {QStringLiteral("spa"), QStringLiteral("es-ES")},
      {QStringLiteral("ita"), QStringLiteral("it-IT")},
      {QStringLiteral("por"), QStringLiteral("pt-BR")},
      {QStringLiteral("rus"), QStringLiteral("ru-RU")},
      {QStringLiteral("jpn"), QStringLiteral("ja-JP")},
      {QStringLiteral("kor"), QStringLiteral("ko-KR")},
      {QStringLiteral("chi_sim"), QStringLiteral("zh-Hans")},
      {QStringLiteral("chi_tra"), QStringLiteral("zh-Hant")},
      {QStringLiteral("ara"), QStringLiteral("ar-SA")},
      {QStringLiteral("hin"), QStringLiteral("hi-IN")},
      {QStringLiteral("nld"), QStringLiteral("nl-NL")},
      {QStringLiteral("pol"), QStringLiteral("pl-PL")},
      {QStringLiteral("swe"), QStringLiteral("sv-SE")},
      {QStringLiteral("dan"), QStringLiteral("da-DK")},
      {QStringLiteral("nor"), QStringLiteral("nb-NO")},
      {QStringLiteral("fin"), QStringLiteral("fi-FI")},
      {QStringLiteral("tur"), QStringLiteral("tr-TR")},
      {QStringLiteral("vie"), QStringLiteral("vi-VN")},
      {QStringLiteral("tha"), QStringLiteral("th-TH")},
      {QStringLiteral("heb"), QStringLiteral("he-IL")},
      {QStringLiteral("ces"), QStringLiteral("cs-CZ")},
      {QStringLiteral("ell"), QStringLiteral("el-GR")},
      {QStringLiteral("ron"), QStringLiteral("ro-RO")},
      {QStringLiteral("hun"), QStringLiteral("hu-HU")},
      {QStringLiteral("en"), QStringLiteral("en-US")},
      {QStringLiteral("de"), QStringLiteral("de-DE")},
      {QStringLiteral("fr"), QStringLiteral("fr-FR")},
      {QStringLiteral("es"), QStringLiteral("es-ES")},
      {QStringLiteral("it"), QStringLiteral("it-IT")},
      {QStringLiteral("pt"), QStringLiteral("pt-BR")},
      {QStringLiteral("ru"), QStringLiteral("ru-RU")},
      {QStringLiteral("zh"), QStringLiteral("zh-Hans")},
      {QStringLiteral("ja"), QStringLiteral("ja-JP")},
      {QStringLiteral("ko"), QStringLiteral("ko-KR")}};
  const QString code = codeRaw.trimmed().toLower();
  const auto match = table.constFind(code);
  if (match != table.constEnd())
    return *match;
  if (code.size() == 2)
    return code + QStringLiteral("-US");
  return codeRaw.trimmed();
}

QString recognizeTextImpl(const QImage &image, QString &error) {
  if (image.isNull() || image.width() <= 0 || image.height() <= 0) {
    error = QStringLiteral("Could not prepare image for OCR");
    return {};
  }

  QString languages = qEnvironmentVariable("OMASNAP_OCR_LANGS");
  if (languages.isEmpty())
    languages =
        qEnvironmentVariable("OMARCHY_OCR_LANGS", QStringLiteral("eng"));
  languages = languages.trimmed();
  const QStringList codes = QString(languages)
                                .replace(QLatin1Char(','), QLatin1Char(' '))
                                .split(QLatin1Char(' '), Qt::SkipEmptyParts);
  NSMutableArray<NSString *> *languageArray =
      [NSMutableArray arrayWithCapacity:codes.size()];
  for (const QString &code : codes)
    [languageArray addObject:visionLanguage(code).toNSString()];
  if (languageArray.count == 0)
    [languageArray addObject:@"en-US"];

  QImage converted =
      image.convertToFormat(QImage::Format_ARGB32_Premultiplied);
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  CGContextRef bitmapContext = CGBitmapContextCreate(
      converted.bits(), converted.width(), converted.height(), 8,
      converted.bytesPerLine(), colorSpace,
      static_cast<uint32_t>(kCGImageAlphaPremultipliedFirst) |
          kCGBitmapByteOrder32Little);
  CGColorSpaceRelease(colorSpace);
  if (!bitmapContext) {
    error = QStringLiteral("Could not prepare image for OCR");
    return {};
  }
  CGImageRef cgImage = CGBitmapContextCreateImage(bitmapContext);
  CGContextRelease(bitmapContext);
  if (!cgImage) {
    error = QStringLiteral("Could not prepare image for OCR");
    return {};
  }

  @autoreleasepool {
    VNRecognizeTextRequest *request =
        [[VNRecognizeTextRequest alloc] initWithCompletionHandler:nil];
    request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    request.usesLanguageCorrection = NO;
    request.recognitionLanguages = languageArray;
    if (@available(macOS 13.0, *))
      request.automaticallyDetectsLanguage = YES;

    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc]
        initWithCGImage:cgImage
                options:@{}];
    NSError *requestError = nil;
    const BOOL performed =
        [handler performRequests:@[ request ] error:&requestError];
    [handler release];

    if (!performed) {
      const QString detail =
          requestError
              ? QString::fromNSString(requestError.localizedDescription)
              : QStringLiteral("unknown Vision error");
      error = QStringLiteral("OCR failed for languages %1: %2")
                  .arg(languages, detail);
      [request release];
      CGImageRelease(cgImage);
      return {};
    }

    struct Piece {
      QRectF box;
      QString text;
    };
    QList<Piece> pieces;
    for (VNObservation *observation in request.results) {
      if (![observation isKindOfClass:[VNRecognizedTextObservation class]])
        continue;
      VNRecognizedTextObservation *textObservation =
          (VNRecognizedTextObservation *)observation;
      VNRecognizedText *candidate =
          [textObservation topCandidates:1].firstObject;
      if (!candidate)
        continue;
      const QString text = QString::fromNSString(candidate.string);
      if (text.trimmed().isEmpty())
        continue;
      const CGRect box = textObservation.boundingBox;
      pieces.append(
          {QRectF(box.origin.x, box.origin.y, box.size.width, box.size.height),
           text});
    }
    [request release];
    CGImageRelease(cgImage);

    std::sort(pieces.begin(), pieces.end(),
              [](const Piece &a, const Piece &b) {
                return a.box.center().y() > b.box.center().y();
              });
    QStringList lines;
    qsizetype index = 0;
    while (index < pieces.size()) {
      qsizetype end = index + 1;
      while (end < pieces.size()) {
        const double gap =
            pieces[index].box.center().y() - pieces[end].box.center().y();
        const double limit =
            0.3 * (pieces[index].box.height() + pieces[end].box.height());
        if (gap > limit)
          break;
        ++end;
      }
      std::sort(pieces.begin() + index, pieces.begin() + end,
                [](const Piece &a, const Piece &b) {
                  return a.box.left() < b.box.left();
                });
      for (qsizetype row = index; row < end; ++row)
        lines.append(pieces[row].text.trimmed());
      index = end;
    }

    const QString text = lines.join(QLatin1Char('\n')).trimmed();
    if (text.isEmpty())
      error = QStringLiteral("No text found in selection");
    return text;
  }
}

#endif // __APPLE__
