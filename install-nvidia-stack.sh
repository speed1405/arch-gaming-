#!/usr/bin/env bash

set -Eeuo pipefail

log() { printf '[nvidia] %s\n' "$1"; }
warn() { printf '[nvidia:warn] %s\n' "$1" >&2; }

if [[ -n ${PACMAN_FLAGS:-} ]]; then
  read -ra PAC_FLAGS <<< "$PACMAN_FLAGS"
else
  PAC_FLAGS=(--noconfirm --needed)
fi

log "Installing core NVIDIA driver packages."
pacman -S "${PAC_FLAGS[@]}" dkms nvidia nvidia-dkms nvidia-utils lib32-nvidia-utils nvidia-settings nvidia-prime opencl-nvidia egl-wayland

if pacman -Si lib32-opencl-nvidia >/dev/null 2>&1; then
  log "Installing optional 32-bit OpenCL runtime."
  pacman -S "${PAC_FLAGS[@]}" lib32-opencl-nvidia || warn "Failed to install lib32-opencl-nvidia"
fi

log "Blacklisting nouveau to avoid driver conflicts."
cat <<'EOF' >/etc/modprobe.d/blacklist-nouveau.conf
blacklist nouveau
options nouveau modeset=0
EOF

if command -v systemctl >/dev/null 2>&1; then
  log "Enabling nvidia-persistenced service."
  systemctl enable nvidia-persistenced.service || warn "Unable to enable nvidia-persistenced"
fi

if command -v mkinitcpio >/dev/null 2>&1; then
  log "Regenerating initramfs for installed kernels."
  mkinitcpio -P || warn "mkinitcpio -P exited with an error"
fi

log "NVIDIA driver setup complete."
