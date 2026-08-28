/** @fileoverview Installs a best-effort crash reporter. See the header. */
#include "crash-reporter.hpp"

#include "telemetry.hpp"

#include <QDir>
#include <QString>

#include <csignal>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <execinfo.h>
#include <fcntl.h>
#include <unistd.h>

namespace omasnap {
namespace {

char g_crashLogPath[512] = "";

constexpr int kCrashFrames = 64;

extern "C" void handleCrashSignal(int signalNumber) {
  if (g_crashLogPath[0] != '\0') {
    if (const int fd =
            ::open(g_crashLogPath, O_CREAT | O_WRONLY | O_TRUNC, 0600);
        fd >= 0) {
      // Raw epoch, not ctime(): formatting helpers with static buffers are
      // not reentrant, and this runs in signal context (CodeQL flags it).
      const std::time_t now = std::time(nullptr);
      char header[640];
      const int headerLength =
          std::snprintf(header, sizeof(header),
                        "omasnap crash\nsignal=%d\ntime_epoch=%lld\n"
                        "trace=%s\n",
                        signalNumber, static_cast<long long>(now),
                        traceId().toLatin1().constData());
      if (headerLength > 0)
        static_cast<void>(
            ::write(fd, header, static_cast<size_t>(headerLength)));
      static_cast<void>(::write(fd, "\nrecent activity:\n", 18));
      char breadcrumbs[4096];
      snapshotBreadcrumbsForCrash(breadcrumbs,
                                  static_cast<int>(sizeof(breadcrumbs)));
      static_cast<void>(::write(fd, breadcrumbs, std::strlen(breadcrumbs)));
      static_cast<void>(::write(fd, "\nbacktrace:\n", 12));
      void* frames[kCrashFrames];
      const int frameCount = ::backtrace(frames, kCrashFrames);
      if (frameCount > 0)
        ::backtrace_symbols_fd(frames, frameCount, fd);
      static_cast<void>(::close(fd));
    }
  }
  ::signal(signalNumber, SIG_DFL);
  ::raise(signalNumber);
}

} // namespace

void installCrashReporter(const QString& runtimeDirectory) {
  if (runtimeDirectory.isEmpty())
    return;
  const QByteArray path =
      QDir(runtimeDirectory)
          .filePath(QStringLiteral("crash-") + QString::number(::getpid()) +
                    QStringLiteral(".log"))
          .toLocal8Bit();
  std::snprintf(g_crashLogPath, sizeof(g_crashLogPath), "%s", path.constData());
  for (const int signalNumber : {SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE})
    ::signal(signalNumber, handleCrashSignal);
}

} // namespace omasnap
