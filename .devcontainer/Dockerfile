# Pinned Arch toolchain matching CI (see docs/dependency-policy.md):
# bump the date tag deliberately, not silently.
FROM archlinux@sha256:68bfc3b0d277b08a99101dc9b94aaa03e5ae70cf1b4fb965c03b2b87b915760d

RUN pacman -Syu --noconfirm --needed \
      base-devel cmake ninja pkgconf git clang \
      qt6-base layer-shell-qt wayland wayland-protocols \
      wl-clipboard tesseract tesseract-data-eng \
    && pacman -Scc --noconfirm

ENV QT_QPA_PLATFORM=offscreen
