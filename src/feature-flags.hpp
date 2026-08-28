/** @fileoverview Runtime feature flags resolved from OMASNAP_FEATURE_FLAGS. */
#pragma once

#include <QString>
#include <QStringList>

namespace omasnap {

enum class FeatureFlag {
  OcrScanSweep,
  DesktopNotifications,
};

/** Canonical, documented flag names accepted in OMASNAP_FEATURE_FLAGS. */
[[nodiscard]] QStringList featureFlagNames();

/** True unless the flag was explicitly disabled in the environment. */
[[nodiscard]] bool featureEnabled(FeatureFlag flag);

/** Test hook: clears the cache so the next query re-reads the environment. */
void resetFeatureFlagsForTest();

} // namespace omasnap
