/** @fileoverview Installs a best-effort crash reporter.
 *
 * On fatal signals the handler appends a `crash-<pid>.log` beside the working
 * snapshots: signal, timestamp, trace id, the breadcrumb ring, and a
 * backtrace. It then re-raises with the default disposition so the OS still
 * produces its own report. The handler only uses write-family calls on
 * pre-rendered buffers; everything else is best effort.
 */
#pragma once

class QString;

namespace omasnap {

/** Writes crash logs into `runtimeDirectory` (no-op when empty). */
void installCrashReporter(const QString& runtimeDirectory);

} // namespace omasnap
