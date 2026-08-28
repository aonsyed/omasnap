# Dependency policy

omasnap builds against system libraries (Qt 6.8+, Wayland, LayerShellQt,
tesseract) discovered through CMake `find_package`/pkg-config. There is no
vendored dependency tree to lock, so pinning happens at the boundaries we
control:

1. **CI images are pinned by date tag.** Workflows build on
   `archlinux:base-devel-<yyyymmdd.n.build>` and Homebrew GitHub runners.
   Bump the Arch tag in a deliberate PR (monthly is plenty) so dependency
   upgrades are reviewed like code changes, not absorbed silently.
   The tag appears in `.github/workflows/*.yml` and
   `.devcontainer/Dockerfile`.
2. **Minimum versions are declared in CMakeLists.txt**
   (`find_package(Qt6 6.8 ...)`). Raise minimums deliberately; never cap
   them.
3. **Updates wait 7 days.** `renovate.json` sets `minimumReleaseAge: 7 days`:
   no dependency update PR is raised until an upstream release is a week old,
   which filters retracted releases and hotfix churn. The same rule applies
   to manual bumps: if a release is younger than 7 days, wait.
4. **GitHub Actions versions** are updated by Dependabot
   (`.github/dependabot.yml`, weekly cadence) and follow the same 7-day rule
   when pinned manually.
