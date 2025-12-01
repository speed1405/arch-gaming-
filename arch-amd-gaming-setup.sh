#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -Eeuo pipefail

# Minimal Arch Linux installer tuned for AMD gaming systems.
# Inspired by the official archinstall flow but implemented as a standalone script.

PACMAN_FLAGS=(--noconfirm --needed)
TARGET_DISK=""
BOOT_MODE="uefi"
EFI_PART=""
ROOT_PART=""
BIOS_BOOT_PART=""
TARGET_HOSTNAME="arch-gaming"
TARGET_USERNAME="gamer"
TARGET_TIMEZONE="UTC"
TARGET_LOCALE="en_US.UTF-8"
TARGET_VCONSOLE_KEYMAP="us"
TARGET_MOUNT="/mnt"
USER_PASSWORD=""
ROOT_PASSWORD=""
DESKTOP_CHOICE="gnome"
AUR_HELPER="paru"

log() { printf '[+] %s\n' "$1"; }
warn() { printf '[!] %s\n' "$1" >&2; }
err() { printf '[x] %s\n' "$1" >&2; exit 1; }

require_cmd() {
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      err "Missing required command: $cmd"
    fi
  done
}

prompt() {
  local prompt_text="$1"
  local default_value="${2:-}"
  local value
  if [[ -n "$default_value" ]]; then
    read -r -p "$prompt_text [$default_value]: " value
    value="${value:-$default_value}"
  else
    read -r -p "$prompt_text: " value
  fi
  printf '%s' "$value"
}

prompt_hidden() {
  local prompt_text="$1"
  local first second
  while true; do
    read -r -s -p "$prompt_text: " first
    printf '\n'
    read -r -s -p "Confirm $prompt_text: " second
    printf '\n'
    if [[ "$first" == "$second" && -n "$first" ]]; then
      printf '%s' "$first"
      return
    fi
    warn "Passwords did not match or were empty. Try again."
  done
}

prompt_yes_no() {
  local prompt_text="$1"
  local default_answer="${2:-y}"
  local choice
  while true; do
    read -r -p "$prompt_text [${default_answer^^}/$( [[ $default_answer == y ]] && echo "n" || echo "Y" )]: " choice
    choice="${choice:-$default_answer}"
    case "${choice,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
    esac
    echo "Please answer yes or no."
  done
}

check_environment() {
  if [[ $EUID -ne 0 ]]; then
    err "Run this installer as root."
  fi
  require_cmd pacstrap arch-chroot lsblk sgdisk mkfs.ext4 mkfs.fat findmnt openssl
  if ! mountpoint -q "$TARGET_MOUNT"; then
    mkdir -p "$TARGET_MOUNT"
  fi
}

select_boot_mode() {
  if [[ -d /sys/firmware/efi ]]; then
    BOOT_MODE="uefi"
  else
    BOOT_MODE="bios"
  fi
  log "Detected boot mode: $BOOT_MODE"
  if prompt_yes_no "Override detected boot mode?" "n"; then
    local choice
    while true; do
      read -r -p "Enter boot mode (uefi/bios): " choice
      case "${choice,,}" in
        uefi|bios)
          BOOT_MODE="${choice,,}"
          break
          ;;
        *) echo "Invalid entry." ;;
      esac
    done
  fi
  log "Using boot mode: $BOOT_MODE"
}

select_target_disk() {
  log "Available disks:"
  lsblk -dpno NAME,SIZE,MODEL | nl -ba
  local choice
  while true; do
    read -r -p "Enter disk device path (e.g., /dev/sda, /dev/nvme0n1): " choice
    if [[ -b "$choice" ]]; then
      TARGET_DISK="$choice"
      break
    fi
    warn "Invalid block device."
  done
  log "Selected disk: $TARGET_DISK"
  if ! prompt_yes_no "This will erase ALL data on $TARGET_DISK. Continue?" "n"; then
    err "Installation cancelled."
  fi
}

partition_disk() {
  log "Partitioning $TARGET_DISK"
  sgdisk --zap-all "$TARGET_DISK"
  local suffix=""
  if [[ $TARGET_DISK == *"nvme"* || $TARGET_DISK == *"mmcblk"* ]]; then
    suffix="p"
  fi
  if [[ $BOOT_MODE == "uefi" ]]; then
    sgdisk -n 1:0:+512M -t 1:ef00 "$TARGET_DISK"
    sgdisk -n 2:0:0 -t 2:8300 "$TARGET_DISK"
    EFI_PART="${TARGET_DISK}${suffix}1"
    ROOT_PART="${TARGET_DISK}${suffix}2"
    BIOS_BOOT_PART=""
  else
    sgdisk -a1 -n 1:24K:+1M -t 1:ef02 "$TARGET_DISK"
    sgdisk -n 2:0:0 -t 2:8300 "$TARGET_DISK"
    BIOS_BOOT_PART="${TARGET_DISK}${suffix}1"
    ROOT_PART="${TARGET_DISK}${suffix}2"
    EFI_PART=""
  fi
  log "EFI partition: ${EFI_PART:-N/A}"
  log "Root partition: $ROOT_PART"
}

format_partitions() {
  unmount_existing_mounts "$ROOT_PART" "$EFI_PART"
  if [[ -n "$EFI_PART" ]]; then
    mkfs.fat -F32 "$EFI_PART"
  fi
  mkfs.ext4 -F "$ROOT_PART"
}

unmount_existing_mounts() {
  local part
  for part in "$@"; do
    [[ -z "$part" ]] && continue
    while read -r mount_point; do
      [[ -z "$mount_point" ]] && continue
      log "Unmounting existing mount on $mount_point (backed by $part)"
      umount -R "$mount_point"
    done < <(findmnt -rn -S "$part" -o TARGET || true)
  done
}

mount_partitions() {
  unmount_existing_mounts "$ROOT_PART" "$EFI_PART"
  if mountpoint -q "$TARGET_MOUNT" 2>/dev/null; then
    umount -R "$TARGET_MOUNT"
  fi
  mkdir -p "$TARGET_MOUNT"
  if mountpoint -q "$TARGET_MOUNT/boot" 2>/dev/null; then
    umount "$TARGET_MOUNT/boot"
  fi
  mount "$ROOT_PART" "$TARGET_MOUNT"
  mkdir -p "$TARGET_MOUNT/boot"
  if [[ -n "$EFI_PART" ]]; then
    mount "$EFI_PART" "$TARGET_MOUNT/boot"
  fi
}

install_base_system() {
  log "Installing base packages"
  pacstrap "$TARGET_MOUNT" base linux linux-firmware linux-headers networkmanager sudo base-devel vim zstd cargo
  genfstab -U "$TARGET_MOUNT" >> "$TARGET_MOUNT/etc/fstab"
  log "Generated fstab"
}

run_in_chroot() {
  arch-chroot "$TARGET_MOUNT" bash -c "$1"
}

set_password_in_chroot() {
  local user="$1"
  local password="$2"
  local hash
  hash=$(openssl passwd -6 "$password")
  local escaped_hash
  escaped_hash=$(printf '%q' "$hash")
  local escaped_user
  escaped_user=$(printf '%q' "$user")
  run_in_chroot "usermod -p $escaped_hash $escaped_user"
}

configure_locale_timezone() {
  TARGET_TIMEZONE=$(prompt "Timezone (Region/City)" "$TARGET_TIMEZONE")
  TARGET_LOCALE=$(prompt "Locale" "$TARGET_LOCALE")
  run_in_chroot "ln -sf /usr/share/zoneinfo/$TARGET_TIMEZONE /etc/localtime"
  run_in_chroot "hwclock --systohc"
  run_in_chroot "sed -i 's/^#\(${TARGET_LOCALE//\//\/} UTF-8\)/\1/' /etc/locale.gen"
  run_in_chroot "locale-gen"
  printf 'LANG=%s\n' "$TARGET_LOCALE" > "$TARGET_MOUNT/etc/locale.conf"
}

configure_vconsole() {
  TARGET_VCONSOLE_KEYMAP=$(prompt "Console keymap" "$TARGET_VCONSOLE_KEYMAP")
  printf 'KEYMAP=%s\n' "$TARGET_VCONSOLE_KEYMAP" > "$TARGET_MOUNT/etc/vconsole.conf"
}

configure_network() {
  TARGET_HOSTNAME=$(prompt "Hostname" "$TARGET_HOSTNAME")
  printf '%s\n' "$TARGET_HOSTNAME" > "$TARGET_MOUNT/etc/hostname"
  cat <<EOF > "$TARGET_MOUNT/etc/hosts"
127.0.0.1 localhost
::1       localhost
127.0.1.1 $TARGET_HOSTNAME.localdomain $TARGET_HOSTNAME
EOF
  run_in_chroot "systemctl enable NetworkManager"
}

create_users() {
  ROOT_PASSWORD=$(prompt_hidden "Root password")
  set_password_in_chroot root "$ROOT_PASSWORD"
  TARGET_USERNAME=$(prompt "Primary username" "$TARGET_USERNAME")
  run_in_chroot "useradd -m -G wheel,audio,video,storage $TARGET_USERNAME"
  USER_PASSWORD=$(prompt_hidden "Password for $TARGET_USERNAME")
  set_password_in_chroot "$TARGET_USERNAME" "$USER_PASSWORD"
  run_in_chroot "usermod -aG wheel $TARGET_USERNAME"
  run_in_chroot "sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers"
}

enable_multilib() {
  run_in_chroot "sed -i 's/^#\s*\[multilib\]/[multilib]/' /etc/pacman.conf"
  run_in_chroot "sed -i '/^[[:space:]]*\\[multilib\\]/,/^[[:space:]]*\\[/{/^[[:space:]]*Include[[:space:]]*=/{d}}' /etc/pacman.conf"
  run_in_chroot "sed -i '/^[[:space:]]*\\[multilib\\]/a Include = /etc/pacman.d/mirrorlist' /etc/pacman.conf"
  run_in_chroot "pacman -Sy"
}

install_amd_stack() {
  local packages=(amd-ucode mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon vulkan-mesa-layers lib32-vulkan-mesa-layers libva-mesa-driver lib32-libva-mesa-driver vulkan-tools xf86-video-amdgpu)
  run_in_chroot "pacman -S ${PACMAN_FLAGS[*]} ${packages[*]}"
}

install_kernel_options() {
  if prompt_yes_no "Install the linux-zen kernel in addition to the default kernel?" "y"; then
    run_in_chroot "pacman -S ${PACMAN_FLAGS[*]} linux-zen linux-zen-headers"
  fi

  if prompt_yes_no "Install the linux-cachyos kernel from AUR?" "n"; then
    install_linux_cachyos
  fi
}

install_linux_cachyos() {
  log "Building linux-cachyos kernel from AUR (this may take a while)..."
  run_in_chroot "pacman -S ${PACMAN_FLAGS[*]} git"
  run_in_chroot "su - $TARGET_USERNAME -c 'git clone https://aur.archlinux.org/linux-cachyos.git ~/linux-cachyos'"
  run_in_chroot "su - $TARGET_USERNAME -c 'cd ~/linux-cachyos && makepkg -si --noconfirm'"
  run_in_chroot "su - $TARGET_USERNAME -c 'rm -rf ~/linux-cachyos'"
}

select_desktop_environment() {
  echo "Desktop options:"
  echo "  1) GNOME"
  echo "  2) KDE Plasma"
  echo "  3) Xfce"
  echo "  4) Cinnamon"
  echo "  5) Skip"
  local choice
  while true; do
    read -r -p "Select desktop [1-5]: " choice
    case "$choice" in
      1) DESKTOP_CHOICE="gnome"; break ;;
      2) DESKTOP_CHOICE="plasma"; break ;;
      3) DESKTOP_CHOICE="xfce"; break ;;
      4) DESKTOP_CHOICE="cinnamon"; break ;;
      5) DESKTOP_CHOICE="none"; break ;;
      *) echo "Invalid selection." ;;
    esac
  done
}

install_desktop_environment() {
  case "$DESKTOP_CHOICE" in
    gnome)
      run_in_chroot "pacman -S ${PACMAN_FLAGS[*]} gnome gnome-tweaks gdm"
      run_in_chroot "systemctl enable gdm"
      ;;
    plasma)
      run_in_chroot "pacman -S ${PACMAN_FLAGS[*]} plasma-meta kde-applications sddm"
      run_in_chroot "systemctl enable sddm"
      ;;
    xfce)
      run_in_chroot "pacman -S ${PACMAN_FLAGS[*]} xfce4 xfce4-goodies lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings"
      run_in_chroot "systemctl enable lightdm"
      ;;
    cinnamon)
      run_in_chroot "pacman -S ${PACMAN_FLAGS[*]} cinnamon lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings"
      run_in_chroot "systemctl enable lightdm"
      ;;
    none)
      warn "Skipping desktop installation."
      ;;
  esac
}

install_gaming_stack() {
  local packages=(steam lutris wine winetricks gamemode lib32-gamemode mangohud lib32-mangohud pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber flatpak)
  run_in_chroot "pacman -S ${PACMAN_FLAGS[*]} ${packages[*]}"
  run_in_chroot "systemctl enable --global gamemoded.service >/dev/null 2>&1 || true"
  run_in_chroot "flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo"
}

install_aur_helper() {
  if ! prompt_yes_no "Install AUR helper ($AUR_HELPER) and ProtonUp-Qt?" "y"; then
    return
  fi
  run_in_chroot "pacman -S ${PACMAN_FLAGS[*]} git"
  run_in_chroot 'bash -c "echo \"%wheel ALL=(ALL:ALL) NOPASSWD: ALL\" > /etc/sudoers.d/00-aur-installer"'
  run_in_chroot "chmod 440 /etc/sudoers.d/00-aur-installer"
  run_in_chroot "su - $TARGET_USERNAME -c 'git clone https://aur.archlinux.org/${AUR_HELPER}.git ~/aur-helper'"
  run_in_chroot "su - $TARGET_USERNAME -c 'cd ~/aur-helper && makepkg -si --noconfirm'"
  run_in_chroot "su - $TARGET_USERNAME -c 'rm -rf ~/aur-helper'"
  run_in_chroot "su - $TARGET_USERNAME -c '$AUR_HELPER -S --noconfirm protonup-qt heroic-games-launcher-bin'"
  run_in_chroot "rm -f /etc/sudoers.d/00-aur-installer"
}

install_bootloader() {
  if [[ $BOOT_MODE == "uefi" ]]; then
    run_in_chroot "pacman -S ${PACMAN_FLAGS[*]} grub efibootmgr"
    run_in_chroot "grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB"
  else
    run_in_chroot "pacman -S ${PACMAN_FLAGS[*]} grub"
    run_in_chroot "grub-install --target=i386-pc $TARGET_DISK"
  fi
  run_in_chroot "grub-mkconfig -o /boot/grub/grub.cfg"
}

cleanup() {
  log "Unmounting target"
  umount -R "$TARGET_MOUNT"
}

main() {
  check_environment
  select_boot_mode
  select_target_disk
  partition_disk
  format_partitions
  mount_partitions
  install_base_system
  configure_locale_timezone
  configure_vconsole
  configure_network
  create_users
  enable_multilib
  install_kernel_options
  install_amd_stack
  install_gaming_stack
  select_desktop_environment
  install_desktop_environment
  install_aur_helper
  install_bootloader
  cleanup
  log "Installation complete. Reboot into your new system."
}

main "$@"

