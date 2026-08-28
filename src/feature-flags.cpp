/** @fileoverview Runtime feature flags resolved from OMASNAP_FEATURE_FLAGS.
 *
 * Flags default to enabled. `OMASNAP_FEATURE_FLAGS` accepts a comma-separated
 * list of `name=0`, `name=1`, `!name`, or bare `name` entries, so behavior can
 * be toggled per invocation without a rebuild or a settings surface. Unknown
 * names are ignored, exactly like unknown environment variables.
 */
#include "feature-flags.hpp"

#include <QHash>
#include <QMutex>
#include <QMutexLocker>
#include <QRegularExpression>

namespace omasnap {
namespace {

QString flagName(FeatureFlag flag) {
  switch (flag) {
  case FeatureFlag::OcrScanSweep:
    return QStringLiteral("ocr_scan_sweep");
  case FeatureFlag::DesktopNotifications:
    return QStringLiteral("desktop_notifications");
  }
  return QString();
}

QHash<QString, bool> parseEnvironment() {
  QHash<QString, bool> state;
  state.insert(flagName(FeatureFlag::OcrScanSweep), true);
  state.insert(flagName(FeatureFlag::DesktopNotifications), true);
  static const QRegularExpression separator(QStringLiteral("\\s*,\\s*"));
  const QStringList overrides = qEnvironmentVariable("OMASNAP_FEATURE_FLAGS")
                                    .split(separator, Qt::SkipEmptyParts);
  for (QString override : overrides) {
    const bool bareEnable = !override.startsWith(QLatin1Char('!'));
    if (!bareEnable)
      override.remove(0, 1);
    static const QRegularExpression assignment(QStringLiteral("\\s*=\\s*"));
    const QStringList parts = override.split(assignment);
    const QString& name = parts.constFirst();
    if (!state.contains(name))
      continue;
    const bool value = parts.size() > 1
                           ? parts.at(1) != QLatin1Char('0') &&
                                 parts.at(1).compare(QStringLiteral("false"),
                                                     Qt::CaseInsensitive) != 0
                           : bareEnable;
    state.insert(name, value);
  }
  return state;
}

QMutex& flagsMutex() {
  static QMutex mutex;
  return mutex;
}

QHash<QString, bool>& flagsCache() {
  static QHash<QString, bool> cache;
  return cache;
}

bool cachedEnabled(FeatureFlag flag) {
  const QMutexLocker locker(&flagsMutex());
  if (flagsCache().isEmpty())
    flagsCache() = parseEnvironment();
  return flagsCache().value(flagName(flag), true);
}

} // namespace

QStringList featureFlagNames() {
  const QMutexLocker locker(&flagsMutex());
  if (flagsCache().isEmpty())
    flagsCache() = parseEnvironment();
  QStringList names = flagsCache().keys();
  names.sort();
  return names;
}

bool featureEnabled(FeatureFlag flag) {
  return cachedEnabled(flag);
}

void resetFeatureFlagsForTest() {
  const QMutexLocker locker(&flagsMutex());
  flagsCache().clear();
}

} // namespace omasnap
