/** @fileoverview Hyprland/Wayland implementations of the capture backends. */
#include "capture.hpp"

#ifndef Q_OS_MACOS

#include "capture-platform.hpp"

#include <QBuffer>
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QProcess>
#include <QStringList>
#include <QUrl>

#include <algorithm>

namespace {
struct ProcessResult {
  QByteArray output;
  QByteArray error;
  int exitCode = -1;
  bool finished = false;
};

ProcessResult runProcess(const QString &program, const QStringList &arguments,
                         const QByteArray &input = {}, int timeoutMs = 10000) {
  QProcess process;
  process.setProcessChannelMode(QProcess::SeparateChannels);
  process.start(program, arguments);
  if (!process.waitForStarted(2000))
    return {{}, process.errorString().toUtf8(), -1, false};

  if (!input.isEmpty())
    process.write(input);
  process.closeWriteChannel();
  const bool finished = process.waitForFinished(timeoutMs);
  if (!finished)
    process.kill();
  return {process.readAllStandardOutput(), process.readAllStandardError(),
          finished ? process.exitCode() : -1, finished};
}

bool copyToWaylandClipboard(const QString &mimeType, const QByteArray &payload,
                            QString &error) {
  QByteArray lastError;
  for (int attempt = 0; attempt < 2; ++attempt) {
    const ProcessResult copied =
        runProcess(QStringLiteral("wl-copy"),
                   {QStringLiteral("--type"), mimeType}, payload, 5000);
    if (!copied.finished || copied.exitCode != 0) {
      lastError = copied.error;
      continue;
    }

    const ProcessResult verified = runProcess(
        QStringLiteral("wl-paste"),
        {QStringLiteral("--no-newline"), QStringLiteral("--type"), mimeType},
        {}, 5000);
    if (verified.finished && verified.exitCode == 0 &&
        verified.output == payload)
      return true;
    lastError = verified.error;
    if (lastError.isEmpty())
      lastError = QByteArrayLiteral("clipboard verification did not match");
  }
  error = QStringLiteral("Could not persist clipboard: %1")
              .arg(QString::fromUtf8(lastError).trimmed());
  return false;
}

bool parseMonitor(const QByteArray &json, MonitorInfo &monitor,
                  QString &error) {
  QJsonParseError parseError;
  const QJsonDocument document = QJsonDocument::fromJson(json, &parseError);
  if (parseError.error != QJsonParseError::NoError || !document.isArray()) {
    error = QStringLiteral("Could not parse Hyprland monitors: %1")
                .arg(parseError.errorString());
    return false;
  }

  for (const QJsonValue value : document.array()) {
    const QJsonObject object = value.toObject();
    if (!object.value(QStringLiteral("focused")).toBool())
      continue;

    const qreal scale = object.value(QStringLiteral("scale")).toDouble(1.0);
    const int rawWidth = object.value(QStringLiteral("width")).toInt();
    const int rawHeight = object.value(QStringLiteral("height")).toInt();
    const int transform = object.value(QStringLiteral("transform")).toInt();
    int logicalWidth = qRound(rawWidth / std::max<qreal>(scale, 0.01));
    int logicalHeight = qRound(rawHeight / std::max<qreal>(scale, 0.01));
    if (transform == 1 || transform == 3 || transform == 5 || transform == 7)
      std::swap(logicalWidth, logicalHeight);

    monitor.name = object.value(QStringLiteral("name")).toString();
    monitor.geometry = {object.value(QStringLiteral("x")).toInt(),
                        object.value(QStringLiteral("y")).toInt(), logicalWidth,
                        logicalHeight};
    monitor.pixelSize = {rawWidth, rawHeight};
    monitor.scale = scale;
    monitor.workspaceId = object.value(QStringLiteral("activeWorkspace"))
                              .toObject()
                              .value(QStringLiteral("id"))
                              .toInt();
    return !monitor.name.isEmpty() && logicalWidth > 0 && logicalHeight > 0;
  }

  error = QStringLiteral("Hyprland did not report a focused monitor");
  return false;
}

QVector<WindowTarget> parseWindows(const QByteArray &json,
                                   const MonitorInfo &monitor) {
  QVector<WindowTarget> result;
  const QJsonDocument document = QJsonDocument::fromJson(json);
  if (!document.isArray())
    return result;

  for (const QJsonValue value : document.array()) {
    const QJsonObject object = value.toObject();
    if (object.value(QStringLiteral("workspace"))
            .toObject()
            .value(QStringLiteral("id"))
            .toInt() != monitor.workspaceId)
      continue;

    const QJsonArray at = object.value(QStringLiteral("at")).toArray();
    const QJsonArray size = object.value(QStringLiteral("size")).toArray();
    if (at.size() < 2 || size.size() < 2)
      continue;

    QRect rect(at.at(0).toInt() - monitor.geometry.x(),
               at.at(1).toInt() - monitor.geometry.y(), size.at(0).toInt(),
               size.at(1).toInt());
    rect = rect.intersected(QRect(QPoint(), monitor.geometry.size()));
    if (rect.isEmpty())
      continue;

    QString title = object.value(QStringLiteral("title")).toString();
    if (title.isEmpty())
      title = object.value(QStringLiteral("class"))
                  .toString(QStringLiteral("window"));
    result.push_back({rect, object.value(QStringLiteral("stableId")).toString(),
                      std::move(title)});
  }
  return result;
}
} // namespace

bool probeFocusedMonitorImpl(MonitorInfo &monitor, QString &error) {
  const ProcessResult monitors =
      runProcess(QStringLiteral("hyprctl"),
                 {QStringLiteral("monitors"), QStringLiteral("-j")});
  if (!monitors.finished || monitors.exitCode != 0 ||
      !parseMonitor(monitors.output, monitor, error)) {
    if (error.isEmpty())
      error = QString::fromUtf8(monitors.error).trimmed();
    return false;
  }
  return true;
}

void *beginWindowDiscoveryImpl() {
  auto *clients = new QProcess();
  clients->setProcessChannelMode(QProcess::SeparateChannels);
  clients->start(QStringLiteral("hyprctl"),
                 {QStringLiteral("clients"), QStringLiteral("-j")});
  clients->closeWriteChannel();
  return clients;
}

QVector<WindowTarget> finishWindowDiscoveryImpl(void *handle,
                                                const MonitorInfo &monitor) {
  QVector<WindowTarget> windows;
  if (!handle)
    return windows;
  auto *clients = static_cast<QProcess *>(handle);
  if (!clients->waitForFinished(10000))
    clients->kill();
  else if (clients->exitCode() == 0)
    windows = parseWindows(clients->readAllStandardOutput(), monitor);
  delete clients;
  return windows;
}

void cancelWindowDiscoveryImpl(void *handle) {
  if (!handle)
    return;
  auto *clients = static_cast<QProcess *>(handle);
  clients->kill();
  delete clients;
}

bool grabMonitorPixelsImpl(const MonitorInfo &monitor, QImage &image,
                           QString &error) {
  return captureOutputSurface(monitor, image, error);
}

bool loadClipboardImageImpl(QImage &image, QString &error) {
  const ProcessResult listed =
      runProcess(QStringLiteral("wl-paste"), {QStringLiteral("--list-types")},
                 {}, 5000);
  if (!listed.finished || listed.exitCode != 0) {
    const QString detail = QString::fromUtf8(listed.error).trimmed();
    error = detail.isEmpty()
                ? QStringLiteral("Could not read the Wayland clipboard")
                : QStringLiteral("Could not read the Wayland clipboard: %1")
                      .arg(detail);
    return false;
  }

  const QStringList offered =
      QString::fromUtf8(listed.output)
          .split('\n', Qt::SkipEmptyParts, Qt::CaseSensitive);
  QStringList imageTypes;
  const QStringList preferred{QStringLiteral("image/png"),
                              QStringLiteral("image/jpeg"),
                              QStringLiteral("image/webp"),
                              QStringLiteral("image/bmp")};
  for (const QString &mimeType : preferred) {
    if (offered.contains(mimeType))
      imageTypes.append(mimeType);
  }
  for (const QString &mimeType : offered) {
    const QString trimmed = mimeType.trimmed();
    if (trimmed.startsWith(QStringLiteral("image/")) &&
        !imageTypes.contains(trimmed))
      imageTypes.append(trimmed);
  }
  if (imageTypes.isEmpty()) {
    error = QStringLiteral("Clipboard does not contain an image");
    return false;
  }

  bool receivedImageData = false;
  QString readError;
  for (const QString &mimeType : imageTypes) {
    const ProcessResult pasted = runProcess(
        QStringLiteral("wl-paste"),
        {QStringLiteral("--no-newline"), QStringLiteral("--type"), mimeType},
        {}, 5000);
    if (!pasted.finished || pasted.exitCode != 0) {
      const QString detail = QString::fromUtf8(pasted.error).trimmed();
      if (!detail.isEmpty())
        readError = detail;
      continue;
    }
    receivedImageData = true;
    image = QImage::fromData(pasted.output);
    if (!image.isNull())
      return true;
  }

  if (!receivedImageData) {
    error = readError.isEmpty()
                ? QStringLiteral("Could not read clipboard image")
                : QStringLiteral("Could not read clipboard image: %1")
                      .arg(readError);
    return false;
  }
  error = QStringLiteral("Clipboard image could not be decoded");
  return false;
}

bool copyPngToClipboardImpl(const QByteArray &png, QString &error) {
  return copyToWaylandClipboard(QStringLiteral("image/png"), png, error);
}

bool copyTextToClipboardImpl(const QString &text, QString &error) {
  return copyToWaylandClipboard(QStringLiteral("text/plain;charset=utf-8"),
                                text.toUtf8(), error);
}

QString recognizeTextImpl(const QImage &image, QString &error) {
  QByteArray payload;
  QBuffer buffer(&payload);
  if (!buffer.open(QIODevice::WriteOnly) || !image.save(&buffer, "PNG")) {
    error = QStringLiteral("Could not prepare image for OCR");
    return {};
  }

  QString languages = qEnvironmentVariable("OMASNAP_OCR_LANGS");
  if (languages.isEmpty())
    languages =
        qEnvironmentVariable("OMARCHY_OCR_LANGS", QStringLiteral("eng"));
  languages = languages.trimmed();
  const ProcessResult result = runProcess(
      QStringLiteral("tesseract"),
      {QStringLiteral("stdin"), QStringLiteral("stdout"),
       QStringLiteral("--oem"), QStringLiteral("1"),
       QStringLiteral("--psm"), QStringLiteral("6"),
       QStringLiteral("-l"), languages,
       QStringLiteral("--dpi"), QStringLiteral("300"),
       QStringLiteral("-c"), QStringLiteral("preserve_interword_spaces=1")},
      payload, 30000);
  if (!result.finished || result.exitCode != 0) {
    error = QStringLiteral("OCR failed for languages %1: %2")
                .arg(languages, QString::fromUtf8(result.error).trimmed());
    return {};
  }
  const QString text = QString::fromUtf8(result.output).trimmed();
  if (text.isEmpty())
    error = QStringLiteral("No text found in selection");
  return text;
}

void sendCaptureNotificationImpl(const QString &message,
                                 const QString &imagePath) {
  QStringList arguments{QStringLiteral("-g"), QStringLiteral(""),
                        QStringLiteral("--app-name"), QStringLiteral("omasnap"),
                        message};
  if (!imagePath.isEmpty()) {
    const QString imageUrl =
        QUrl::fromLocalFile(imagePath).toString(QUrl::FullyEncoded);
    QString omasnap = QDir(QCoreApplication::applicationDirPath())
                          .filePath(QStringLiteral("omasnap"));
    if (!QFileInfo::exists(omasnap))
      omasnap = QStringLiteral("omasnap");
    arguments << QStringLiteral("Click to edit") << QStringLiteral("--image")
              << imagePath << QStringLiteral("--exec")
              << QStringLiteral("%1 %2").arg(shellQuote(omasnap),
                                             shellQuote(imageUrl));
  }
  arguments << QStringLiteral("-t") << QStringLiteral("4500");
  QProcess::startDetached(QStringLiteral("omarchy-notification-send"),
                          arguments);
}

#endif // !Q_OS_MACOS
