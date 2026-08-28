/** @fileoverview Trace ids, scrubbed logging, lightweight metrics, and
 *  opt-in local usage events. Pure Qt: no GUI objects, safe on any thread.
 */
#include "telemetry.hpp"

#include "capture.hpp"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QHash>
#include <QMutex>
#include <QMutexLocker>
#include <QRandomGenerator>
#include <QRegularExpression>
#include <QSaveFile>
#include <QtGlobal>

#include <cstdio>
#include <cstring>

namespace omasnap {
namespace {

constexpr int kBreadcrumbCount = 16;
constexpr int kBreadcrumbText = 176;

struct Breadcrumb {
  qint64 msecs = 0;
  char text[kBreadcrumbText] = "";
};

QMutex& telemetryMutex() {
  static QMutex mutex;
  return mutex;
}

QString& traceIdStorage() {
  static QString id;
  return id;
}

QString generateTraceId() {
  return QString::number(QRandomGenerator::global()->generate64(), 16)
      .rightJustified(12, QLatin1Char('0'))
      .left(12);
}

void renderCrashBreadcrumbBuffer(const Breadcrumb* ring, int next, char* buffer,
                                 int capacity) {
  int written = 0;
  buffer[0] = '\0';
  for (int i = 0; i < kBreadcrumbCount && written < capacity - 1; ++i) {
    const Breadcrumb& entry = ring[(next + i) % kBreadcrumbCount];
    if (entry.text[0] == '\0')
      continue;
    const int remaining = capacity - written - 1;
    const int line = std::snprintf(
        buffer + written, static_cast<size_t>(remaining), "%lld %s\n",
        static_cast<long long>(entry.msecs), entry.text);
    if (line <= 0 || line >= remaining)
      break;
    written += line;
  }
}

/** The signal-readable breadcrumb snapshot; rebuilt on every append. */
char g_crashBreadcrumbs[kBreadcrumbCount * (kBreadcrumbText + 32)] = "";

Breadcrumb g_breadcrumbs[kBreadcrumbCount] = {};
int g_breadcrumbNext = 0;

struct MetricValue {
  qint64 count = 0;
  qint64 totalMs = 0;
};

QHash<QString, MetricValue>& metricsStorage() {
  static QHash<QString, MetricValue> metrics;
  return metrics;
}

bool analyticsEnabled() {
  const QString enabled = qEnvironmentVariable("OMASNAP_ANALYTICS");
  return enabled == QStringLiteral("1") ||
         enabled.compare(QStringLiteral("true"), Qt::CaseInsensitive) == 0 ||
         !qEnvironmentVariableIsEmpty("OMASNAP_ANALYTICS_FILE");
}

QString analyticsPath() {
  const QString overridePath = qEnvironmentVariable("OMASNAP_ANALYTICS_FILE");
  if (!overridePath.isEmpty())
    return overridePath;
  if (!analyticsEnabled())
    return QString();
  const QString runtime = secureRuntimeDirectory();
  if (runtime.isEmpty())
    return QString();
  return QDir(runtime).filePath(QStringLiteral("analytics.jsonl"));
}

QString escapeJson(const QString& value) {
  QString escaped = value;
  escaped.replace(QLatin1Char('\\'), QStringLiteral("\\\\"));
  escaped.replace(QLatin1Char('"'), QStringLiteral("\\\""));
  escaped.replace(QLatin1Char('\n'), QStringLiteral("\\n"));
  escaped.replace(QLatin1Char('\r'), QStringLiteral(""));
  return escaped;
}

void appendBreadcrumbLocked(const QString& message) {
  const QString scrubbed = scrubLogMessage(message);
  const QByteArray bytes = scrubbed.toUtf8();
  Breadcrumb& entry = g_breadcrumbs[g_breadcrumbNext % kBreadcrumbCount];
  entry.msecs = QDateTime::currentMSecsSinceEpoch();
  std::strncpy(entry.text, bytes.constData(), kBreadcrumbText - 1);
  entry.text[kBreadcrumbText - 1] = '\0';
  g_breadcrumbNext = (g_breadcrumbNext + 1) % kBreadcrumbCount;
  renderCrashBreadcrumbBuffer(g_breadcrumbs, g_breadcrumbNext,
                              g_crashBreadcrumbs,
                              static_cast<int>(sizeof(g_crashBreadcrumbs)));
}

QtMessageHandler previousMessageHandler = nullptr;

void telemetryMessageHandler(QtMsgType type, const QMessageLogContext& context,
                             const QString& message) {
  {
    const QMutexLocker locker(&telemetryMutex());
    appendBreadcrumbLocked(message);
  }
  if (previousMessageHandler != nullptr)
    previousMessageHandler(type, context, scrubLogMessage(message));
}

} // namespace

QString traceId() {
  const QMutexLocker locker(&telemetryMutex());
  if (traceIdStorage().isEmpty())
    traceIdStorage() = generateTraceId();
  return traceIdStorage();
}

void adoptTraceIdFromEnvironment() {
  const QString inherited = qEnvironmentVariable("OMASNAP_TRACE_ID");
  const QMutexLocker locker(&telemetryMutex());
  if (!inherited.isEmpty() && inherited.size() <= 32) {
    traceIdStorage() = inherited;
  } else if (traceIdStorage().isEmpty()) {
    traceIdStorage() = generateTraceId();
  }
  qputenv("OMASNAP_TRACE_ID", traceIdStorage().toLatin1());
}

QString scrubLogMessage(const QString& message) {
  static const QRegularExpression bearer(
      QStringLiteral("bearer\\s+[^\\s,;]+"),
      QRegularExpression::CaseInsensitiveOption);
  static const QRegularExpression credentials(
      QStringLiteral(
          "\\b(token|secret|password|passwd|api[-_]?key|authorization)"
          "\\b\\s*[=:]\\s*[^\\s,;]+"),
      QRegularExpression::CaseInsensitiveOption);
  QString scrubbed = message;
  scrubbed.replace(bearer, QStringLiteral("bearer [redacted]"));
  scrubbed.replace(credentials, QStringLiteral("\\1=[redacted]"));
  return scrubbed;
}

void installTelemetryMessageHandler() {
  static bool installed = false;
  if (installed)
    return;
  installed = true;
  previousMessageHandler = qInstallMessageHandler(telemetryMessageHandler);
}

void recordMetricSample(const QString& name, qint64 milliseconds) {
  const QMutexLocker locker(&telemetryMutex());
  MetricValue& value = metricsStorage()[name];
  value.count += 1;
  value.totalMs += milliseconds;
}

void incrementMetric(const QString& name) {
  const QMutexLocker locker(&telemetryMutex());
  MetricValue& value = metricsStorage()[name];
  value.count += 1;
}

QString metricsSummary() {
  const QMutexLocker locker(&telemetryMutex());
  QStringList names = metricsStorage().keys();
  names.sort();
  QStringList lines;
  for (const QString& name : names) {
    const MetricValue& value = metricsStorage().value(name);
    const qint64 average = value.count == 0 ? 0 : value.totalMs / value.count;
    lines << QStringLiteral("%1 count=%2 total_ms=%3 avg_ms=%4")
                 .arg(name)
                 .arg(value.count)
                 .arg(value.totalMs)
                 .arg(average);
  }
  return lines.join(QLatin1Char('\n'));
}

bool writeMetricsJson(const QString& path) {
  const QMutexLocker locker(&telemetryMutex());
  QStringList names = metricsStorage().keys();
  names.sort();
  QStringList entries;
  for (const QString& name : names) {
    const MetricValue& value = metricsStorage().value(name);
    const qint64 average = value.count == 0 ? 0 : value.totalMs / value.count;
    entries
        << QStringLiteral(
               "{\"name\":\"%1\",\"count\":%2,\"total_ms\":%3,\"avg_ms\":%4}")
               .arg(escapeJson(name))
               .arg(value.count)
               .arg(value.totalMs)
               .arg(average);
  }
  QSaveFile file(path);
  if (!file.open(QIODevice::WriteOnly | QIODevice::Text))
    return false;
  const QByteArray payload =
      QStringLiteral("{\"trace\":\"%1\",\"metrics\":[%2]}")
          .arg(escapeJson(traceIdStorage()), entries.join(QLatin1Char(',')))
          .toUtf8();
  file.write(payload);
  file.write("\n");
  return file.commit();
}

QString analyticsFilePath() {
  const QMutexLocker locker(&telemetryMutex());
  return analyticsPath();
}

void recordAnalyticsEvent(const QString& event, const QString& detail) {
  const QMutexLocker locker(&telemetryMutex());
  const QString path = analyticsPath();
  if (path.isEmpty())
    return;
  QFile file(path);
  if (!file.open(QIODevice::Append | QIODevice::Text))
    return;
  const QString line =
      QStringLiteral(
          "{\"t\":%1,\"trace\":\"%2\",\"event\":\"%3\",\"detail\":\"%4\"}")
          .arg(QDateTime::currentMSecsSinceEpoch())
          .arg(escapeJson(traceIdStorage()))
          .arg(escapeJson(event))
          .arg(escapeJson(detail));
  file.write(line.toUtf8());
  file.write("\n");
}

void appendBreadcrumb(const QString& message) {
  const QMutexLocker locker(&telemetryMutex());
  appendBreadcrumbLocked(message);
}

void snapshotBreadcrumbsForCrash(char* buffer, int capacity) {
  if (buffer == nullptr || capacity <= 0)
    return;
  const int size = static_cast<int>(sizeof(g_crashBreadcrumbs));
  const int copied = capacity - 1 < size ? capacity - 1 : size;
  std::memcpy(buffer, g_crashBreadcrumbs, static_cast<size_t>(copied));
  buffer[copied] = '\0';
}

} // namespace omasnap
