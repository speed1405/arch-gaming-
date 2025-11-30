#!/usr/bin/env bash
set -Eeuo pipefail

PACMAN_FLAGS=(--needed --noconfirm)
AUR_FLAGS=(--needed --noconfirm)
AUR_HELPER=""
AUR_HELPER_SELECTION="paru"
MULTILIB_ENABLED=0
DESKTOP_CHOICE="skip"
ENABLE_AUR=0
OPTIMIZE_MIRRORS=0
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

log() {
  printf '[+] %s\n' "$1"
}

warn() {
  printf '[!] %s\n' "$1"
}

err() {
  printf '[x] %s\n' "$1" >&2
}

ui_cancelled() {
  err "Operation cancelled by user."
  exit 1
}

init_ui() {
  if command -v whiptail >/dev/null 2>&1 && [[ -t 1 ]]; then
    UI_MODE="whiptail"
  else
    if ! command -v whiptail >/dev/null 2>&1; then
      warn "whiptail not found; falling back to basic text prompts."
    else
      warn "TTY not detected for whiptail; using basic text prompts."
    fi
    UI_MODE="text"
  fi
}

detect_current_boot_mode() {
  if [[ -d /sys/firmware/efi ]]; then
    echo "uefi"
  else
    echo "bios"
  fi
}

select_install_boot_mode() {
  local detected
  detected=$(detect_current_boot_mode)
  local prompt="Select boot mode for GRUB installation"
  local default_choice="$detected"
  local selection=""

  if [[ $UI_MODE == "whiptail" ]]; then
    selection=$(whiptail --title "$UI_TITLE" --default-item "$default_choice" --menu "$prompt" 15 70 "$UI_MENU_HEIGHT" \
      "uefi" "UEFI (GPT + EFI system partition)" \
      "bios" "Legacy BIOS (GPT + bios_grub partition)" 3>&1 1>&2 2>&3) || ui_cancelled
  else
    echo "$prompt"
    echo "  1) UEFI (recommended when firmware supports it)"
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

  BOOT_MODE="$selection"
  if [[ $BOOT_MODE == "uefi" && $detected != "uefi" ]]; then
    warn "System was booted in BIOS mode; ensure firmware actually supports UEFI before proceeding."
  fi
  if [[ $BOOT_MODE == "bios" && $detected == "uefi" ]]; then
    warn "Legacy BIOS mode selected even though UEFI is available."
  fi
}

prompt_text_input() {
  local prompt="$1"
  local default_value="${2-}"
  local result=""
  if [[ $UI_MODE == "whiptail" ]]; then
    result=$(whiptail --title "$UI_TITLE" --inputbox "$prompt" "$UI_BOX_HEIGHT" "$UI_BOX_WIDTH" "$default_value" 3>&1 1>&2 2>&3) || ui_cancelled
  else
    if [[ -n "$default_value" ]]; then
      read -r -p "$prompt (default: $default_value): " result
      result="${result:-$default_value}"
    else
      read -r -p "$prompt: " result
    fi
  fi
  printf '%s' "$result"
}

prompt_secret_input() {
  local prompt="$1"
  local result=""
  if [[ $UI_MODE == "whiptail" ]]; then
    result=$(whiptail --title "$UI_TITLE" --passwordbox "$prompt" "$UI_BOX_HEIGHT" "$UI_BOX_WIDTH" 3>&1 1>&2 2>&3) || ui_cancelled
  else
    read -rs -p "$prompt" result
    echo
  fi
  printf '%s' "$result"
}

run_root_cmd() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  if [[ $UI_MODE == "whiptail" ]]; then
    local -a cmd=(whiptail --title "$UI_TITLE")
    if [[ ${default,,} != y* ]]; then
      cmd+=(--defaultno)
    fi
    cmd+=(--yesno "$prompt" "$UI_BOX_HEIGHT" "$UI_BOX_WIDTH")
    if "${cmd[@]}"; then
      return 0
    else
      return 1
    fi
  fi

  local answer
  while true; do
    read -r -p "$prompt [y/n] (default: $default): " answer
    answer="${answer:-$default}"
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

require_command() {
  local cmd="$1"
  local msg="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "$msg"
    exit 1
  fi
}

install_packages() {
  local message="$1"
  shift
  local packages=("$@")
  log "$message"
  run_root_cmd pacman -S "${PACMAN_FLAGS[@]}" "${packages[@]}"
}

check_prereqs() {
  if [[ $EUID -eq 0 ]]; then
    err "Run this script as a regular user with sudo rights."
    exit 1
  fi
  require_command sudo "This script needs sudo. Install sudo and configure your user."
  require_command pacman "This script is designed for Arch Linux."
}

detect_multilib() {
  if grep -Eq '^\s*\[multilib\]' /etc/pacman.conf; then
    MULTILIB_ENABLED=1
  fi
}

update_system() {
  log "Syncing package databases and updating system..."
  run_root_cmd pacman -Syu --noconfirm
}

enable_multilib() {
  local conf="/etc/pacman.conf"
  if grep -Eq '^\s*\[multilib\]' "$conf"; then
    log "Multilib repository already enabled."
    MULTILIB_ENABLED=1
    return
  fi

  log "Enabling multilib repository..."
  run_root_cmd cp "$conf" "${conf}.bak.$(date +%Y%m%d%H%M%S)"
  if grep -Eq '^\s*#\s*\[multilib\]' "$conf"; then
    run_root_cmd sed -i '/^\s*#\s*\[multilib\]/,/Include/s/^#\s*//' "$conf"
  else
    printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' | run_root_cmd tee -a "$conf" >/dev/null
  fi
  run_root_cmd pacman -Sy
  MULTILIB_ENABLED=1
}

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

  if [[ $UI_MODE == "whiptail" ]]; then
    selection=$(whiptail --title "$UI_TITLE" --default-item "$default_choice" --menu "$prompt" 15 70 "$UI_MENU_HEIGHT" \
      "uefi" "UEFI system" \
      "bios" "Legacy BIOS" 3>&1 1>&2 2>&3) || ui_cancelled
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
  local labels=(
    "Post-install gaming setup (existing Arch system)"
    "Full Arch install (UEFI or BIOS, single disk)"
  )
  local values=(postinstall fullinstall)

  if [[ $UI_MODE == "whiptail" ]]; then
    local menu_entries=()
    for i in "${!values[@]}"; do
      menu_entries+=("${values[i]}" "${labels[i]}")
    done
    local selection
    selection=$(whiptail --title "$UI_TITLE" --menu "Select operating mode" 20 80 "$UI_MENU_HEIGHT" "${menu_entries[@]}" 3>&1 1>&2 2>&3) || ui_cancelled
    RUN_MODE="$selection"
    return
  fi

  echo "Select operating mode:"
  for i in "${!labels[@]}"; do
    printf '  %d) %s\n' "$((i + 1))" "${labels[i]}"
  done
  while true; do
    read -r -p "Mode [1-${#labels[@]}] (default: 1): " choice
    choice="${choice:-1}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#labels[@]})); then
      RUN_MODE="${values[choice-1]}"
      break
    fi
    echo "Invalid selection, try again."
  done
}

check_base_install_prereqs() {
  if [[ $EUID -ne 0 ]]; then
    err "Full install mode must run as root from the Arch ISO."
    exit 1
  fi
  local required=(lsblk sgdisk mkfs.fat mkfs.ext4 pacstrap arch-chroot)
  for cmd in "${required[@]}"; do
    require_command "$cmd" "Required command '$cmd' not found in live environment."
  done
  local detected
  detected=$(detect_current_boot_mode)
  log "Live environment boot mode detected: ${detected^^}."
}

prompt_hostname() {
  local input
  while true; do
    input=$(prompt_text_input "Hostname" "$BASE_HOSTNAME")
    if [[ -n "$input" ]]; then
      BASE_HOSTNAME="$input"
      break
    fi
    echo "Hostname cannot be empty."
  done
}

prompt_username() {
  local input
  while true; do
    input=$(prompt_text_input "Primary username" "$BASE_USERNAME")
    if [[ "$input" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
      BASE_USERNAME="$input"
      break
    fi
    echo "Invalid username. Use lowercase letters, numbers, dash or underscore."
  done
}

prompt_timezone() {
  local input
  input=$(prompt_text_input "Timezone (Region/City)" "$BASE_TIMEZONE")
  BASE_TIMEZONE="$input"
}

prompt_locale() {
  local input
  input=$(prompt_text_input "Locale" "$BASE_LOCALE")
  BASE_LOCALE="$input"
}

prompt_password() {
  local var_name="$1"
  local label="$2"
  local pass1 pass2
  while true; do
    pass1=$(prompt_secret_input "Enter $label password")
    pass2=$(prompt_secret_input "Confirm $label password")
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

  if [[ $UI_MODE == "whiptail" ]]; then
    local menu_entries=()
    for entry in "${user_entries[@]}"; do
      local name="${entry%%:*}"
      local home="${entry#*:}"
      menu_entries+=("$name" "$home")
    done
    local selection
    selection=$(whiptail --title "$UI_TITLE" --menu "Select user to grant sudo" 20 80 "$UI_MENU_HEIGHT" "${menu_entries[@]}" 3>&1 1>&2 2>&3) || ui_cancelled
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

  if [[ $UI_MODE == "whiptail" ]]; then
    local menu_entries=()
    for entry in "${disk_entries[@]}"; do
      local name="${entry%% *}"
      local size="${entry#* }"
      menu_entries+=("$name" "$size")
    done
    local selection
    selection=$(whiptail --title "$UI_TITLE" --menu "$prompt" 20 80 "$UI_MENU_HEIGHT" "${menu_entries[@]}" 3>&1 1>&2 2>&3) || ui_cancelled
    printf '%s' "$selection"
    return
  fi

  echo "Available disks:"
  for i in "${!disk_entries[@]}"; do
    local entry name size
    entry="${disk_entries[i]}"
    name="${entry%% *}"
    size="${entry#* }"
    printf '  %d) %s (%s)\n' "$((i + 1))" "$name" "$size"
  done

  local choice
  while true; do
    read -r -p "$prompt [1-${#disk_entries[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#disk_entries[@]})); then
      printf '%s' "${disk_entries[choice-1]%% *}"
      return
    fi
    echo "Invalid selection, try again."
  done
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

cleanup_mounts() {
  if mountpoint -q "$MOUNTPOINT/boot" 2>/dev/null; then
    umount "$MOUNTPOINT/boot"
  fi
  if mountpoint -q "$MOUNTPOINT" 2>/dev/null; then
    umount "$MOUNTPOINT"
  fi
}

run_full_arch_install() {
  check_base_install_prereqs
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
  cleanup_mounts
  trap - EXIT

  cat <<'EOF'

Base installation complete!
Next steps:
  • Reboot into the new system.
  • Log in as the user you created.
  • Re-run this script (already copied to ~/arch-amd-gaming-setup.sh) and choose "Post-install" to set up AMD gaming packages.
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

  if [[ $UI_MODE == "whiptail" ]]; then
    local menu_entries=()
    for i in "${!options[@]}"; do
      menu_entries+=("${options[i]}" "${labels[i]}")
    done
    local selection
    selection=$(whiptail --title "$UI_TITLE" --default-item skip --menu "Choose a desktop environment" 20 80 "$UI_MENU_HEIGHT" "${menu_entries[@]}" 3>&1 1>&2 2>&3) || ui_cancelled
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

  case "$DESKTOP_CHOICE" in
    skip|"")
      log "Skipping desktop environment installation."
      return
      ;;
    gnome)
      label="GNOME"
      packages=(gnome gnome-tweaks gnome-shell-extensions gdm power-profiles-daemon)
      dm_service="gdm.service"
      ;;
    plasma)
      label="KDE Plasma"
      packages=(plasma-meta kde-applications sddm sddm-kcm)
      dm_service="sddm.service"
      ;;
    xfce)
      label="Xfce"
      packages=(xfce4 xfce4-goodies lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings)
      dm_service="lightdm.service"
      ;;
    cinnamon)
      label="Cinnamon"
      packages=(cinnamon lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings)
      dm_service="lightdm.service"
      ;;
    *)
      warn "Unknown desktop selection '$DESKTOP_CHOICE'. Skipping."
      return
      ;;
  esac

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

select_aur_helper() {
  local options=(paru yay)
  if [[ $UI_MODE == "whiptail" ]]; then
    local menu_entries=()
    for helper in "${options[@]}"; do
      local desc=""
      case "$helper" in
        paru) desc="paru (Rust-based, pacman-like syntax)" ;;
        yay) desc="yay (Go-based helper)" ;;
      esac
      menu_entries+=("$helper" "$desc")
    done
    AUR_HELPER_SELECTION=$(whiptail --title "$UI_TITLE" --default-item "$AUR_HELPER_SELECTION" --menu "Choose an AUR helper to install" 15 70 "$UI_MENU_HEIGHT" "${menu_entries[@]}" 3>&1 1>&2 2>&3) || ui_cancelled
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
  if ! prompt_yes_no "Enable AUR helper support?" "y"; then
    ENABLE_AUR=0
    warn "AUR support disabled; skipping community utilities."
    return
  fi

  ENABLE_AUR=1
  detect_aur_helper
  if [[ -n "$AUR_HELPER" ]]; then
    log "Using detected AUR helper: $AUR_HELPER"
    return
  fi

  select_aur_helper
  install_selected_aur_helper "$AUR_HELPER_SELECTION"
  detect_aur_helper
  if [[ -z "$AUR_HELPER" ]]; then
    warn "Failed to set up an AUR helper. AUR features will be unavailable."
    ENABLE_AUR=0
  else
    log "AUR helper $AUR_HELPER installed successfully."
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
  install_gaming_packages
  configure_gamemode
  configure_mangohud_defaults
  setup_flatpak
  configure_aur_support
  if [[ $ENABLE_AUR -eq 1 ]]; then
    if prompt_yes_no "Install Heroic Launcher + ProtonUp from AUR?" "y"; then
      install_aur_packages
    fi
  else
    warn "Skipping optional Heroic/ProtonUp install because AUR support is disabled."
  fi
  grant_sudo_privileges
  post_install_summary
}

main() {
  init_ui
  select_run_mode
  if [[ $RUN_MODE == "fullinstall" ]]; then
    run_full_arch_install
  else
    run_post_install
  fi
}

main "$@"

