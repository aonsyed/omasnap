---
name: ci-triage
description: Triage a failed omasnap CI run using the alert issue and reproduce locally
---

# CI triage

Start from the alert issue (label `ci`) or the failed run URL, then follow
docs/runbooks.md "CI failure triage":

1. Identify the workflow: `build` (build+smoke), `quality` (guards, format,
   complexity, duplication, docs), `coverage`, `codeql`, `pr-review`.
2. Reproduce locally:
   - guards and format: `make guards`, `make format-check`
   - build+smoke: `make check` (Arch/devcontainer)
   - coverage: the lcov commands in `.github/workflows/coverage.yml`
3. Fix, push, confirm the rerun is green, close the alert issue with a link
   to the fixing commit.

If the failure is an Arch image issue (keyring/mirror), bump the pinned tag
in all workflows and `.devcontainer/Dockerfile` per docs/dependency-policy.md.
