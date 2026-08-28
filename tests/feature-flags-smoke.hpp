/** @fileoverview Declares feature flag smoke checks. */
#pragma once

class QString;

[[nodiscard]] bool runFeatureFlagsSmoke(QString& error);
