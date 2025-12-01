#!/usr/bin/env bash
set -Eeuo pipefail

# ================================================================
# Global Configuration & Defaults
# ================================================================

PACMAN_FLAGS=(--needed --noconfirm)
AUR_FLAGS=(--needed --noconfirm)
AUR_HELPER=""
AUR_HELPER_SELECTION="paru"
AUR_KERNEL_SELECTION="linux-amd-znver3"
MULTILIB_ENABLED=0
DESKTOP_CHOICE="skip"
ENABLE_AUR=0
OPTIMIZE_MIRRORS=0
INSTALL_GAMING=1
SWAPFILE_PATH="/swapfile"
DEFAULT_GAMING_COMPONENTS=(steam lutris wine gamemode mangohud pipewire openxr dxvk)
GAMING_COMPONENTS_SELECTED=("${DEFAULT_GAMING_COMPONENTS[@]}")
RUN_MODE="postinstall"
MOUNTPOINT="/mnt"
BASE_DISK=""
EFI_PART=""
ROOT_PART=""
BASE_HOSTNAME="arch-box"
BASE_USERNAME="gamer"
BASE_TIMEZONE="UTC"
BASE_LOCALE="en_US.UTF-8"
BASE_ROOT_PASSWORD=""
BASE_USER_PASSWORD=""
BOOT_MODE="uefi"
BIOS_BOOT_PART=""
SCRIPT_PATH="$0"
if command -v realpath >/dev/null 2>&1; then
  SCRIPT_PATH="$(realpath "$0")"
fi
UI_MODE="text"
UI_TITLE="Arch AMD Gaming Setup"
UI_BOX_HEIGHT=12
UI_BOX_WIDTH=70
UI_MENU_HEIGHT=10
FORCED_RUN_MODE=""

# ================================================================
# CLI Argument Parsing & Environment Detection
# ================================================================

print_usage() {
  cat <<'EOF'
Arch AMD Gaming Setup

Usage: ./arch-amd-gaming-setup.sh [--mode postinstall|fullinstall]
  --mode postinstall   Force post-install flow (skip auto-detection)
  --mode fullinstall   Force full disk install (requires root on live ISO)
  -h, --help           Show this help message
EOF
}

parse_cli_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        if [[ $# -lt 2 ]]; then
          err "--mode requires an argument"
          exit 1
        fi
        FORCED_RUN_MODE="$2"
        shift 2
        ;;
      --mode=*)
        FORCED_RUN_MODE="${1#*=}"
        shift
        ;;
      -h|--help)
        print_usage
        exit 0
        ;;
      *)
        warn "Unknown argument: $1"
        shift
        ;;
    esac
  done

  if [[ -n "$FORCED_RUN_MODE" ]]; then
    case "$FORCED_RUN_MODE" in
      fullinstall|postinstall) ;;
      *)
        err "Invalid --mode value '$FORCED_RUN_MODE'. Use 'fullinstall' or 'postinstall'."
        exit 1
        ;;
    esac
  fi
}

detect_timezone_default() {
  local detected=""
  if command -v timedatectl >/dev/null 2>&1; then
    detected=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  fi
  if [[ -z "$detected" && -L /etc/localtime ]]; then
    detected=$(readlink -f /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')
  fi
  if [[ -z "$detected" && -f /etc/timezone ]]; then
    detected=$(< /etc/timezone)
  fi
  if [[ -n "$detected" ]]; then
    BASE_TIMEZONE="$detected"
  fi
}

# ================================================================
# Logging, UI Initialization & Prompt Helpers
# ================================================================

log() {
  printf '[+] %s\n' "$1"
}

warn() {
  printf '[!] %s\n' "$1"
}

err() {
  printf '[x] %s\n' "$1" >&2
}

init_ui() {
  if command -v dialog >/dev/null 2>&1 && [[ -n "${TERM:-}" && $TERM != "dumb" ]]; then
    UI_MODE="dialog"
  else
    UI_MODE="text"
  fi
}

ui_cancelled() {
  err "Operation cancelled by user."
  exit 1
}

prompt_yes_no() {
  local prompt="$1"
  local default_answer="${2:-n}"
  local normalized="${default_answer,,}"

  if [[ $UI_MODE == "dialog" ]]; then
    local -a extra=()
    if [[ $normalized == n* ]]; then
      extra+=(--defaultno)
    fi
    if dialog --title "$UI_TITLE" "${extra[@]}" --yesno "$prompt" "$UI_BOX_HEIGHT" "$UI_BOX_WIDTH"; then
      return 0
    fi
    return 1
  fi

  while true; do
    local answer
    read -r -p "$prompt [y/n] (default: ${normalized:-n}): " answer
    answer="${answer:-$normalized}"
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

prompt_text_input() {
  local prompt="$1"
  local default_value="${2:-}"
  local input

  if [[ $UI_MODE == "dialog" ]]; then
    input=$(dialog --title "$UI_TITLE" --inputbox "$prompt" "$UI_BOX_HEIGHT" "$UI_BOX_WIDTH" "$default_value" --stdout) || ui_cancelled
  else
    read -r -p "$prompt${default_value:+ [$default_value]}: " input
    input="${input:-$default_value}"
  fi

  printf '%s' "$input"
}

prompt_hostname() {
  while true; do
    local value
    value=$(prompt_text_input "Hostname" "$BASE_HOSTNAME")
    value="${value,,}"
    value="${value// /-}"
    if [[ -n "$value" ]]; then
      BASE_HOSTNAME="$value"
      break
    fi
    echo "Hostname cannot be empty."
  done
}

prompt_timezone() {
  while true; do
    local tz
    tz=$(prompt_text_input "Timezone (Region/City)" "$BASE_TIMEZONE")
    if [[ -n "$tz" ]]; then
      BASE_TIMEZONE="$tz"
      break
    fi
    echo "Timezone cannot be empty."
  done
}

prompt_locale() {
  while true; do
    local locale
    locale=$(prompt_text_input "Locale (e.g., en_US.UTF-8)" "$BASE_LOCALE")
    if [[ -n "$locale" ]]; then
      BASE_LOCALE="$locale"
      break
    fi
    echo "Locale cannot be empty."
  done
}

prompt_username() {
  while true; do
    local username
    username=$(prompt_text_input "New user name" "$BASE_USERNAME")
    username="${username,,}"
    if [[ -n "$username" && $username =~ ^[a-z][-a-z0-9_]*$ ]]; then
      BASE_USERNAME="$username"
      break
    fi
    echo "Enter a lowercase username (letters, numbers, -, _)."
  done
}

prompt_password() {
  local var_name="$1"
  local label="${2:-user}"
  local pass1=""
  local pass2=""

  while true; do
    if [[ $UI_MODE == "dialog" ]]; then
      pass1=$(dialog --title "$UI_TITLE" --insecure --passwordbox "Enter password for $label" "$UI_BOX_HEIGHT" "$UI_BOX_WIDTH" --stdout) || ui_cancelled
      pass2=$(dialog --title "$UI_TITLE" --insecure --passwordbox "Confirm password for $label" "$UI_BOX_HEIGHT" "$UI_BOX_WIDTH" --stdout) || ui_cancelled
    else
      read -rs -p "Password for $label: " pass1; echo
      read -rs -p "Confirm password for $label: " pass2; echo
    fi

    if [[ -z "$pass1" ]]; then
      echo "Password cannot be empty."
      continue
    fi
    if [[ "$pass1" != "$pass2" ]]; then
      echo "Passwords do not match. Try again."
      continue
    fi
    printf -v "$var_name" '%s' "$pass1"
    break
  done

  pass1=""
  pass2=""
}

detect_current_boot_mode() {
  if [[ -d /sys/firmware/efi ]]; then
    printf 'uefi'
  else
    printf 'bios'
  fi
}

run_root_cmd() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

install_packages() {
  local message="$1"
  shift || true
  if [[ $# -eq 0 ]]; then
    return
  fi
  log "$message"
  run_root_cmd pacman -S "${PACMAN_FLAGS[@]}" "$@"
}

update_system() {
  log "Updating system packages..."
  run_root_cmd pacman -Syu "${PACMAN_FLAGS[@]}"
}

detect_multilib() {
  local conf="/etc/pacman.conf"
  if grep -Eq '^[[:space:]]*\[multilib\]' "$conf" && grep -Eq '^[[:space:]]*Include[[:space:]]*=.*multilib' "$conf"; then
    MULTILIB_ENABLED=1
  else
    MULTILIB_ENABLED=0
  fi
}

enable_multilib() {
  local conf="/etc/pacman.conf"
  detect_multilib
  if [[ $MULTILIB_ENABLED -eq 1 ]]; then
    log "Multilib repository already enabled."
    return
  fi

  local backup="${conf}.bak.$(date +%Y%m%d%H%M%S)"
  run_root_cmd cp "$conf" "$backup"
  run_root_cmd bash -s "$conf" <<'EOF'
set -euo pipefail
conf="$1"
if ! grep -Eq '^[[:space:]]*\[multilib\]' "$conf"; then
  printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> "$conf"
else
  sed -i 's/^#[[:space:]]*\(\[multilib\]\)/\1/' "$conf"
  if grep -Eq '^[[:space:]]*Include[[:space:]]*=.*multilib' "$conf"; then
    sed -i 's/^#[[:space:]]*\(Include[[:space:]]*=.*multilib.*\)/\1/' "$conf"
  else
    awk -v add='Include = /etc/pacman.d/mirrorlist' '
      BEGIN{inserted=0}
      /^\s*\[multilib\]/ {
        print
        if (!inserted) {
          print add
          inserted=1
        }
        next
      }
      {print}
      END{
        if (!inserted) {
          print "[multilib]"
          print add
        }
      }
    ' "$conf" > "${conf}.tmp"
    mv "${conf}.tmp" "$conf"
  fi
fi
EOF
  run_root_cmd pacman -Sy
  detect_multilib
  if [[ $MULTILIB_ENABLED -eq 1 ]]; then
    log "Multilib repository enabled."
  else
    warn "Failed to enable multilib repository automatically."
  fi
}

ensure_multilib_for_gaming() {
  detect_multilib
  if [[ $MULTILIB_ENABLED -eq 1 ]]; then
    return 0
  fi
  warn "Multilib repository disabled; 32-bit gaming components will be skipped."
  return 1
}

check_prereqs() {
  require_command pacman "pacman is required"
  require_command systemctl "systemctl is required"
  if [[ $EUID -ne 0 ]]; then
    require_command sudo "sudo is required for privileged operations"
  fi
}

check_base_install_prereqs() {
  if [[ $EUID -ne 0 ]]; then
    err "Full install mode must be run as root."
    exit 1
  fi
  local -a required=(lsblk sgdisk mkfs.ext4 mkfs.fat pacstrap arch-chroot)
  local cmd
  for cmd in "${required[@]}"; do
    require_command "$cmd" "$cmd is required for full installation"
  done
}

select_gaming_components() {
  local -a selections=("${GAMING_COMPONENTS_SELECTED[@]}")
  if [[ $UI_MODE == "dialog" ]]; then
    local options=(steam lutris wine gamemode mangohud pipewire openxr dxvk)
    local checklist=()
    for option in "${options[@]}"; do
      local desc=""
      case "$option" in
        steam) desc="Steam client + runtime" ;;
        lutris) desc="Lutris launcher" ;;
        wine) desc="Wine + helpers" ;;
        gamemode) desc="Feral gamemode service" ;;
        mangohud) desc="MangoHud overlay + GOverlay" ;;
        pipewire) desc="PipeWire audio stack" ;;
        openxr) desc="OpenXR + Vulkan tools" ;;
        dxvk) desc="DXVK binaries (needs multilib)" ;;
      esac
      local state="off"
      for sel in "${GAMING_COMPONENTS_SELECTED[@]}"; do
        if [[ $sel == "$option" ]]; then
          state="on"
          break
        fi
      done
      checklist+=("$option" "$desc" "$state")
    done
    local result
    result=$(dialog --title "$UI_TITLE" --checklist "Select gaming components to install" 20 80 10 "${checklist[@]}" --separate-output --stdout) || ui_cancelled
    mapfile -t selections <<<"$result"
  else
    echo "Select gaming components to install (comma-separated). Options:"
    echo "  steam, lutris, wine, gamemode, mangohud, pipewire, openxr, dxvk"
    local default_input
    default_input=$(IFS=, ; echo "${GAMING_COMPONENTS_SELECTED[*]}")
    local input
    read -r -p "Selection (default: $default_input): " input
    input="${input:-$default_input}"
    IFS=',' read -ra selections <<<"$input"
    for i in "${!selections[@]}"; do
      local trimmed="${selections[i]}"
      trimmed="${trimmed#${trimmed%%[![:space:]]*}}"
      trimmed="${trimmed%${trimmed##*[![:space:]]}}"
      selections[i]="${trimmed,,}"
    done
  fi

  local -a filtered=()
  for sel in "${selections[@]}"; do
    case "$sel" in
      steam|lutris|wine|gamemode|mangohud|pipewire|openxr|dxvk)
        filtered+=("$sel")
        ;;
    esac
  done
  GAMING_COMPONENTS_SELECTED=("${filtered[@]}")
}

require_command() {
  local cmd="$1"
  local msg="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "$msg"
    exit 1
  fi
}

# ================================================================
# Package Management & System Preparation
# ================================================================

optimize_mirrors() {
  if ! prompt_yes_no "Optimize pacman mirrors for speed using reflector?" "y"; then
    return
  fi

  OPTIMIZE_MIRRORS=1
  install_packages "Installing reflector..." reflector

  local countries_input
  countries_input=$(prompt_text_input "Enter comma-separated country names or leave blank for worldwide" "") || true

  local mirrorlist="/etc/pacman.d/mirrorlist"
  run_root_cmd cp "$mirrorlist" "${mirrorlist}.bak.$(date +%Y%m%d%H%M%S)"

  local -a reflector_cmd=(
    reflector
    --protocol https
    --latest 30
    --sort rate
    --fastest 15
    --save "$mirrorlist"
  )

  if [[ -n "$countries_input" ]]; then
    IFS=',' read -ra countries <<<"$countries_input"
    for country in "${countries[@]}"; do
      local trimmed="$country"
      trimmed="${trimmed#${trimmed%%[![:space:]]*}}"
      trimmed="${trimmed%${trimmed##*[![:space:]]}}"
      if [[ -n "$trimmed" ]]; then
        reflector_cmd+=(--country "$trimmed")
      fi
    done
  fi

  log "Refreshing mirrorlist with reflector..."
  run_root_cmd "${reflector_cmd[@]}"
  log "Mirrorlist updated."
}

ensure_local_uefi_packages() {
  local packages=(grub efibootmgr fwupd)
  local missing=()
  for pkg in "${packages[@]}"; do
    if ! pacman -Qi "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    install_packages "Installing UEFI tooling (${missing[*]})..." "${missing[@]}"
  fi
}

run_uefi_bootloader_setup() {
  if [[ ! -d /sys/firmware/efi ]]; then
    warn "System is not currently booted in UEFI mode; skipping GRUB install."
    return
  fi

  ensure_local_uefi_packages
  local default_mount="/boot"
  [[ -d /boot/efi ]] && default_mount="/boot/efi"
  local efi_mount
  efi_mount=$(prompt_text_input "EFI system partition mount point" "$default_mount")
  if [[ -z "$efi_mount" || ! -d "$efi_mount" ]]; then
    warn "EFI mount point '$efi_mount' not found. Ensure it is created and mounted, then re-run this step."
    return
  fi

  if ! mountpoint -q "$efi_mount"; then
    warn "EFI mount point $efi_mount is not mounted; GRUB install may fail. Mount it and re-run."
    return
  fi

  log "Running grub-install for target x86_64-efi..."
  if ! run_root_cmd grub-install --target=x86_64-efi --efi-directory="$efi_mount" --bootloader-id=ArchLinux --recheck; then
    err "grub-install failed; please check the EFI partition and rerun."
    return
  fi
  log "Generating GRUB configuration..."
  run_root_cmd grub-mkconfig -o /boot/grub/grub.cfg
}

ensure_local_bios_packages() {
  if ! pacman -Qi grub >/dev/null 2>&1; then
    install_packages "Installing GRUB for BIOS systems..." grub
  fi
}

select_bootloader_mode_choice() {
  local prompt="$1"
  local detected
  detected=$(detect_current_boot_mode)
  local default_choice="$detected"
  local selection

  if [[ $UI_MODE == "dialog" ]]; then
    selection=$(dialog --title "$UI_TITLE" --default-item "$default_choice" --menu "$prompt" 15 70 "$UI_MENU_HEIGHT" \
      uefi "UEFI system" \
      bios "Legacy BIOS" --stdout) || ui_cancelled
  else
    echo "$prompt"
    echo "  1) UEFI"
    echo "  2) Legacy BIOS"
    local choice
    while true; do
      read -r -p "Choice [1-2] (default: $([[ $default_choice == uefi ]] && echo 1 || echo 2)): " choice
      choice="${choice:-$([[ $default_choice == uefi ]] && echo 1 || echo 2)}"
      case "$choice" in
        1) selection="uefi"; break ;;
        2) selection="bios"; break ;;
        *) echo "Invalid selection, try again." ;;
      esac
    done
  fi

  printf '%s' "$selection"
}

select_install_boot_mode() {
  local selection
  selection=$(select_bootloader_mode_choice "Select boot mode for the new installation")
  BOOT_MODE="$selection"
  local detected
  detected=$(detect_current_boot_mode)
  if [[ $BOOT_MODE == "bios" && $detected == "uefi" ]]; then
    warn "Legacy BIOS install selected while firmware is in UEFI mode; ensure this is intentional."
  elif [[ $BOOT_MODE == "uefi" && $detected == "bios" ]]; then
    warn "UEFI install selected but system booted in BIOS/Legacy mode; installation will only boot via UEFI."
  fi
}

run_bios_bootloader_setup() {
  ensure_local_bios_packages
  local boot_disk
  boot_disk=$(prompt_disk_selection "Select disk for BIOS GRUB install")
  log "Running grub-install for legacy BIOS on $boot_disk..."
  if ! run_root_cmd grub-install --target=i386-pc "$boot_disk"; then
    err "grub-install failed for BIOS mode; please inspect disk state and retry."
    return
  fi
  log "Generating GRUB configuration..."
  run_root_cmd grub-mkconfig -o /boot/grub/grub.cfg
}

configure_bootloader_postinstall() {
  if ! prompt_yes_no "Install or repair a bootloader now?" "n"; then
    return
  fi
  local mode
  mode=$(select_bootloader_mode_choice "Select bootloader target mode")
  case "$mode" in
    uefi) run_uefi_bootloader_setup ;;
    bios) run_bios_bootloader_setup ;;
  esac
}

select_run_mode() {
  if [[ -n "$FORCED_RUN_MODE" ]]; then
    RUN_MODE="$FORCED_RUN_MODE"
    log "Using forced mode: $RUN_MODE"
    return
  fi

  if [[ $EUID -eq 0 ]]; then
    RUN_MODE="fullinstall"
  else
    RUN_MODE="postinstall"
  fi
  log "Auto-detected run mode: $RUN_MODE"
}

select_existing_user() {
  local -a user_entries=()
  while IFS=: read -r name _ uid _ home _; do
    if ((uid >= 1000)) && [[ -d "$home" ]]; then
      user_entries+=("$name:$home")
    fi
  done < <(getent passwd)

  if [[ ${#user_entries[@]} -eq 0 ]]; then
    err "No regular users detected to grant sudo access."
    return 1
  fi

  if [[ $UI_MODE == "dialog" ]]; then
    local menu_entries=()
    for entry in "${user_entries[@]}"; do
      local name="${entry%%:*}"
      local home="${entry#*:}"
      menu_entries+=("$name" "$home")
    done
    local selection
    selection=$(dialog --title "$UI_TITLE" --menu "Select user to grant sudo" 20 80 "$UI_MENU_HEIGHT" "${menu_entries[@]}" --stdout) || ui_cancelled
    printf '%s' "$selection"
    return
  fi

  echo "Available users:"
  for i in "${!user_entries[@]}"; do
    local entry="${user_entries[i]}"
    local name="${entry%%:*}"
    local home="${entry#*:}"
    printf '  %d) %s (%s)\n' "$((i + 1))" "$name" "$home"
  done

  local choice
  while true; do
    read -r -p "Select user [1-${#user_entries[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#user_entries[@]})); then
      printf '%s' "${user_entries[choice-1]%%:*}"
      return
    fi
    echo "Invalid selection, try again."
  done
}

prompt_disk_selection() {
  local prompt="$1"
  local -a disk_entries=()
  mapfile -t disk_entries < <(lsblk -dpno NAME,SIZE,TYPE | awk '$3=="disk" {print $1" "$2}')
  if [[ ${#disk_entries[@]} -eq 0 ]]; then
    err "No disks detected."
    exit 1
  fi

  if [[ $UI_MODE == "dialog" ]]; then
    local menu_entries=()
    local entry name size
    for entry in "${disk_entries[@]}"; do
      name="${entry%% *}"
      size="${entry#* }"
      menu_entries+=("$name" "$size")
    done
    local selection
    selection=$(dialog --title "$UI_TITLE" --menu "$prompt" 20 80 "$UI_MENU_HEIGHT" "${menu_entries[@]}" --stdout) || ui_cancelled
    printf '%s' "$selection"
    return
  fi

  echo "Available disks:"
  local i entry name size
  for i in "${!disk_entries[@]}"; do
    entry="${disk_entries[i]}"
    name="${entry%% *}"
    size="${entry#* }"
    printf '  %d) %s (%s)\n' "$((i + 1))" "$name" "$size"
  done

  local choice
  while true; do
    read -r -p "$prompt [1-${#disk_entries[@]} or device path]: " choice
    if [[ -z "$choice" ]]; then
      choice="1"
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#disk_entries[@]})); then
      printf '%s' "${disk_entries[choice-1]%% *}"
      return
    fi

    local candidate="$choice"
    if [[ $candidate != /dev/* ]]; then
      candidate="/dev/${candidate}"  # allow entering bare device names like sda
    fi
    for entry in "${disk_entries[@]}"; do
      name="${entry%% *}"
      if [[ "$candidate" == "$name" ]]; then
        printf '%s' "$name"
        return
      fi
    done
    echo "Invalid selection, try again."
  done
}

install_gaming_packages() {
  if [[ ${#GAMING_COMPONENTS_SELECTED[@]} -eq 0 ]]; then
    warn "No gaming components selected; skipping package installation."
    return
  fi

  local -a packages=()
  for component in "${GAMING_COMPONENTS_SELECTED[@]}"; do
    case "$component" in
      steam) packages+=(steam steam-native-runtime) ;;
      lutris) packages+=(lutris) ;;
      wine) packages+=(wine wine-mono wine-gecko) ;;
      gamemode) packages+=(gamemode) ;;
      mangohud) packages+=(mangohud goverlay) ;;
      pipewire) packages+=(pipewire pipewire-alsa pipewire-pulse pipewire-jack qpwgraph) ;;
      openxr) packages+=(openxr-loader vulkan-tools) ;;
      dxvk)
        if [[ $MULTILIB_ENABLED -eq 1 ]]; then
          packages+=(dxvk-bin)
        else
          warn "Skipping DXVK because multilib is disabled."
        fi
        ;;
    esac
  done

  if [[ ${#packages[@]} -eq 0 ]]; then
    warn "No installable gaming packages detected after filtering."
    return
  fi

  local -a deduped=()
  declare -A seen=()
  local pkg
  for pkg in "${packages[@]}"; do
    if [[ -n "$pkg" && -z ${seen[$pkg]+x} ]]; then
      deduped+=("$pkg")
      seen[$pkg]=1
    fi
  done

  install_packages "Installing selected gaming packages..." "${deduped[@]}"
}

select_install_disk() {
  BASE_DISK=$(prompt_disk_selection "Select target disk (all data will be wiped)")
}

confirm_disk_wipe() {
  if ! prompt_yes_no "ALL DATA on $BASE_DISK will be erased. Continue?" "n"; then
    err "Disk wipe cancelled."
    exit 1
  fi
}

set_partition_paths() {
  local suffix=""
  if [[ $BASE_DISK == *"nvme"* || $BASE_DISK == *"mmcblk"* || $BASE_DISK == *"loop"* ]]; then
    suffix="p"
  fi
  if [[ $BOOT_MODE == "uefi" ]]; then
    EFI_PART="${BASE_DISK}${suffix}1"
    ROOT_PART="${BASE_DISK}${suffix}2"
    BIOS_BOOT_PART=""
  else
    BIOS_BOOT_PART="${BASE_DISK}${suffix}1"
    ROOT_PART="${BASE_DISK}${suffix}2"
    EFI_PART=""
  fi
}

partition_disk() {
  sgdisk --zap-all "$BASE_DISK"
  if [[ $BOOT_MODE == "uefi" ]]; then
    log "Partitioning $BASE_DISK (UEFI: 512MiB EFI + rest root)..."
    sgdisk -n1:0:+512M -t1:ef00 -c1:"EFI System" "$BASE_DISK"
    sgdisk -n2:0:0 -t2:8300 -c2:"Linux Root" "$BASE_DISK"
  else
    log "Partitioning $BASE_DISK (BIOS: 1MiB bios_grub + rest root)..."
    sgdisk -a1 -n1:34:2047 -t1:ef02 -c1:"BIOS Boot" "$BASE_DISK"
    sgdisk -n2:0:0 -t2:8300 -c2:"Linux Root" "$BASE_DISK"
  fi
  partprobe "$BASE_DISK"
}

format_and_mount_partitions() {
  mkdir -p "$MOUNTPOINT"
  if [[ $BOOT_MODE == "uefi" ]]; then
    log "Formatting $EFI_PART as FAT32 and $ROOT_PART as ext4..."
    mkfs.fat -F32 "$EFI_PART"
    mkfs.ext4 -F "$ROOT_PART"
    log "Mounting root at $MOUNTPOINT and EFI at $MOUNTPOINT/boot..."
    mount "$ROOT_PART" "$MOUNTPOINT"
    mkdir -p "$MOUNTPOINT/boot"
    mount "$EFI_PART" "$MOUNTPOINT/boot"
  else
    log "Formatting $ROOT_PART as ext4 (BIOS mode)..."
    mkfs.ext4 -F "$ROOT_PART"
    log "Mounting root at $MOUNTPOINT..."
    mount "$ROOT_PART" "$MOUNTPOINT"
  fi
}

pacstrap_base_system() {
  local base_packages=(base linux linux-firmware networkmanager sudo grub)
  if [[ $BOOT_MODE == "uefi" ]]; then
    base_packages+=(efibootmgr)
  fi
  log "Installing base system with pacstrap..."
  pacstrap -K "$MOUNTPOINT" "${base_packages[@]}"
  genfstab -U "$MOUNTPOINT" >>"$MOUNTPOINT/etc/fstab"
}

install_optional_fwupd_in_chroot() {
  if [[ $BOOT_MODE != "uefi" ]]; then
    return
  fi
  if prompt_yes_no "Install fwupd in the new system for firmware updates?" "y"; then
    arch-chroot "$MOUNTPOINT" pacman -S --needed --noconfirm fwupd
  fi
}

install_bootloader_in_chroot() {
  log "Installing and configuring GRUB bootloader..."
  if [[ $BOOT_MODE == "uefi" ]]; then
    arch-chroot "$MOUNTPOINT" grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ArchLinux --recheck
  else
    arch-chroot "$MOUNTPOINT" grub-install --target=i386-pc "$BASE_DISK"
  fi
  arch-chroot "$MOUNTPOINT" grub-mkconfig -o /boot/grub/grub.cfg
}

ensure_wheel_sudoers() {
  local sudoers="/etc/sudoers"
  if run_root_cmd grep -Eq '^[[:space:]]*%wheel[[:space:]]*ALL=\(ALL(:ALL)?\)[[:space:]]*ALL' "$sudoers"; then
    return
  fi
  local backup="${sudoers}.bak.$(date +%Y%m%d%H%M%S)"
  run_root_cmd cp "$sudoers" "$backup"
  if run_root_cmd grep -Eq '^[[:space:]]*#[[:space:]]*%wheel[[:space:]]*ALL=\(ALL(:ALL)?\)[[:space:]]*ALL' "$sudoers"; then
    run_root_cmd sed -i 's/^[[:space:]]*#[[:space:]]*\(%wheel ALL=(ALL:ALL) ALL\)/\1/' "$sudoers"
  else
    printf '\n%%wheel ALL=(ALL:ALL) ALL\n' | run_root_cmd tee -a "$sudoers" >/dev/null
  fi
}

grant_sudo_privileges() {
  if ! prompt_yes_no "Grant sudo privileges to an existing user?" "n"; then
    return
  fi
  local username
  if ! username=$(select_existing_user); then
    return
  fi
  log "Adding $username to wheel group..."
  run_root_cmd usermod -aG wheel "$username"
  ensure_wheel_sudoers
  log "User $username now has sudo access via wheel group."
}

configure_swapfile() {
  if ! prompt_yes_no "Create or update a swap file?" "n"; then
    return
  fi

  local default_size="4"
  local size_input
  while true; do
    size_input=$(prompt_text_input "Swap size in GiB (integer >0)" "$default_size")
    if [[ "$size_input" =~ ^[0-9]+$ ]] && ((size_input > 0)); then
      break
    fi
    echo "Enter a positive integer."
  done

  local path
  path=$(prompt_text_input "Swap file path" "$SWAPFILE_PATH")
  if [[ -z "$path" ]]; then
    warn "Swap file path cannot be empty; aborting swap setup."
    return
  fi

  SWAPFILE_PATH="$path"

  if run_root_cmd test -e "$path"; then
    if prompt_yes_no "Swap file $path already exists. Recreate it?" "n"; then
      run_root_cmd swapoff "$path" 2>/dev/null || true
      run_root_cmd rm -f "$path"
    else
      warn "Keeping existing swap file."
      return
    fi
  fi

  log "Creating swap file $path (${size_input}G)..."
  if ! run_root_cmd fallocate -l "${size_input}G" "$path"; then
    warn "fallocate failed; falling back to dd (may take longer)."
    if ! run_root_cmd dd if=/dev/zero of="$path" bs=1M count="$((size_input * 1024))" status=progress; then
      err "Failed to allocate swap file."; return
    fi
  fi
  run_root_cmd chmod 600 "$path"
  if ! run_root_cmd mkswap "$path"; then
    err "mkswap failed; removing incomplete swap file."
    run_root_cmd rm -f "$path"
    return
  fi
  run_root_cmd swapon "$path"
  if run_root_cmd grep -q "^$path[[:space:]]" /etc/fstab; then
    log "Swap entry for $path already present in /etc/fstab."
  else
    printf '%s\n' "$path none swap defaults 0 0" | run_root_cmd tee -a /etc/fstab >/dev/null
    log "Added $path to /etc/fstab."
  fi
  log "Swap configured and enabled."
}

configure_system_in_chroot() {
  log "Configuring timezone, locale, and hostname..."
  if [[ -f "/usr/share/zoneinfo/$BASE_TIMEZONE" ]]; then
    arch-chroot "$MOUNTPOINT" ln -sf "/usr/share/zoneinfo/$BASE_TIMEZONE" /etc/localtime
  else
    warn "Timezone $BASE_TIMEZONE not found; falling back to UTC."
    arch-chroot "$MOUNTPOINT" ln -sf /usr/share/zoneinfo/UTC /etc/localtime
  fi
  arch-chroot "$MOUNTPOINT" hwclock --systohc

  local escaped_locale
  escaped_locale="${BASE_LOCALE//\//\\}"
  arch-chroot "$MOUNTPOINT" bash -c "sed -i 's/^#\(${escaped_locale} UTF-8\)/\1/' /etc/locale.gen || grep -q '^${escaped_locale} UTF-8' /etc/locale.gen || echo '${BASE_LOCALE} UTF-8' >> /etc/locale.gen"
  arch-chroot "$MOUNTPOINT" locale-gen
  echo "LANG=$BASE_LOCALE" >"$MOUNTPOINT/etc/locale.conf"

  echo "$BASE_HOSTNAME" >"$MOUNTPOINT/etc/hostname"
  cat <<EOF >"$MOUNTPOINT/etc/hosts"
127.0.0.1 localhost
::1       localhost
127.0.1.1 $BASE_HOSTNAME.localdomain $BASE_HOSTNAME
EOF

  log "Setting root password..."
  prompt_password BASE_ROOT_PASSWORD "root"
  echo "root:$BASE_ROOT_PASSWORD" | arch-chroot "$MOUNTPOINT" chpasswd

  prompt_username
  log "Creating user $BASE_USERNAME..."
  arch-chroot "$MOUNTPOINT" useradd -m -G wheel,audio,video,storage "$BASE_USERNAME"
  prompt_password BASE_USER_PASSWORD "$BASE_USERNAME"
  echo "$BASE_USERNAME:$BASE_USER_PASSWORD" | arch-chroot "$MOUNTPOINT" chpasswd
  arch-chroot "$MOUNTPOINT" bash -c "sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers"
  BASE_ROOT_PASSWORD=""
  BASE_USER_PASSWORD=""

  log "Enabling NetworkManager..."
  arch-chroot "$MOUNTPOINT" systemctl enable NetworkManager.service

  install_bootloader_in_chroot
}

copy_script_to_new_install() {
  local target_path="$MOUNTPOINT/home/$BASE_USERNAME/arch-amd-gaming-setup.sh"
  install -Dm755 "$SCRIPT_PATH" "$target_path"
  arch-chroot "$MOUNTPOINT" chown "$BASE_USERNAME:$BASE_USERNAME" "/home/$BASE_USERNAME/arch-amd-gaming-setup.sh"
  log "Script copied to $target_path"
}

run_post_install_inside_target() {
  local user_script="/home/$BASE_USERNAME/arch-amd-gaming-setup.sh"
  if [[ ! -f "$MOUNTPOINT$user_script" ]]; then
    warn "Post-install script not found at $user_script; skipping automatic configuration."
    return
  fi

  log "Launching post-install configuration inside the new system..."
  local inner_script="./$(basename "$user_script")"
  local chroot_cmd="cd /home/$BASE_USERNAME && $inner_script --mode postinstall"
  if ! arch-chroot "$MOUNTPOINT" runuser -l "$BASE_USERNAME" -c "$chroot_cmd"; then
    warn "Post-install phase inside target system exited with an error. You can rerun $user_script after reboot."
  else
    log "Post-install configuration inside target system completed."
  fi
}

cleanup_mounts() {
  if mountpoint -q "$MOUNTPOINT/boot" 2>/dev/null; then
    umount "$MOUNTPOINT/boot"
  fi
  if mountpoint -q "$MOUNTPOINT" 2>/dev/null; then
    umount "$MOUNTPOINT"
  fi
}

ensure_live_iso_dependencies() {
  local -a required=(dialog reflector git)
  local -a missing=()
  for pkg in "${required[@]}"; do
    if ! pacman -Qi "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    log "Live ISO dependencies already satisfied (${required[*]})."
    return
  fi

  log "Installing missing live ISO dependencies: ${missing[*]}"
  pacman -Sy --noconfirm
  pacman -S --noconfirm --needed "${missing[@]}"
}

run_full_arch_install() {
  check_base_install_prereqs
  ensure_live_iso_dependencies
  trap cleanup_mounts EXIT
  prompt_hostname
  prompt_timezone
  prompt_locale
  select_install_boot_mode
  select_install_disk
  confirm_disk_wipe
  set_partition_paths
  optimize_mirrors

  partition_disk
  format_and_mount_partitions
  pacstrap_base_system
  install_optional_fwupd_in_chroot
  configure_system_in_chroot
  copy_script_to_new_install
  run_post_install_inside_target
  cleanup_mounts
  trap - EXIT

  cat <<'EOF'

Installation complete!
Next steps:
  • Reboot into the new system.
  • Log in and enjoy your configured desktop + gaming stack.
  • Re-run ~/arch-amd-gaming-setup.sh later if you want to tweak settings again.
EOF
}

select_desktop_environment() {
  if ! prompt_yes_no "Install a desktop environment?" "n"; then
    DESKTOP_CHOICE="skip"
    return
  fi

  local options=(gnome plasma xfce cinnamon skip)
  local labels=(
    "GNOME (Wayland-first, GDM)"
    "KDE Plasma (Wayland/X11, SDDM)"
    "Xfce (Lightweight, LightDM)"
    "Cinnamon (GNOME-based, LightDM)"
    "Skip (already configured)"
  )

  if [[ $UI_MODE == "dialog" ]]; then
    local menu_entries=()
    for i in "${!options[@]}"; do
      menu_entries+=("${options[i]}" "${labels[i]}")
    done
    local selection
    selection=$(dialog --title "$UI_TITLE" --default-item skip --menu "Choose a desktop environment" 20 80 "$UI_MENU_HEIGHT" "${menu_entries[@]}" --stdout) || ui_cancelled
    DESKTOP_CHOICE="$selection"
    return
  fi

  while true; do
    echo "Available desktop environments:"
    for i in "${!options[@]}"; do
      printf '  %d) %s\n' "$((i + 1))" "${labels[i]}"
    done
    read -r -p "Choose an option [1-${#options[@]}] (default: ${#options[@]}): " choice
    choice="${choice:-${#options[@]}}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#options[@]})); then
      DESKTOP_CHOICE="${options[choice-1]}"
      break
    else
      echo "Invalid selection, try again."
    fi
  done
}

install_desktop_environment() {
  local label=""
  local dm_service=""
  local -a packages=()
  local terminal_pkg=""

  case "$DESKTOP_CHOICE" in
    skip|"")
      log "Skipping desktop environment installation."
      return
      ;;
    gnome)
      label="GNOME"
      packages=(gnome gnome-tweaks gnome-shell-extensions gdm power-profiles-daemon)
      dm_service="gdm.service"
      terminal_pkg="gnome-terminal"
      ;;
    plasma)
      label="KDE Plasma"
      packages=(plasma-meta kde-applications sddm sddm-kcm)
      dm_service="sddm.service"
      terminal_pkg="konsole"
      ;;
    xfce)
      label="Xfce"
      packages=(xfce4 xfce4-goodies lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings)
      dm_service="lightdm.service"
      terminal_pkg="xfce4-terminal"
      ;;
    cinnamon)
      label="Cinnamon"
      packages=(cinnamon lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings)
      dm_service="lightdm.service"
      terminal_pkg="gnome-terminal"
      ;;
    *)
      warn "Unknown desktop selection '$DESKTOP_CHOICE'. Skipping."
      return
      ;;
  esac

  if [[ -n "$terminal_pkg" ]]; then
    log "Adding default terminal $terminal_pkg for $label."
    packages+=("$terminal_pkg")
  fi

  install_packages "Installing $label desktop environment..." "${packages[@]}"

  if [[ -n "$dm_service" ]]; then
    log "Enabling display manager $dm_service..."
    run_root_cmd systemctl enable --now "$dm_service"
  fi
}

install_linux_zen() {
  if ! prompt_yes_no "Install linux-zen kernel and headers?" "n"; then
    return
  fi
  install_packages "Installing linux-zen kernel..." linux-zen linux-zen-headers
  if command -v grub-mkconfig >/dev/null 2>&1; then
    log "Updating GRUB configuration..."
    run_root_cmd grub-mkconfig -o /boot/grub/grub.cfg
  else
    warn "Skipped GRUB update (grub-mkconfig not found). Update your bootloader manually."
  fi
}

install_amd_stack() {
  local amd_packages=(
    amd-ucode
    mesa
    lib32-mesa
    libva-mesa-driver
    lib32-libva-mesa-driver
    vulkan-radeon
    lib32-vulkan-radeon
    vulkan-mesa-layers
    lib32-vulkan-mesa-layers
    vulkan-tools
    libdrm
    lib32-libdrm
    xf86-video-amdgpu
  )
  install_packages "Installing AMD GPU stack..." "${amd_packages[@]}"
}

install_gaming_packages() {
  local gaming_packages=(
    steam
    steam-native-runtime
    gamemode
    mangohud
    goverlay
    lutris
    wine
    wine-mono
    wine-gecko
    openxr-loader
    pipewire
    pipewire-alsa
    pipewire-pulse
    pipewire-jack
    qpwgraph
  )
  if [[ $MULTILIB_ENABLED -eq 1 ]]; then
    gaming_packages+=(dxvk-bin)
  else
    warn "Skipping dxvk-bin because multilib is disabled."
  fi
  install_packages "Installing core gaming packages..." "${gaming_packages[@]}"
}

configure_gamemode() {
  if systemctl --user list-unit-files 2>/dev/null | grep -q gamemoded.service; then
    log "Enabling gamemoded user service..."
    systemctl --user enable --now gamemoded.service
  else
    warn "gamemoded user service not found (is gamemode installed?)."
  fi
}

configure_mangohud_defaults() {
  local config_dir="$HOME/.config/MangoHud"
  mkdir -p "$config_dir"
  if [[ ! -f "$config_dir/MangoHud.conf" ]]; then
    cat >"$config_dir/MangoHud.conf" <<'EOF'
# Minimal MangoHud defaults (toggle with F12 by default)
cpu_temp
gpu_temp
gpu_core_clock
gpu_mem_clock
vram
fps
frame_timing
EOF
    log "Created baseline MangoHud configuration at $config_dir/MangoHud.conf"
  else
    log "MangoHud configuration already exists, leaving untouched."
  fi
}

setup_flatpak() {
  if ! prompt_yes_no "Install Flatpak and enable Flathub?" "y"; then
    return
  fi
  install_packages "Installing Flatpak..." flatpak
  if ! flatpak remote-list | grep -q flathub; then
    log "Adding Flathub remote..."
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  fi
}

detect_aur_helper() {
  if command -v paru >/dev/null 2>&1; then
    AUR_HELPER="paru"
    return
  fi
  if command -v yay >/dev/null 2>&1; then
    AUR_HELPER="yay"
    return
  fi
  AUR_HELPER=""
}

ensure_aur_helper_present() {
  detect_aur_helper
  if [[ -n "$AUR_HELPER" ]]; then
    log "Using detected AUR helper: $AUR_HELPER"
    return 0
  fi

  select_aur_helper
  install_selected_aur_helper "$AUR_HELPER_SELECTION"
  detect_aur_helper
  if [[ -z "$AUR_HELPER" ]]; then
    warn "Failed to set up an AUR helper."
    return 1
  fi
  log "AUR helper $AUR_HELPER installed successfully."
  return 0
}

select_aur_helper() {
  local options=(paru yay)
  if [[ $UI_MODE == "dialog" ]]; then
    local menu_entries=()
    for helper in "${options[@]}"; do
      local desc=""
      case "$helper" in
        paru) desc="paru (Rust-based, pacman-like syntax)" ;;
        yay) desc="yay (Go-based helper)" ;;
      esac
      menu_entries+=("$helper" "$desc")
    done
    AUR_HELPER_SELECTION=$(dialog --title "$UI_TITLE" --default-item "$AUR_HELPER_SELECTION" --menu "Choose an AUR helper to install" 15 70 "$UI_MENU_HEIGHT" "${menu_entries[@]}" --stdout) || ui_cancelled
    return
  fi

  echo "Choose an AUR helper to install:"
  local idx=1
  for helper in "${options[@]}"; do
    printf '  %d) %s\n' "$idx" "$helper"
    ((idx++))
  done
  while true; do
    read -r -p "Selection [1-${#options[@]}] (default: 1): " choice
    choice="${choice:-1}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#options[@]})); then
      AUR_HELPER_SELECTION="${options[choice-1]}"
      break
    else
      echo "Invalid selection, try again."
    fi
  done
}

install_selected_aur_helper() {
  local helper="$1"
  install_packages "Installing prerequisites for $helper..." base-devel git
  local temp_dir
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' EXIT
  log "Cloning $helper from AUR..."
  git clone "https://aur.archlinux.org/${helper}.git" "$temp_dir/$helper"
  pushd "$temp_dir/$helper" >/dev/null
  makepkg -si --noconfirm
  popd >/dev/null
  rm -rf "$temp_dir"
  trap - EXIT
}

configure_aur_support() {
  if ! prompt_yes_no "Enable AUR helper support (install helper + optional packages)?" "y"; then
    ENABLE_AUR=0
    warn "AUR support disabled; skipping community utilities."
    if prompt_yes_no "Install an AUR helper anyway for manual use?" "n"; then
      ensure_aur_helper_present || warn "Unable to provision an AUR helper."
    fi
    return
  fi

  ENABLE_AUR=1
  if ! ensure_aur_helper_present; then
    warn "Failed to set up an AUR helper. AUR features will be unavailable."
    ENABLE_AUR=0
  fi
}

install_aur_packages() {
  if [[ $ENABLE_AUR -ne 1 ]]; then
    warn "AUR support not enabled; skipping AUR packages."
    return
  fi

  detect_aur_helper
  if [[ -z "$AUR_HELPER" ]]; then
    warn "No AUR helper available; skipping AUR packages."
    return
  fi

  local aur_packages=(
    heroic-games-launcher-bin
    protonup-qt
  )
  log "Installing AUR gaming utilities via $AUR_HELPER..."
  "$AUR_HELPER" -S "${AUR_FLAGS[@]}" "${aur_packages[@]}"
}

select_aur_kernel_package() {
  local -a kernel_ids=(linux-amd-znver3 linux-ck-zen linux-tkg-bmq custom)
  local -a kernel_desc=(
    "Zen 3 optimized kernel"
    "ck patchset tuned for Zen"
    "linux-tkg with BMQ scheduler"
    "Enter a custom AUR kernel"
  )
  local selection=""

  if [[ $UI_MODE == "dialog" ]]; then
    local -a menu_entries=()
    for i in "${!kernel_ids[@]}"; do
      menu_entries+=("${kernel_ids[i]}" "${kernel_desc[i]}")
    done
    selection=$(dialog --title "$UI_TITLE" --default-item "$AUR_KERNEL_SELECTION" \
      --menu "Choose an AUR kernel to install" 20 80 "$UI_MENU_HEIGHT" "${menu_entries[@]}" --stdout) || ui_cancelled
  else
    echo "Select an AUR kernel to install:"
    for i in "${!kernel_ids[@]}"; do
      printf '  %d) %s - %s\n' "$((i + 1))" "${kernel_ids[i]}" "${kernel_desc[i]}"
    done
    local choice
    local default_choice=1
    read -r -p "Choice [1-${#kernel_ids[@]}] (default: $default_choice): " choice
    choice="${choice:-$default_choice}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#kernel_ids[@]})); then
      selection="${kernel_ids[choice-1]}"
    else
      selection="${kernel_ids[0]}"
    fi
  fi

  if [[ $selection == "custom" ]]; then
    selection=$(prompt_text_input "Enter the exact AUR kernel package name" "$AUR_KERNEL_SELECTION")
  fi

  selection="${selection// /}" # strip spaces
  if [[ -z "$selection" ]]; then
    err "Kernel selection cannot be empty."
    return 1
  fi
  AUR_KERNEL_SELECTION="$selection"
  printf '%s' "$selection"
}

install_aur_kernel_option() {
  if [[ $ENABLE_AUR -ne 1 ]]; then
    return
  fi
  detect_aur_helper
  if [[ -z "$AUR_HELPER" ]]; then
    warn "No AUR helper detected; skipping kernel installation."
    return
  fi
  if ! prompt_yes_no "Install an additional kernel from AUR?" "n"; then
    return
  fi

  local kernel_pkg
  if ! kernel_pkg=$(select_aur_kernel_package); then
    warn "Skipping AUR kernel installation."
    return
  fi

  local -a packages=("$kernel_pkg")
  if [[ "$kernel_pkg" != *-headers ]]; then
    packages+=("${kernel_pkg}-headers")
  fi

  log "Installing AUR kernel (${packages[*]}) via $AUR_HELPER..."
  if ! "$AUR_HELPER" -S "${AUR_FLAGS[@]}" "${packages[@]}"; then
    warn "Failed to install $kernel_pkg from AUR."
    return
  fi

  if command -v grub-mkconfig >/dev/null 2>&1; then
    log "Regenerating GRUB configuration for the new kernel..."
    run_root_cmd grub-mkconfig -o /boot/grub/grub.cfg
  else
    warn "grub-mkconfig not found; update your bootloader manually."
  fi
}

is_gaming_component_selected() {
  local needle="$1"
  local component
  for component in "${GAMING_COMPONENTS_SELECTED[@]}"; do
    if [[ "$component" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

format_validation_line() {
  local label="$1"
  local status="$2"
  local note="$3"
  printf '%-24s %-6s %s' "$label" "$status" "$note"
}

add_validation_result() {
  local -n _lines_ref="$1"
  local label="$2"
  local status="$3"
  local note="$4"
  local -n _ok_ref="$5"
  local -n _warn_ref="$6"
  local -n _fail_ref="$7"
  local -n _info_ref="$8"
  _lines_ref+=("$(format_validation_line "$label" "$status" "$note")")
  case "$status" in
    OK) ((_ok_ref++)) ;;
    WARN) ((_warn_ref++)) ;;
    FAIL) ((_fail_ref++)) ;;
    INFO) ((_info_ref++)) ;;
  esac
}

post_install_validation() {
  local -a validation_lines=()
  local ok=0
  local warn_count=0
  local fail=0
  local info=0
  local status=""
  local note=""

  local user_services_available=0
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl --user status basic.target >/dev/null 2>&1; then
      user_services_available=1
    fi
  fi

  if [[ $INSTALL_GAMING -eq 1 ]]; then
    if is_gaming_component_selected "steam"; then
      if pacman -Qi steam >/dev/null 2>&1; then
        status="OK"; note="steam package installed"
      else
        status="WARN"; note="Install with 'sudo pacman -S steam'"
      fi
      add_validation_result validation_lines "Steam client" "$status" "$note" ok warn_count fail info
    fi

    if is_gaming_component_selected "lutris"; then
      if pacman -Qi lutris >/dev/null 2>&1; then
        status="OK"; note="lutris package installed"
      else
        status="WARN"; note="Install with 'sudo pacman -S lutris'"
      fi
      add_validation_result validation_lines "Lutris" "$status" "$note" ok warn_count fail info
    fi

    if is_gaming_component_selected "wine"; then
      if pacman -Qi wine >/dev/null 2>&1; then
        status="OK"; note="wine package installed"
      else
        status="WARN"; note="Install with 'sudo pacman -S wine'"
      fi
      add_validation_result validation_lines "Wine" "$status" "$note" ok warn_count fail info
    fi

    if is_gaming_component_selected "gamemode"; then
      if command -v gamemoded >/dev/null 2>&1; then
        if (( user_services_available )); then
          if systemctl --user is-active --quiet gamemoded.service >/dev/null 2>&1; then
            status="OK"; note="gamemoded user service active"
          else
            status="WARN"; note="Enable with 'systemctl --user enable --now gamemoded.service'"
          fi
        else
          status="INFO"; note="gamemode installed; user services unavailable in this session"
        fi
      else
        status="WARN"; note="Install with 'sudo pacman -S gamemode'"
      fi
      add_validation_result validation_lines "Gamemode" "$status" "$note" ok warn_count fail info
    fi

    if is_gaming_component_selected "mangohud"; then
      if command -v mangohud >/dev/null 2>&1; then
        status="OK"; note="mangohud binary present"
      else
        status="WARN"; note="Install with 'sudo pacman -S mangohud'"
      fi
      add_validation_result validation_lines "MangoHud" "$status" "$note" ok warn_count fail info
    fi

    if is_gaming_component_selected "pipewire"; then
      if command -v pipewire >/dev/null 2>&1; then
        if (( user_services_available )); then
          if systemctl --user is-active --quiet pipewire.service >/dev/null 2>&1; then
            status="OK"; note="pipewire user service active"
          else
            status="WARN"; note="Start with 'systemctl --user enable --now pipewire.service'"
          fi
        else
          status="INFO"; note="PipeWire installed; user services unavailable in this session"
        fi
      else
        status="WARN"; note="Install with 'sudo pacman -S pipewire pipewire-pulse'"
      fi
      add_validation_result validation_lines "PipeWire" "$status" "$note" ok warn_count fail info
    fi

    if is_gaming_component_selected "dxvk"; then
      if pacman -Qi dxvk-bin >/dev/null 2>&1; then
        status="OK"; note="dxvk-bin package installed"
      else
        status="WARN"; note="Install with 'sudo pacman -S dxvk-bin' after enabling multilib"
      fi
      add_validation_result validation_lines "DXVK" "$status" "$note" ok warn_count fail info
    fi
  fi

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet NetworkManager.service >/dev/null 2>&1; then
      status="OK"; note="NetworkManager service active"
    else
      if systemctl is-enabled --quiet NetworkManager.service >/dev/null 2>&1; then
        status="WARN"; note="Service enabled but inactive; start it with 'sudo systemctl start NetworkManager.service'"
      else
        status="WARN"; note="Enable with 'sudo systemctl enable --now NetworkManager.service'"
      fi
    fi
  else
    status="INFO"; note="systemctl unavailable; skipping NetworkManager check"
  fi
  add_validation_result validation_lines "NetworkManager" "$status" "$note" ok warn_count fail info

  if command -v flatpak >/dev/null 2>&1; then
    local remotes
    remotes=$(flatpak remote-list --columns=name 2>/dev/null || true)
    if grep -Eq '^flathub$' <<<"$remotes"; then
      status="OK"; note="Flathub remote configured"
    else
      status="WARN"; note="Add Flathub via 'flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo'"
    fi
  else
    status="INFO"; note="Flatpak not installed (expected if you skipped that step)"
  fi
  add_validation_result validation_lines "Flatpak/Flathub" "$status" "$note" ok warn_count fail info

  detect_aur_helper
  if [[ -n "$AUR_HELPER" ]]; then
    status="OK"; note="Detected $AUR_HELPER"
  else
    if [[ $ENABLE_AUR -eq 1 ]]; then
      status="WARN"; note="Missing AUR helper; rerun the script to install paru or yay"
    else
      status="INFO"; note="AUR helper not installed (enable AUR support to add one)"
    fi
  fi
  add_validation_result validation_lines "AUR helper" "$status" "$note" ok warn_count fail info

  local report_body="No validation checks were run."
  if ((${#validation_lines[@]} > 0)); then
    report_body=$(printf '%s\n' "${validation_lines[@]}")
  fi
  local totals="Totals: OK=$ok WARN=$warn_count FAIL=$fail INFO=$info"
  local body="Post-install validation results:\n\n${report_body}\n\n${totals}"

  if [[ $UI_MODE == "dialog" ]]; then
    local dialog_height=$((10 + ${#validation_lines[@]}))
    if ((dialog_height < 12)); then
      dialog_height=12
    elif ((dialog_height > 30)); then
      dialog_height=30
    fi
    dialog --title "$UI_TITLE" --msgbox "$body" "$dialog_height" 90 || true
  else
    printf '%s\n' "$body"
  fi
}

post_install_summary() {
  cat <<'EOF'

Setup complete! Recommended next steps:
  • Reboot to use the new kernel/microcode if installed.
  • Launch Steam and enable Proton Experimental under Settings > Steam Play.
  • Run ProtonUp-Qt to install the latest GE-Proton builds.
  • Use MangoHud (F12) and GOverlay to fine-tune overlays.
  • Customize your chosen desktop environment (themes, extensions, panels, etc.).
  • Use your AUR helper to grab any extra community packages you rely on.
EOF
}

run_post_install() {
  check_prereqs
  detect_multilib
  cat <<'EOF'
==============================================
 Arch Linux AMD Gaming Setup
 This script will apply the following:
  • Update system packages
    • (Optional) optimize pacman mirrors via reflector
  • (Optional) enable multilib + install linux-zen
  • (Optional) install a desktop environment + display manager
  • Install AMD GPU drivers and tools
  • Install core gaming stack (Steam, Lutris, Wine, etc.)
  • (Optional) Configure Flatpak + Flathub
  • (Optional) Enable AUR helper + install Heroic/ProtonUp
==============================================
EOF

  if ! prompt_yes_no "Continue?" "y"; then
    echo "Aborted by user."
    exit 0
  fi

  optimize_mirrors
  update_system
  if prompt_yes_no "Install/verify UEFI tooling (grub, efibootmgr, fwupd)?" "y"; then
    ensure_local_uefi_packages
  fi
  configure_bootloader_postinstall
  if prompt_yes_no "Enable multilib repo?" "y"; then
    enable_multilib
  fi
  install_linux_zen
  install_amd_stack
  select_desktop_environment
  install_desktop_environment
  configure_gaming_packages
  if [[ $INSTALL_GAMING -eq 1 ]]; then
    if ensure_multilib_for_gaming; then
      install_gaming_packages
    else
      warn "You can re-run this script later after enabling multilib to install Steam, Lutris, and other gaming tools."
    fi
  else
    warn "Skipping gaming package installation per user selection."
  fi
  configure_gamemode
  configure_mangohud_defaults
  setup_flatpak
  configure_aur_support
  if [[ $ENABLE_AUR -eq 1 ]]; then
    if prompt_yes_no "Install Heroic Launcher + ProtonUp from AUR?" "y"; then
      install_aur_packages
    fi
    install_aur_kernel_option
  else
    warn "Skipping optional Heroic/ProtonUp install because AUR support is disabled."
  fi
  configure_swapfile
  grant_sudo_privileges
  post_install_validation
  post_install_summary
}

main() {
  parse_cli_args "$@"
  detect_timezone_default
  init_ui
  select_run_mode
  if [[ $RUN_MODE == "fullinstall" ]]; then
    run_full_arch_install
  else
    run_post_install
  fi
}

main "$@"

