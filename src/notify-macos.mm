/** @fileoverview macOS notification backend: fire-and-forget osascript. */
#include "capture-platform.hpp"

#ifdef __APPLE__

#include <QProcess>
#include <QStringList>

void sendCaptureNotificationImpl(const QString &message,
                                 const QString &imagePath) {
  // Escape for an AppleScript string literal.
  QString escaped = message;
  escaped.replace(u'\\', QStringLiteral("\\\\"))
      .replace(u'"', QStringLiteral("\\\""));
  QString script =
      QStringLiteral("display notification \"%1\" with title \"omasnap\"")
          .arg(escaped);
  // osascript quoting is fragile; only pass paths that need no escaping.
  if (!imagePath.isEmpty() && !imagePath.contains(u'"') &&
      !imagePath.contains(u'\\'))
    script += QStringLiteral(" subtitle \"%1\"").arg(imagePath);

  // osascript avoids the UNUserNotificationCenter permission prompt; failure
  // is silently ignored like omarchy-notification-send on Linux.
  QProcess::startDetached(QStringLiteral("/usr/bin/osascript"),
                          {QStringLiteral("-e"), script});
}

#endif // __APPLE__
