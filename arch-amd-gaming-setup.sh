#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -Eeuo pipefail

# Minimal Arch Linux installer tuned for AMD gaming systems.
# Inspired by the official archinstall flow but implemented as a standalone script.
#
# Quick Start Guide (also available in script):
# 1. Boot the Arch ISO, connect to the internet (`iwctl` for Wi-Fi or plug in Ethernet).
# 2. (Optional) `pacman -Sy dialog` to enable whiptail-based dialogs.
# 3. Copy or download this script to the live environment, then `chmod +x arch-amd-gaming-setup.sh`.
# 4. Run `./arch-amd-gaming-setup.sh` as root and follow the guided prompts or choose a curated profile.

PACMAN_FLAGS=(--noconfirm --needed)
TARGET_DISK=""
BOOT_MODE="uefi"
EFI_PART=""
ROOT_PART=""
BIOS_BOOT_PART=""
TARGET_HOSTNAME="arch-gaming"
TARGET_USERNAME="gamer"
TARGET_TIMEZONE="Australia/Sydney"
TARGET_LOCALE="en_US.UTF-8"
TARGET_VCONSOLE_KEYMAP="us"
TARGET_MOUNT="/mnt"
USER_PASSWORD=""
ROOT_PASSWORD=""
DESKTOP_CHOICE="gnome"
AUR_HELPER="paru"
UI_TITLE="Arch AMD Gaming Setup"
UI_BACKEND="text"
PROFILE_MODE="custom"
PROFILE_NAME="Guided setup"
PROFILE_DESCRIPTION="Manual walkthrough where you review every setting."
INSTALL_LINUX_ZEN="ask"
INSTALL_LINUX_CACHYOS="ask"
SKIP_DESKTOP_PROMPT=0
DETECTED_CPU="Unknown"
DETECTED_GPU="Unknown"
DETECTED_RAM_GB="Unknown"
DETECTED_NETWORK="Unknown"
HAS_NETWORK=0
EXTRA_PACKAGES=()
SELECTED_EXTRA_LABELS=()
PROFILE_PACKAGES=()
DETECTED_GPU_VENDOR="unknown"
DETECTED_TIMEZONE="Australia/Sydney"

log() { printf '[+] %s\n' "$1"; }
warn() { printf '[!] %s\n' "$1" >&2; }
err() { printf '[x] %s\n' "$1" >&2; exit 1; }

init_ui() {
  UI_BACKEND="text"
  if command -v whiptail >/dev/null 2>&1; then
    UI_BACKEND="whiptail"
  fi
}

show_help_section() {
  local help_text=$'Installer Help\n\nProfiles:\n  - Guided setup: manual prompts for every decision.\n  - Gaming desktop: GNOME + linux-zen tuned for dedicated rigs.\n  - Performance desktop: Plasma + linux-zen + CachyOS with Gamescope/VR extras.\n  - Lightweight laptop: Xfce with defaults geared for portability.\n\nKernel options:\n  - linux-zen: low-latency kernel that improves gaming responsiveness.\n  - linux-cachyos: AUR build with extra desktop optimisations (longer install).\n\nDesktops & window managers:\n  - GNOME / Plasma / Xfce / Cinnamon provide full-featured desktops.\n  - i3 / Sway offer lightweight tiling window managers.\n\nGraphics stack:\n  - AMD GPUs receive Mesa/Vulkan packages automatically.\n  - NVIDIA GPUs trigger a dedicated helper script for proprietary drivers.\n\nOptional extras:\n  - Streaming, emulation, creative, and system utility bundles can be toggled.\n\nDisks & partitioning:\n  - The selected disk is fully wiped and repartitioned.\n  - The pre-flight summary lets you review choices before changes occur.\n\nNavigation tips:\n  - Whiptail dialogs: arrow keys move, Tab switches buttons, Enter confirms.\n  - Text mode: type responses exactly as shown (yes/no, option names).'

  case "$UI_BACKEND" in
    whiptail)
      whiptail --title "$UI_TITLE" --msgbox "$help_text" 22 74
      ;;
    *)
      printf '%s\n\n' "$help_text"
      read -r -p "Press Enter to continue..." _
      ;;
  esac
}

show_quick_start_guide() {
  local guide=$'Quick Start Guide\n\n1. Connect to the internet (use `iwctl` for Wi-Fi or plug in Ethernet).\n2. Optionally run `pacman -Sy dialog` to enable guided whiptail dialogs.\n3. Copy or download this script to the live environment.\n4. Make it executable: `chmod +x arch-amd-gaming-setup.sh`.\n5. Launch it as root: `./arch-amd-gaming-setup.sh`.'
  case "$UI_BACKEND" in
    whiptail)
      whiptail --title "$UI_TITLE" --msgbox "$guide" 20 70
      ;;
    *)
      printf '%s\n' "$guide"
      ;;
  esac
}

prompt() {
  local prompt_text="$1"
  local default_value="${2:-}"
  local help_text="${3:-}"
  local value display
  case "$UI_BACKEND" in
    whiptail)
      display="$prompt_text"
      if [[ -n "$help_text" ]]; then
        display+=$'\n\n'"$help_text"
      fi
      value=$(whiptail --title "$UI_TITLE" --inputbox "$display" 10 60 "$default_value" 3>&1 1>&2 2>&3)
      if [[ $? -ne 0 ]]; then
        err "Operation cancelled."
      fi
      if [[ -z "$value" && -n "$default_value" ]]; then
        value="$default_value"
      fi
      ;;
    *)
      if [[ -n "$help_text" ]]; then
        printf '%s\n' "$help_text"
      fi
      if [[ -n "$default_value" ]]; then
        read -r -p "$prompt_text [$default_value]: " value
        value="${value:-$default_value}"
      else
        read -r -p "$prompt_text: " value
      fi
      ;;
  esac
  printf '%s' "$value"
}

prompt_hidden() {
  local prompt_text="$1"
  local help_text="${2:-}"
  local first second display
  while true; do
    case "$UI_BACKEND" in
      whiptail)
        display="$prompt_text"
        if [[ -n "$help_text" ]]; then
          display+=$'\n\n'"$help_text"
        fi
        first=$(whiptail --title "$UI_TITLE" --passwordbox "$display" 10 60 3>&1 1>&2 2>&3)
        if [[ $? -ne 0 ]]; then
          err "Operation cancelled."
        fi
        second=$(whiptail --title "$UI_TITLE" --passwordbox "Confirm $prompt_text" 10 60 3>&1 1>&2 2>&3)
        if [[ $? -ne 0 ]]; then
          err "Operation cancelled."
        fi
        ;;
      *)
        if [[ -n "$help_text" ]]; then
          printf '%s\n' "$help_text"
        fi
        read -r -s -p "$prompt_text: " first
        printf '\n'
        read -r -s -p "Confirm $prompt_text: " second
        printf '\n'
        ;;
    esac
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
  local help_text="${3:-}"
  local choice
  local display
  local suffix
  local default_lower="${default_answer,,}"

  case "$UI_BACKEND" in
    whiptail)
      display="$prompt_text"
      if [[ -n "$help_text" ]]; then
        display+=$'\n\n'"$help_text"
      fi
      local -a whiptail_args=(--title "$UI_TITLE" --yesno "$display" 12 70)
      case "$default_lower" in
        y|yes) ;;
        *) whiptail_args+=(--defaultno) ;;
      esac
      if whiptail "${whiptail_args[@]}" 3>&1 1>&2 2>&3; then
        return 0
      fi
      return 1
      ;;
    *)
      if [[ -n "$help_text" ]]; then
        printf '%s\n' "$help_text"
      fi
      case "$default_lower" in
        y|yes) suffix="[Y/n]" ;;
        *) suffix="[y/N]" ;;
      esac
      while true; do
        read -r -p "$prompt_text $suffix: " choice
        choice="${choice:-$default_answer}"
        case "${choice,,}" in
          y|yes) return 0 ;;
          n|no) return 1 ;;
        esac
        echo "Please answer yes or no."
      done
      ;;
  esac
}

detect_missing_requirements() {
  local -a required_cmds=(pacstrap arch-chroot lsblk sgdisk mkfs.ext4 mkfs.fat findmnt openssl chpasswd)
  local -a missing_cmds=()
  local cmd
  for cmd in "${required_cmds[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing_cmds+=("$cmd")
    fi
  done
  if ((${#missing_cmds[@]})); then
    err "Missing required tools: ${missing_cmds[*]}. Install them with: pacman -Sy ${missing_cmds[*]}"
  fi

  if command -v ping >/dev/null 2>&1; then
    if ! ping -c 1 -W 2 archlinux.org >/dev/null 2>&1; then
      warn "Network check failed (archlinux.org is unreachable)."
      if ! prompt_yes_no "Continue without confirming internet access?" "n" "Most installation steps download packages; connect to a network before proceeding."; then
        err "Installation cancelled due to missing network connectivity."
      fi
    fi
  else
    warn "Skipping network check because 'ping' is unavailable."
  fi

  if [[ $UI_BACKEND == "text" ]]; then
    warn "Install 'dialog' (pacman -Sy dialog) to enable whiptail-based menus. Continuing with plain text prompts."
  fi
}

detect_hardware() {
  log "Detecting hardware..."

  DETECTED_CPU="Unknown CPU"
  DETECTED_GPU="Unknown GPU"
  DETECTED_RAM_GB="Unknown"
  DETECTED_NETWORK="No active link"
  HAS_NETWORK=0

  if command -v lscpu >/dev/null 2>&1; then
    DETECTED_CPU=$(lscpu | awk -F: '/Model name/ {gsub(/^ +/,"",$2); print $2; exit}')
  elif [[ -f /proc/cpuinfo ]]; then
    DETECTED_CPU=$(awk -F: '/model name/ {gsub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo)
  fi
  [[ -n "$DETECTED_CPU" ]] || DETECTED_CPU="Unknown CPU"

  if command -v lspci >/dev/null 2>&1; then
    DETECTED_GPU=$(lspci | awk -F: '/VGA compatible controller|3D controller/ {gsub(/^ +/,"",$3); print $3; exit}')
  elif [[ -d /sys/class/drm ]]; then
    DETECTED_GPU=$(ls /sys/class/drm | grep -m1 '^card[0-9]*$' | xargs -I{} cat /sys/class/drm/{}/device/vendor 2>/dev/null || true)
  fi
  [[ -n "$DETECTED_GPU" ]] || DETECTED_GPU="Unknown GPU"

  local gpu_lower
  gpu_lower=$(printf '%s' "$DETECTED_GPU" | awk '{print tolower($0)}')
  case "$gpu_lower" in
    *nvidia*|*0x10de*)
      DETECTED_GPU_VENDOR="nvidia"
      ;;
    *amd*|*advanced micro devices*|*ati*|*radeon*|*0x1002*|*0x1022*)
      DETECTED_GPU_VENDOR="amd"
      ;;
    *)
      DETECTED_GPU_VENDOR="unknown"
      ;;
  esac

  if [[ -f /proc/meminfo ]]; then
    local mem_kb
    mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    if [[ -n "$mem_kb" ]]; then
      DETECTED_RAM_GB=$(( (mem_kb + 524288) / 1048576 ))
      DETECTED_RAM_GB="${DETECTED_RAM_GB} GB"
    fi
  fi
  [[ -n "$DETECTED_RAM_GB" ]] || DETECTED_RAM_GB="Unknown"

  if command -v nmcli >/dev/null 2>&1; then
    if nmcli networking connectivity >/dev/null 2>&1; then
      DETECTED_NETWORK="NetworkManager"
      HAS_NETWORK=1
    fi
  elif command -v ip >/dev/null 2>&1; then
    if ip route get 1.1.1.1 >/dev/null 2>&1; then
      DETECTED_NETWORK="Active route"
      HAS_NETWORK=1
    fi
  fi

  log "Detected CPU: $DETECTED_CPU"
  log "Detected GPU: $DETECTED_GPU"
  log "Detected RAM: $DETECTED_RAM_GB"
  log "Network status: $DETECTED_NETWORK"
}

detect_timezone() {
  local tz="" link_target

  if command -v timedatectl >/dev/null 2>&1; then
    tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    [[ "$tz" == "n/a" ]] && tz=""
  fi

  if [[ -z "$tz" ]]; then
    if [[ -L /etc/localtime ]]; then
      link_target=$(readlink -f /etc/localtime || true)
      tz=${link_target#/usr/share/zoneinfo/}
    elif [[ -f /etc/timezone ]]; then
      tz=$(< /etc/timezone)
    fi
  fi

  if [[ -z "$tz" && -n "$HAS_NETWORK" && $HAS_NETWORK -eq 1 && command -v curl >/dev/null 2>&1 ]]; then
    tz=$(curl -fsSL --max-time 2 https://ipapi.co/timezone 2>/dev/null || true)
  fi

  if [[ -n "$tz" ]]; then
    DETECTED_TIMEZONE="$tz"
    log "Detected timezone: $DETECTED_TIMEZONE"
  else
    DETECTED_TIMEZONE="UTC"
    log "Falling back to default timezone: $DETECTED_TIMEZONE"
  fi
}

apply_profile() {
  local profile="$1"
  PROFILE_MODE="$profile"
  SKIP_DESKTOP_PROMPT=0
  INSTALL_LINUX_ZEN="ask"
  INSTALL_LINUX_CACHYOS="ask"
  PROFILE_PACKAGES=()
  case "$profile" in
    gaming-gnome)
      PROFILE_NAME="Gaming desktop (GNOME)"
      PROFILE_DESCRIPTION=$'Desktop: GNOME\nKernel: linux + linux-zen\nNotes: Great for dedicated gaming rigs with AMD graphics.'
      DESKTOP_CHOICE="gnome"
      TARGET_HOSTNAME="arch-gaming"
      INSTALL_LINUX_ZEN="yes"
      INSTALL_LINUX_CACHYOS="no"
      SKIP_DESKTOP_PROMPT=1
      ;;
    performance-plasma)
      PROFILE_NAME="Performance desktop (Plasma)"
      PROFILE_DESCRIPTION=$'Desktop: KDE Plasma\nKernel: linux + linux-zen + linux-cachyos\nNotes: Adds Gamescope and OpenXR/OpenVR runtimes for high-refresh rigs.'
      DESKTOP_CHOICE="plasma"
      TARGET_HOSTNAME="arch-perf"
      INSTALL_LINUX_ZEN="yes"
      INSTALL_LINUX_CACHYOS="yes"
      PROFILE_PACKAGES=("gamescope" "openxr" "openvr" "monado")
      SKIP_DESKTOP_PROMPT=1
      ;;
    lightweight-xfce)
      PROFILE_NAME="Lightweight laptop (Xfce)"
      PROFILE_DESCRIPTION=$'Desktop: Xfce\nKernel: linux only\nNotes: Balanced defaults aimed at portable systems.'
      DESKTOP_CHOICE="xfce"
      TARGET_HOSTNAME="arch-lite"
      INSTALL_LINUX_ZEN="no"
      INSTALL_LINUX_CACHYOS="no"
      SKIP_DESKTOP_PROMPT=1
      ;;
    custom|*)
      PROFILE_MODE="custom"
      PROFILE_NAME="Guided setup"
      PROFILE_DESCRIPTION="Manual walkthrough where you review every setting."
      SKIP_DESKTOP_PROMPT=0
      ;;
  esac
}

profile_summary() {
  local summary=$'Active profile: '"$PROFILE_NAME"$'\n\n'"$PROFILE_DESCRIPTION"
  case "$UI_BACKEND" in
    whiptail)
      whiptail --title "$UI_TITLE" --msgbox "$summary" 18 70
      ;;
    *)
      printf '%s\n' "$summary"
      ;;
  esac
}

select_profile() {
  local selection choice
  case "$UI_BACKEND" in
    whiptail)
      selection=$(whiptail --title "$UI_TITLE" --menu "Choose a starting profile" 20 70 7 \
        "custom" "Guided setup (choose each option)" \
        "gaming-gnome" "Gaming desktop (GNOME + linux-zen)" \
        "performance-plasma" "Performance desktop (Plasma + zen + CachyOS)" \
        "lightweight-xfce" "Lightweight laptop (Xfce)" 3>&1 1>&2 2>&3)
      if [[ $? -ne 0 || -z "$selection" ]]; then
        selection="custom"
      fi
      ;;
    *)
      echo "Setup profiles:"
      echo "  1) Guided setup (choose each option)."
      echo "  2) Gaming desktop (GNOME + linux-zen)."
      echo "  3) Performance desktop (Plasma + zen + CachyOS)."
      echo "  4) Lightweight laptop (Xfce)."
      read -r -p "Select profile [1-4]: " choice
      case "$choice" in
        2) selection="gaming-gnome" ;;
        3) selection="performance-plasma" ;;
        4) selection="lightweight-xfce" ;;
        *) selection="custom" ;;
      esac
      ;;
  esac

  apply_profile "$selection"
  profile_summary
  if [[ $PROFILE_MODE != "custom" ]]; then
    log "Applied profile: $PROFILE_NAME (defaults pre-filled; you can adjust prompts as needed)."
  else
    log "Guided setup selected."
  fi
}

select_optional_extras() {
  SELECTED_EXTRA_LABELS=()
  EXTRA_PACKAGES=()

  if ! prompt_yes_no "Choose optional extras to install?" "y" "Extras include streaming, emulation, creative, and system tool bundles."; then
    log "Skipping optional extras selection."
    return
  fi

  local -a selected_tags=()
  if [[ $UI_BACKEND == "whiptail" ]]; then
    local selection
    selection=$(whiptail --title "$UI_TITLE" --checklist "Select optional extras (use Space to toggle)" 20 80 8 \
      "streaming" "Streaming & recording (OBS Studio, EasyEffects)" OFF \
      "emulation" "Emulation & retro gaming (RetroArch, Dolphin, PCSX2)" OFF \
      "creative" "Creative tools (Blender, GIMP, Inkscape)" OFF \
      "sysutils" "System utilities (htop, btop, fastfetch)" OFF 3>&1 1>&2 2>&3)
    if [[ $? -eq 0 && -n $selection ]]; then
      read -ra selected_tags <<< "$selection"
    fi
  else
    echo "Optional extras:"
    echo "  1) Streaming & recording (OBS Studio, EasyEffects)"
    echo "  2) Emulation & retro gaming (RetroArch, Dolphin, PCSX2)"
    echo "  3) Creative tools (Blender, GIMP, Inkscape)"
    echo "  4) System utilities (htop, btop, fastfetch)"
    local input_line
    read -r -p "Select numbers separated by spaces (Enter to skip): " input_line
    local -a input_choices=()
    read -ra input_choices <<< "$input_line"
    local choice
    for choice in "${input_choices[@]}"; do
      case "$choice" in
        1|streaming) selected_tags+=("streaming") ;;
        2|emulation) selected_tags+=("emulation") ;;
        3|creative) selected_tags+=("creative") ;;
        4|sysutils) selected_tags+=("sysutils") ;;
      esac
    done
  fi

  if ((${#selected_tags[@]} == 0)); then
    log "No optional extras selected."
    return
  fi

  local -a unique_tags=()
  local -A seen_tags=()
  local tag
  for tag in "${selected_tags[@]}"; do
    tag=${tag//\"/}
    [[ -z "$tag" ]] && continue
    if [[ -z ${seen_tags[$tag]:-} ]]; then
      seen_tags[$tag]=1
      unique_tags+=("$tag")
    fi
  done

  selected_tags=("${unique_tags[@]}")

  for tag in "${selected_tags[@]}"; do
    case "$tag" in
      streaming)
        SELECTED_EXTRA_LABELS+=("Streaming & recording")
        EXTRA_PACKAGES+=("obs-studio" "easyeffects")
        ;;
      emulation)
        SELECTED_EXTRA_LABELS+=("Emulation & retro gaming")
        EXTRA_PACKAGES+=("retroarch" "dolphin-emu" "pcsx2")
        ;;
      creative)
        SELECTED_EXTRA_LABELS+=("Creative tools")
        EXTRA_PACKAGES+=("blender" "gimp" "inkscape")
        ;;
      sysutils)
        SELECTED_EXTRA_LABELS+=("System utilities")
        EXTRA_PACKAGES+=("htop" "btop" "fastfetch")
        ;;
    esac
  done

  log "Selected extras: ${SELECTED_EXTRA_LABELS[*]}"
}

preflight_summary() {
  local desktop_info zen_plan cachyos_plan summary extras_text profile_pkg_text gpu_plan

  if (( SKIP_DESKTOP_PROMPT )); then
    desktop_info="Desktop/WM: ${DESKTOP_CHOICE} (from profile)"
  else
    desktop_info="Desktop/WM: Will prompt later (current default: ${DESKTOP_CHOICE})"
  fi

  case "$INSTALL_LINUX_ZEN" in
    yes) zen_plan="Install (profile default)" ;;
    no) zen_plan="Skip (profile default)" ;;
    *) zen_plan="Ask during install (default: Yes)" ;;
  esac

  case "$INSTALL_LINUX_CACHYOS" in
    yes) cachyos_plan="Install (profile default)" ;;
    no) cachyos_plan="Skip (profile default)" ;;
    *) cachyos_plan="Ask during install (default: No)" ;;
  esac

  case "$DETECTED_GPU_VENDOR" in
    amd) gpu_plan="Install AMD Mesa/Vulkan stack" ;;
    nvidia) gpu_plan="Run NVIDIA helper" ;;
    *) gpu_plan="Skip automatic GPU driver setup" ;;
  esac

  if ((${#SELECTED_EXTRA_LABELS[@]})); then
    extras_text=$( (
      IFS=', '
      printf '%s' "${SELECTED_EXTRA_LABELS[*]}"
    ))
  else
    extras_text="None"
  fi

  if ((${#PROFILE_PACKAGES[@]})); then
    profile_pkg_text=$( (
      IFS=', '
      printf '%s' "${PROFILE_PACKAGES[*]}"
    ))
  else
    profile_pkg_text="None"
  fi

  summary=$'Pre-flight Summary\n\n'
  summary+=$'Profile: '"$PROFILE_NAME"$'\n'
  summary+=$'Target disk: '"$TARGET_DISK"$'\n'
  summary+=$'Boot mode: '"${BOOT_MODE^^}"$'\n'
  summary+="${desktop_info}"$'\n'
  summary+=$'Kernel plan:\n'
  summary+=$'  - linux-zen: '"$zen_plan"$'\n'
  summary+=$'  - linux-cachyos: '"$cachyos_plan"$'\n'
  summary+=$'Hardware summary:\n'
  summary+=$'  - CPU: '"$DETECTED_CPU"$'\n'
  summary+=$'  - GPU: '"$DETECTED_GPU"$'\n'
  summary+=$'  - RAM: '"$DETECTED_RAM_GB"$'\n'
  summary+=$'  - Network: '"$DETECTED_NETWORK"$'\n'
  summary+=$'  - Detected timezone: '"$DETECTED_TIMEZONE"$'\n'
  summary+=$'  - GPU driver plan: '"$gpu_plan"$'\n'
  summary+=$'Hostname (current default): '"$TARGET_HOSTNAME"$'\n'
  summary+=$'Primary user (current default): '"$TARGET_USERNAME"$'\n'
  summary+=$'Mount point: '"$TARGET_MOUNT"$'\n\n'
  summary+=$'Optional extras: '"$extras_text"$'\n\n'
  summary+=$'Profile-specific packages: '"$profile_pkg_text"$'\n\n'
  summary+=$'No changes have been made yet. This is the final confirmation before wiping and partitioning the selected disk.'

  case "$UI_BACKEND" in
    whiptail)
      whiptail --title "$UI_TITLE" --msgbox "$summary" 20 70
      ;;
    *)
      printf '%s\n' "$summary"
      ;;
  esac

  if ! prompt_yes_no "Proceed with disk partitioning and installation?" "y" "Choose No to adjust settings or exit before any changes are made."; then
    err "Installation cancelled before making any changes."
  fi
}

check_environment() {
  if [[ $EUID -ne 0 ]]; then
    err "Run this installer as root."
  fi
  detect_missing_requirements
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
  if prompt_yes_no "Override detected boot mode?" "n" "UEFI is recommended for modern systems; choose BIOS only for legacy hardware."; then
    local choice
    while true; do
      choice=$(prompt "Enter boot mode (uefi/bios)" "$BOOT_MODE" "Type 'uefi' for systems with EFI firmware or 'bios' for legacy installs.")
      case "${choice,,}" in
        uefi|bios)
          BOOT_MODE="${choice,,}"
          break
          ;;
        *)
          warn "Invalid entry."
          ;;
      esac
    done
  fi
  log "Using boot mode: $BOOT_MODE"
}

select_target_disk() {
  case "$UI_BACKEND" in
    whiptail)
      local -a rows=()
      while read -r name size; do
        [[ -z "$name" ]] && continue
        rows+=("$name" "$size" "OFF")
      done < <(lsblk -dpno NAME,SIZE)
      if [[ ${#rows[@]} -lt 3 ]]; then
        err "No disks detected."
      fi
      rows[2]="ON"
      local selection
      selection=$(whiptail --title "$UI_TITLE" --radiolist "Select target disk (all data will be wiped)" 15 70 6 "${rows[@]}" 3>&1 1>&2 2>&3)
      if [[ $? -ne 0 || -z "$selection" ]]; then
        err "Operation cancelled."
      fi
      TARGET_DISK="$selection"
      ;;
    *)
      log "Available disks:"
      lsblk -dpno NAME,SIZE,MODEL | nl -ba
      log "Tip: select the full disk device (e.g., /dev/sda) instead of an individual partition."
      local choice
      while true; do
        read -r -p "Enter disk device path (e.g., /dev/sda, /dev/nvme0n1): " choice
        if [[ -b "$choice" ]]; then
          TARGET_DISK="$choice"
          break
        fi
        warn "Invalid block device."
      done
      ;;
  esac
  log "Selected disk: $TARGET_DISK"
  if ! prompt_yes_no "This will erase ALL data on $TARGET_DISK. Continue?" "n" "All partitions and files on the selected disk will be permanently removed."; then
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
  printf '%s:%s\n' "$user" "$password" | arch-chroot "$TARGET_MOUNT" chpasswd
}

configure_locale_timezone() {
  local default_timezone="$TARGET_TIMEZONE"
  if [[ -z "$default_timezone" || "$default_timezone" == "UTC" ]]; then
    default_timezone="$DETECTED_TIMEZONE"
  fi
  TARGET_TIMEZONE=$(prompt "Timezone (Region/City)" "$default_timezone" "Use Region/City format, e.g., Europe/Paris or America/New_York. Detected default: $DETECTED_TIMEZONE")
  TARGET_LOCALE=$(prompt "Locale" "$TARGET_LOCALE" "Matches entries in /etc/locale.gen, e.g., en_US.UTF-8.")
  run_in_chroot "ln -sf /usr/share/zoneinfo/$TARGET_TIMEZONE /etc/localtime"
  run_in_chroot "hwclock --systohc"
  run_in_chroot "sed -i 's/^#\(${TARGET_LOCALE//\//\/} UTF-8\)/\1/' /etc/locale.gen"
  run_in_chroot "locale-gen"
  printf 'LANG=%s\n' "$TARGET_LOCALE" > "$TARGET_MOUNT/etc/locale.conf"
}

configure_vconsole() {
  TARGET_VCONSOLE_KEYMAP=$(prompt "Console keymap" "$TARGET_VCONSOLE_KEYMAP" "Common options include us, uk, de-latin1, fr.")
  printf 'KEYMAP=%s\n' "$TARGET_VCONSOLE_KEYMAP" > "$TARGET_MOUNT/etc/vconsole.conf"
}

configure_network() {
  TARGET_HOSTNAME=$(prompt "Hostname" "$TARGET_HOSTNAME" "Short lowercase name for this machine (letters, numbers, hyphens).")
  printf '%s\n' "$TARGET_HOSTNAME" > "$TARGET_MOUNT/etc/hostname"
  cat <<EOF > "$TARGET_MOUNT/etc/hosts"
127.0.0.1 localhost
::1       localhost
127.0.1.1 $TARGET_HOSTNAME.localdomain $TARGET_HOSTNAME
EOF
  run_in_chroot "systemctl enable NetworkManager"
}

create_users() {
  ROOT_PASSWORD=$(prompt_hidden "Root password" "Choose a strong password; characters will not be shown while typing.")
  set_password_in_chroot root "$ROOT_PASSWORD"
  TARGET_USERNAME=$(prompt "Primary username" "$TARGET_USERNAME" "Lowercase login name without spaces, e.g., gamer.")
  run_in_chroot "useradd -m -G wheel,audio,video,storage $TARGET_USERNAME"
  USER_PASSWORD=$(prompt_hidden "Password for $TARGET_USERNAME" "Enter the login password for $TARGET_USERNAME; input remains hidden.")
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

install_nvidia_stack() {
  local helper_source helper_target helper_dir flags_str
  helper_source=$(cd "$(dirname "$0")" && pwd)/install-nvidia-stack.sh
  if [[ ! -f "$helper_source" ]]; then
    warn "NVIDIA helper script not found; skipping NVIDIA driver installation."
    return
  fi

  helper_dir="$TARGET_MOUNT/usr/local/bin"
  helper_target="$helper_dir/install-nvidia-stack.sh"
  mkdir -p "$helper_dir"
  cp "$helper_source" "$helper_target"
  chmod +x "$helper_target"

  log "Running NVIDIA helper inside chroot."
  printf -v flags_str '%s ' "${PACMAN_FLAGS[@]}"
  flags_str=${flags_str%% }
  if [[ -n "$flags_str" ]]; then
    run_in_chroot "PACMAN_FLAGS='$flags_str' /usr/local/bin/install-nvidia-stack.sh"
  else
    run_in_chroot "/usr/local/bin/install-nvidia-stack.sh"
  fi
  run_in_chroot "rm -f /usr/local/bin/install-nvidia-stack.sh"
}

install_gpu_stack() {
  case "$DETECTED_GPU_VENDOR" in
    nvidia)
      log "Detected NVIDIA GPU. Delegating driver setup."
      install_nvidia_stack
      ;;
    amd)
      log "Detected AMD GPU. Installing Mesa/Vulkan stack."
      install_amd_stack
      ;;
    *)
      warn "Unknown GPU vendor; skipping vendor-specific driver installation."
      ;;
  esac
}

install_kernel_options() {
  case "$INSTALL_LINUX_ZEN" in
    yes)
      log "Installing linux-zen kernel (profile default)."
      run_in_chroot "pacman -S ${PACMAN_FLAGS[*]} linux-zen linux-zen-headers"
      ;;
    no)
      log "Skipping linux-zen kernel (profile default)."
      ;;
    *)
      if prompt_yes_no "Install the linux-zen kernel in addition to the default kernel?" "y" "Adds a low-latency kernel tuned for gaming performance."; then
        run_in_chroot "pacman -S ${PACMAN_FLAGS[*]} linux-zen linux-zen-headers"
      fi
      ;;
  esac

  case "$INSTALL_LINUX_CACHYOS" in
    yes)
      log "Installing the linux-cachyos kernel as requested by profile."
      install_linux_cachyos
      ;;
    no)
      log "Skipping linux-cachyos kernel (profile default)."
      ;;
    *)
      if prompt_yes_no "Install the linux-cachyos kernel from AUR?" "n" "Builds and installs the CachyOS kernel from source; this takes longer but provides extra desktop optimizations."; then
        install_linux_cachyos
      fi
      ;;
  esac
}

install_linux_cachyos() {
  log "Building linux-cachyos kernel from AUR (this may take a while)..."
  run_in_chroot "pacman -S ${PACMAN_FLAGS[*]} git"
  run_in_chroot "su - $TARGET_USERNAME -c 'git clone https://aur.archlinux.org/linux-cachyos.git ~/linux-cachyos'"
  run_in_chroot "su - $TARGET_USERNAME -c 'cd ~/linux-cachyos && makepkg -si --noconfirm'"
  run_in_chroot "su - $TARGET_USERNAME -c 'rm -rf ~/linux-cachyos'"
}

select_desktop_environment() {
  if (( SKIP_DESKTOP_PROMPT )); then
    log "Using desktop environment from profile: $DESKTOP_CHOICE"
    return
  fi
  case "$UI_BACKEND" in
    whiptail)
      local selection
      selection=$(whiptail --title "$UI_TITLE" --menu "Select desktop environment" 18 70 6 \
        "gnome" "GNOME" \
        "plasma" "KDE Plasma" \
        "xfce" "Xfce" \
        "cinnamon" "Cinnamon" \
        "i3" "i3 Window Manager (tiling)" \
        "sway" "Sway (Wayland tiling WM)" \
        "none" "Skip" 3>&1 1>&2 2>&3)
      if [[ $? -ne 0 ]]; then
        warn "No selection made; defaulting to GNOME."
        DESKTOP_CHOICE="gnome"
      else
        DESKTOP_CHOICE="$selection"
      fi
      ;;
    *)
      echo "Desktop options:"
      echo "  1) GNOME"
      echo "  2) KDE Plasma"
      echo "  3) Xfce"
      echo "  4) Cinnamon"
      echo "  5) i3 (tiling window manager)"
      echo "  6) Sway (Wayland tiling window manager)"
      echo "  7) Skip"
      local choice
      while true; do
        read -r -p "Select desktop [1-7]: " choice
        case "$choice" in
          1) DESKTOP_CHOICE="gnome"; break ;;
          2) DESKTOP_CHOICE="plasma"; break ;;
          3) DESKTOP_CHOICE="xfce"; break ;;
          4) DESKTOP_CHOICE="cinnamon"; break ;;
          5) DESKTOP_CHOICE="i3"; break ;;
          6) DESKTOP_CHOICE="sway"; break ;;
          7) DESKTOP_CHOICE="none"; break ;;
          *) echo "Invalid selection." ;;
        esac
      done
      ;;
  esac
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
    i3)
      run_in_chroot "pacman -S ${PACMAN_FLAGS[*]} i3-wm i3status i3lock dmenu rofi xorg-server xorg-xinit lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings"
      run_in_chroot "systemctl enable lightdm"
      ;;
    sway)
      run_in_chroot "pacman -S ${PACMAN_FLAGS[*]} sway swaybg swayidle swaylock waybar xorg-server-xwayland alacritty xdg-desktop-portal-wlr gdm"
      run_in_chroot "systemctl enable gdm"
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

install_optional_extras() {
  if ((${#EXTRA_PACKAGES[@]} == 0)); then
    log "No optional extras selected for installation."
    return
  fi
  log "Installing optional extras: ${SELECTED_EXTRA_LABELS[*]}"
  run_in_chroot "pacman -S ${PACMAN_FLAGS[*]} ${EXTRA_PACKAGES[*]}"
}

install_profile_packages() {
  if ((${#PROFILE_PACKAGES[@]} == 0)); then
    return
  fi
  log "Installing profile-specific packages: ${PROFILE_PACKAGES[*]}"
  run_in_chroot "pacman -S ${PACMAN_FLAGS[*]} ${PROFILE_PACKAGES[*]}"
}

install_aur_helper() {
  if ! prompt_yes_no "Install AUR helper ($AUR_HELPER)?" "y" "Installs $AUR_HELPER for managing packages from the AUR."; then
    log "Skipping AUR helper installation."
    return
  fi
  run_in_chroot "pacman -S ${PACMAN_FLAGS[*]} git"
  run_in_chroot 'bash -c "echo \"%wheel ALL=(ALL:ALL) NOPASSWD: ALL\" > /etc/sudoers.d/00-aur-installer"'
  run_in_chroot "chmod 440 /etc/sudoers.d/00-aur-installer"
  run_in_chroot "su - $TARGET_USERNAME -c 'git clone https://aur.archlinux.org/${AUR_HELPER}.git ~/aur-helper'"
  run_in_chroot "su - $TARGET_USERNAME -c 'cd ~/aur-helper && makepkg -si --noconfirm'"
  run_in_chroot "su - $TARGET_USERNAME -c 'rm -rf ~/aur-helper'"
  run_in_chroot "rm -f /etc/sudoers.d/00-aur-installer"
  log "Installed $AUR_HELPER."
}

install_protonup_and_heroic() {
  if ! prompt_yes_no "Install ProtonUp-Qt and Heroic Games Launcher?" "y" "Installs ProtonUp-Qt for managing Proton versions and the Heroic launcher for Epic/GOG."; then
    log "Skipping ProtonUp-Qt and Heroic installation."
    return
  fi

  local -a pacman_targets=()
  local -a aur_targets=()
  local pkg

  if run_in_chroot "pacman -Si protonup-qt >/dev/null 2>&1"; then
    pacman_targets+=("protonup-qt")
  else
    aur_targets+=("protonup-qt")
  fi

  if run_in_chroot "pacman -Si heroic-games-launcher >/dev/null 2>&1"; then
    pacman_targets+=("heroic-games-launcher")
  else
    aur_targets+=("heroic-games-launcher-bin")
  fi

  if ((${#pacman_targets[@]} > 0)); then
    log "Installing ${pacman_targets[*]} from official repositories."
    run_in_chroot "pacman -S ${PACMAN_FLAGS[*]} ${pacman_targets[*]}"
  fi

  if ((${#aur_targets[@]} == 0)); then
    return
  fi

  if run_in_chroot "command -v $AUR_HELPER >/dev/null 2>&1"; then
    log "Using $AUR_HELPER to install ${aur_targets[*]} from the AUR."
    run_in_chroot 'bash -c "echo \"%wheel ALL=(ALL:ALL) NOPASSWD: ALL\" > /etc/sudoers.d/00-aur-installer"'
    run_in_chroot "chmod 440 /etc/sudoers.d/00-aur-installer"
    run_in_chroot "su - $TARGET_USERNAME -c '$AUR_HELPER -S --noconfirm ${aur_targets[*]}'"
    run_in_chroot "rm -f /etc/sudoers.d/00-aur-installer"
    return
  fi

  warn "Falling back to manual AUR build for ${aur_targets[*]}."
  run_in_chroot "pacman -S ${PACMAN_FLAGS[*]} git base-devel"
  run_in_chroot 'bash -c "echo \"%wheel ALL=(ALL:ALL) NOPASSWD: ALL\" > /etc/sudoers.d/00-aur-installer"'
  run_in_chroot "chmod 440 /etc/sudoers.d/00-aur-installer"
  for pkg in "${aur_targets[@]}"; do
    run_in_chroot "su - $TARGET_USERNAME -c 'git clone https://aur.archlinux.org/${pkg}.git ~/aur-${pkg}'"
    run_in_chroot "su - $TARGET_USERNAME -c 'cd ~/aur-${pkg} && makepkg -si --noconfirm'"
    run_in_chroot "su - $TARGET_USERNAME -c 'rm -rf ~/aur-${pkg}'"
  done
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
  init_ui
  if prompt_yes_no "View the quick start guide before continuing?" "y" "Great for first-time runs; you can skip if you're already familiar."; then
    show_quick_start_guide
  fi
  if prompt_yes_no "Open the installer help overview?" "y" "Covers profiles, kernels, desktops, and navigation tips."; then
    show_help_section
  fi
  check_environment
  detect_hardware
  detect_timezone
  select_profile
  select_optional_extras
  select_boot_mode
  select_target_disk
  preflight_summary
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
  install_gpu_stack
  install_gaming_stack
  install_optional_extras
  install_profile_packages
  select_desktop_environment
  install_desktop_environment
  install_aur_helper
  install_protonup_and_heroic
  install_bootloader
  cleanup
  log "Installation complete. Reboot into your new system."
}

main "$@"

