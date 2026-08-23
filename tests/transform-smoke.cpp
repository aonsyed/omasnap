/** @fileoverview Tests Wayland capture transforms and object cleanup. */
#include "transform-smoke.hpp"

#include "capture.hpp"

#if !defined(Q_OS_MACOS)
#include "surface-capture-smoke.hpp"
#endif

#include <QDir>
#include <QFile>
#include <QImage>
#include <QTemporaryDir>
#include <QVector>

namespace {
#if !defined(Q_OS_MACOS)
/** Writes an executable helper used to replace an external command. */
bool writeExecutable(const QString &path, const QByteArray &contents) {
  QFile file(path);
  if (!file.open(QIODevice::WriteOnly) ||
      file.write(contents) != contents.size())
    return false;
  file.close();
  return QFile::setPermissions(path, QFileDevice::ReadOwner |
                                         QFileDevice::WriteOwner |
                                         QFileDevice::ExeOwner);
}
#endif // !Q_OS_MACOS

/** Creates a small image whose red channel stores easy-to-check values. */
QImage indexedImage(const QVector<QVector<int>> &rows) {
  QImage image(rows.constFirst().size(), rows.size(), QImage::Format_RGB32);
  for (int y = 0; y < rows.size(); ++y) {
    for (int x = 0; x < rows.at(y).size(); ++x)
      image.setPixelColor(x, y, QColor(rows.at(y).at(x), 0, 0));
  }
  return image;
}

/** Checks every WL_OUTPUT_TRANSFORM_* variant against its upright form.
 *  The constants mirror wayland-client-protocol.h so this stays runnable on
 *  platforms without Wayland headers. */
bool checkNormalizeMatrix(QString &error) {
  constexpr std::uint32_t kTransformNormal = 0;
  constexpr std::uint32_t kTransform90 = 1;
  constexpr std::uint32_t kTransform180 = 2;
  constexpr std::uint32_t kTransform270 = 3;
  constexpr std::uint32_t kTransformFlipped = 4;
  constexpr std::uint32_t kTransformFlipped90 = 5;
  constexpr std::uint32_t kTransformFlipped180 = 6;
  constexpr std::uint32_t kTransformFlipped270 = 7;
  const QImage upright = indexedImage({{1, 2}, {3, 4}, {5, 6}});
  const QVector<QPair<std::uint32_t, QImage>> transformedImages{
      {kTransformNormal, upright},
      {kTransform90, indexedImage({{2, 4, 6}, {1, 3, 5}})},
      {kTransform180, indexedImage({{6, 5}, {4, 3}, {2, 1}})},
      {kTransform270, indexedImage({{5, 3, 1}, {6, 4, 2}})},
      {kTransformFlipped, indexedImage({{2, 1}, {4, 3}, {6, 5}})},
      {kTransformFlipped90, indexedImage({{1, 3, 5}, {2, 4, 6}})},
      {kTransformFlipped180, indexedImage({{5, 6}, {3, 4}, {1, 2}})},
      {kTransformFlipped270, indexedImage({{6, 4, 2}, {5, 3, 1}})},
  };
  for (const auto &[transform, transformed] : transformedImages) {
    if (normalizeWaylandCapture(transformed, transform) != upright) {
      error = QStringLiteral("Captured Wayland buffer was not upright");
      return false;
    }
  }
  return true;
}
} // namespace

bool runTransformSmoke(QString &error) {
#if !defined(Q_OS_MACOS)
  if (!runWaylandCleanupChecks()) {
    error =
        QStringLiteral("Wayland capture objects were not released in order");
    return false;
  }
  QTemporaryDir fakeCommands;
  if (!fakeCommands.isValid()) {
    error = QStringLiteral("Could not create transform-test directory");
    return false;
  }
  const QString fakeHyprctl =
      QDir(fakeCommands.path()).filePath(QStringLiteral("hyprctl"));
  const QByteArray hyprctlScript = QByteArrayLiteral(
      "#!/usr/bin/env bash\n"
      "set -euo pipefail\n"
      "if [[ \"${1:-}\" == \"monitors\" ]]; then\n"
      "  printf '[{\"focused\":true,\"scale\":1.0,\"width\":300,"
      "\"height\":200,\"transform\":%s,\"name\":\"TEST-ROTATED\","
      "\"x\":0,\"y\":0,\"activeWorkspace\":{\"id\":7}}]\\n' "
      "\"$OMASNAP_TEST_TRANSFORM\"\n"
      "else\n"
      "  printf '[{\"workspace\":{\"id\":7},\"at\":[0,0],\"size\":[100,100],"
      "\"title\":\"Test window\",\"stableId\":\"w1\"}]\\n'\n"
      "fi\n");
  if (!writeExecutable(fakeHyprctl, hyprctlScript)) {
    error = QStringLiteral("Could not create transform-test commands");
    return false;
  }
  QImage rotatedSource(300, 200, QImage::Format_RGB32);
  rotatedSource.fill(QColor(QStringLiteral("#123456")));
  const QString capturePath =
      QDir(fakeCommands.path()).filePath(QStringLiteral("source.png"));
  if (!rotatedSource.save(capturePath, "PNG")) {
    error = QStringLiteral("Could not create transform-test capture");
    return false;
  }

  const QByteArray originalPath = qgetenv("PATH");
  qputenv("PATH", fakeCommands.path().toUtf8() + ':' + originalPath);
  qputenv("OMASNAP_TEST_CAPTURE", capturePath.toUtf8());
  const auto restoreEnvironment = [&originalPath] {
    qputenv("PATH", originalPath);
    qunsetenv("OMASNAP_TEST_CAPTURE");
    qunsetenv("OMASNAP_TEST_TRANSFORM");
  };
  for (const int transform : {1, 3, 5, 7}) {
    qputenv("OMASNAP_TEST_TRANSFORM", QByteArray::number(transform));
    CaptureData rotatedCapture;
    if (!captureFocusedMonitor(rotatedCapture, true, error) ||
        rotatedCapture.monitor.geometry.size() != QSize(200, 300) ||
        rotatedCapture.previewSize != QSize(200, 300) ||
        rotatedCapture.windows.size() != 1) {
      if (error.isEmpty())
        error = QStringLiteral("Quarter-turn monitor geometry was not swapped");
      restoreEnvironment();
      return false;
    }
  }

  // Callers that never show the overlay skip window discovery entirely.
  qputenv("OMASNAP_TEST_TRANSFORM", QByteArrayLiteral("0"));
  CaptureData withoutWindows;
  if (!captureFocusedMonitor(withoutWindows, false, error) ||
      withoutWindows.source.size() != QSize(300, 200) ||
      withoutWindows.previewSize != QSize(300, 200) ||
      !withoutWindows.windows.isEmpty()) {
    if (error.isEmpty())
      error = QStringLiteral("Capture without window discovery was incorrect");
    restoreEnvironment();
    return false;
  }

  // Without a test capture, missing output-capture protocol must fail clearly.
  qunsetenv("OMASNAP_TEST_CAPTURE");
  CaptureData missingProtocol;
  QString protocolError;
  const bool captured =
      captureFocusedMonitor(missingProtocol, false, protocolError);
  if (captured || protocolError.isEmpty()) {
    error = QStringLiteral("Missing output capture did not report an error");
    restoreEnvironment();
    return false;
  }

  restoreEnvironment();
#endif // !Q_OS_MACOS

  return checkNormalizeMatrix(error);
}
