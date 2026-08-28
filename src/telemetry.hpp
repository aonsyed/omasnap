/** @fileoverview Trace ids, scrubbed logging, lightweight performance
 *  metrics, and opt-in local usage events.
 *
 * Every omasnap process carries a trace id (inherited through
 * OMASNAP_TRACE_ID by pins and hotkey-spawned captures) so one capture can be
 * followed across processes in logs, crash reports, and analytics events.
 * The message handler scrubs credential-shaped substrings before anything is
 * written, and keeps a small breadcrumb ring that the crash reporter dumps.
 */
#pragma once

#include <QString>

namespace omasnap {

/** The per-session trace id, inherited or generated (12 hex characters). */
[[nodiscard]] QString traceId();

/** Adopts OMASNAP_TRACE_ID or generates a fresh id, and exports the value so
 *  detached child processes (pins, hotkey captures) share it. */
void adoptTraceIdFromEnvironment();

/** Masks credential-shaped `key=value` and bearer tokens in `message`. */
[[nodiscard]] QString scrubLogMessage(const QString& message);

/** Installs the scrubbing/breadcrumb Qt message handler. */
void installTelemetryMessageHandler();

/** Records one duration sample (milliseconds) under `name`. */
void recordMetricSample(const QString& name, qint64 milliseconds);

/** Counts one occurrence of `name`. */
void incrementMetric(const QString& name);

/** Human-readable, sorted "name count=<n> total_ms=<t> avg_ms=<a>" lines. */
[[nodiscard]] QString metricsSummary();

/** Writes the metrics as a JSON object to `path`; false on I/O failure. */
[[nodiscard]] bool writeMetricsJson(const QString& path);

/** Appends a local, opt-in usage event (OMASNAP_ANALYTICS=1). No-op unless
 *  analytics is enabled in the environment. */
void recordAnalyticsEvent(const QString& event, const QString& detail = {});

/** The analytics event log path, or empty when analytics is disabled. */
[[nodiscard]] QString analyticsFilePath();

/** Adds a scrubbed breadcrumb to the crash-report ring buffer. */
void appendBreadcrumb(const QString& message);

/** Copies the pre-rendered breadcrumb ring into `buffer`; signal-safe. */
void snapshotBreadcrumbsForCrash(char* buffer, int capacity);

} // namespace omasnap
