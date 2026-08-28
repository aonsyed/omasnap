# Pinned Arch toolchain matching CI (see docs/dependency-policy.md):
# bump the date tag deliberately, not silently.
FROM archlinux:base-devel-20260828.0.581697

RUN pacman -Syu --noconfirm --needed \
      base-devel cmake ninja pkgconf git clang \
      qt6-base layer-shell-qt wayland wayland-protocols \
      wl-clipboard tesseract tesseract-data-eng \
    && pacman -Scc --noconfirm

ENV QT_QPA_PLATFORM=offscreen
