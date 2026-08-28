---
name: release
description: Cut an omasnap release - version bump, both-platform verification, tag, omarchy-pkgs PR
---

# Release

Follow AGENTS.md "Release process" exactly:

1. Bump `project(omasnap VERSION ...)` in `CMakeLists.txt` to the next
   version.
2. Verify both platforms:
   - Linux: `make check` on Arch (the devcontainer provides it).
   - macOS: the cmake/ninja/ctest commands from AGENTS.md "Build and verify".
3. Commit as `chore(release): v<version>`, tag `v<version>`, push main and
   the tag. The workflow attaches both artifacts and generates release notes.
4. Verify per docs/runbooks.md "Release verification": green run, both
   artifacts present, `omasnap --version` correct.
5. Open the omarchy-pkgs PR: set `pkgver`, refresh the `sha256sums`
   (`curl -sL <tarball-url> | sha256sum`), commit on a branch, PR to
   omacom-io/omarchy-pkgs.
6. Close the loop: link the release and the pkgbuild PR in the tracking
   issue if one exists.
