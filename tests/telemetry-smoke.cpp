/** @fileoverview Exercises scrubbing, trace ids, metrics, analytics events,
 *  and the crash breadcrumb snapshot. */
#include "telemetry-smoke.hpp"

#include "telemetry.hpp"

#include <QDir>
#include <QFile>
#include <QString>
#include <QTemporaryDir>
#include <QtGlobal>

#include <cstring>

bool runTelemetrySmoke(QString& error) {
  using namespace omasnap;

  const QString dirty = QStringLiteral(
      "upload token=abc123 password:hunter2 Authorization: Bearer "
      "eyJhbGciOi.9876 trailing");
  const QString clean = scrubLogMessage(dirty);
  if (clean.contains(QStringLiteral("abc123")) ||
      clean.contains(QStringLiteral("hunter2")) ||
      clean.contains(QStringLiteral("eyJhbGciOi.9876"))) {
    error = QStringLiteral("Scrubbing left credential values intact: %1")
                .arg(clean);
    return false;
  }

  qunsetenv("OMASNAP_TRACE_ID");
  adoptTraceIdFromEnvironment();
  const QString generated = traceId();
  if (generated.size() != 12 ||
      qEnvironmentVariable("OMASNAP_TRACE_ID") != generated) {
    error = QStringLiteral("Generated trace id must be 12 chars and exported "
                           "for child processes");
    return false;
  }

  qputenv("OMASNAP_TRACE_ID", "trace-from-parent");
  adoptTraceIdFromEnvironment();
  if (traceId() != QStringLiteral("trace-from-parent")) {
    error = QStringLiteral("Inherited trace id was not adopted");
    return false;
  }
  // The session id is sticky: it was already generated for this process, so
  // unsetting the environment must not mint a second id mid-session.
  qunsetenv("OMASNAP_TRACE_ID");
  adoptTraceIdFromEnvironment();
  if (traceId() != QStringLiteral("trace-from-parent") ||
      qEnvironmentVariable("OMASNAP_TRACE_ID") !=
          QStringLiteral("trace-from-parent")) {
    error = QStringLiteral("Trace id must stay stable within a session");
    return false;
  }

  recordMetricSample(QStringLiteral("smoke_ms"), 10);
  recordMetricSample(QStringLiteral("smoke_ms"), 30);
  incrementMetric(QStringLiteral("smoke_count"));
  const QString summary = metricsSummary();
  if (!summary.contains(QStringLiteral("smoke_ms count=2 total_ms=40")) ||
      !summary.contains(QStringLiteral("smoke_count count=1"))) {
    error = QStringLiteral("Metrics summary wrong:\n%1").arg(summary);
    return false;
  }

  QTemporaryDir directory;
  const QString metricsPath =
      QDir(directory.path()).filePath(QStringLiteral("metrics.json"));
  QFile metricsFile(metricsPath);
  if (!writeMetricsJson(metricsPath) ||
      !metricsFile.open(QIODevice::ReadOnly)) {
    error = QStringLiteral("Metrics JSON was not written");
    return false;
  }
  const QString metricsJson = QString::fromUtf8(metricsFile.readAll());
  metricsFile.close();
  if (!metricsJson.contains(QStringLiteral("\"smoke_ms\"")) ||
      !metricsJson.contains(QStringLiteral("\"count\":2"))) {
    error = QStringLiteral("Metrics JSON missing samples: %1").arg(metricsJson);
    return false;
  }

  const QString analyticsPath =
      QDir(directory.path()).filePath(QStringLiteral("analytics.jsonl"));
  qputenv("OMASNAP_ANALYTICS_FILE", analyticsPath.toLocal8Bit());
  recordAnalyticsEvent(QStringLiteral("smoke_test"),
                       QStringLiteral("detail with \"quotes\""));
  qunsetenv("OMASNAP_ANALYTICS_FILE");
  qunsetenv("OMASNAP_ANALYTICS");
  if (!analyticsFilePath().isEmpty()) {
    error = QStringLiteral("Analytics must stay opt-in");
    return false;
  }
  QFile analyticsFile(analyticsPath);
  if (!analyticsFile.open(QIODevice::ReadOnly)) {
    error = QStringLiteral("Opt-in analytics event was not written");
    return false;
  }
  const QString analyticsLine = QString::fromUtf8(analyticsFile.readAll());
  analyticsFile.close();
  if (!analyticsLine.contains(QStringLiteral("\"event\":\"smoke_test\"")) ||
      analyticsLine.contains(QStringLiteral("\"event\":\"detail"))) {
    error = QStringLiteral("Analytics event malformed: %1").arg(analyticsLine);
    return false;
  }

  appendBreadcrumb(QStringLiteral("smoke breadcrumb token=secretvalue"));
  char buffer[4096];
  snapshotBreadcrumbsForCrash(buffer, static_cast<int>(sizeof(buffer)));
  if (std::strstr(buffer, "smoke breadcrumb") == nullptr) {
    error = QStringLiteral("Breadcrumb missing from crash snapshot");
    return false;
  }
  if (std::strstr(buffer, "secretvalue") != nullptr) {
    error = QStringLiteral("Breadcrumbs were not scrubbed");
    return false;
  }

  qunsetenv("OMASNAP_TRACE_ID");
  return true;
}
