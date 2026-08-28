/** @fileoverview Exercises the OMASNAP_FEATURE_FLAGS parser and registry. */
#include "feature-flags-smoke.hpp"

#include "feature-flags.hpp"

#include <QStringList>
#include <QtGlobal>

bool runFeatureFlagsSmoke(QString& error) {
  using namespace omasnap;

  qputenv("OMASNAP_FEATURE_FLAGS", "");
  resetFeatureFlagsForTest();
  if (!featureEnabled(FeatureFlag::OcrScanSweep) ||
      !featureEnabled(FeatureFlag::DesktopNotifications)) {
    error = QStringLiteral("Flags must default to enabled");
    return false;
  }

  qputenv("OMASNAP_FEATURE_FLAGS", "ocr_scan_sweep=0");
  resetFeatureFlagsForTest();
  if (featureEnabled(FeatureFlag::OcrScanSweep) ||
      !featureEnabled(FeatureFlag::DesktopNotifications)) {
    error = QStringLiteral("name=0 must disable exactly the named flag");
    return false;
  }

  qputenv("OMASNAP_FEATURE_FLAGS",
          "!desktop_notifications,unknown_flag=0,ocr_scan_sweep=false");
  resetFeatureFlagsForTest();
  if (featureEnabled(FeatureFlag::DesktopNotifications)) {
    error = QStringLiteral("!name must disable the flag");
    return false;
  }
  if (featureEnabled(FeatureFlag::OcrScanSweep)) {
    error = QStringLiteral("name=false must disable the flag");
    return false;
  }
  const QStringList names = featureFlagNames();
  if (!names.contains(QStringLiteral("ocr_scan_sweep")) ||
      names.contains(QStringLiteral("unknown_flag"))) {
    error = QStringLiteral("Flag registry leaked an unknown flag: %1")
                .arg(names.join(QLatin1Char(',')));
    return false;
  }

  qputenv("OMASNAP_FEATURE_FLAGS", "ocr_scan_sweep=1");
  resetFeatureFlagsForTest();
  if (!featureEnabled(FeatureFlag::OcrScanSweep)) {
    error = QStringLiteral("name=1 must enable the flag");
    return false;
  }

  qunsetenv("OMASNAP_FEATURE_FLAGS");
  resetFeatureFlagsForTest();
  return true;
}
