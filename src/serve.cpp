/** @fileoverview Serve mode: a resident hotkey server that launches
 *  capture subprocesses when the global combos are pressed. */
#include "serve.hpp"

#ifdef __APPLE__

#include <QApplication>
#include <QCoreApplication>
#include <QDebug>
#include <QProcess>

extern "C" {
bool omasnap_install_hotkeys(void (*callback)(void *ctx, const char *mode),
                             void *ctx);
void omasnap_uninstall_hotkeys();
const char *omasnap_hotkey_description(int index);
}

namespace {

/** Mode names in hotkey-registration order (region, window, fullscreen). */
constexpr const char *kServeModes[3] = {"region", "window", "fullscreen"};

void spawnCapture(void *ctx, const char *mode) {
  static_cast<void>(ctx);
  if (!QProcess::startDetached(QCoreApplication::applicationFilePath(),
                                {QStringLiteral("--capture-") +
                                 QString::fromUtf8(mode)}))
    qWarning("omasnap serve: could not start %s capture", mode);
}

} // namespace

int runServeMode() {
  if (!omasnap_install_hotkeys(&spawnCapture, nullptr)) {
    qCritical("omasnap: could not register global capture hotkeys");
    return 1;
  }
  qInfo().noquote() << QStringLiteral("omasnap serve: hotkeys registered:");
  for (int i = 0; i < 3; ++i) {
    const char *combo = omasnap_hotkey_description(i);
    if (combo && *combo)
      qInfo().noquote() << QStringLiteral("  %1 -> %2 capture")
                            .arg(QString::fromUtf8(combo),
                                 QString::fromLatin1(kServeModes[i]));
  }
  qInfo().noquote() << QStringLiteral(
      "remap via OMASNAP_HOTKEY_REGION/_WINDOW/_FULLSCREEN "
      "(e.g. cmd+shift+9)");
  const int exitCode = QApplication::exec();
  omasnap_uninstall_hotkeys();
  return exitCode;
}

#endif // __APPLE__
