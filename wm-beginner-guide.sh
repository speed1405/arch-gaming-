#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -Eeuo pipefail

REQUIRED_PACKAGES=(xorg-server xorg-apps xorg-xinit lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings \
  openbox obconf obmenu-generator nitrogen picom rofi lxappearance tint2 alacritty)

ensure_packages_installed() {
  local missing=()
  local pkg
  local -a install_cmd

  for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! pacman -Qi "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done

  if ((${#missing[@]} == 0)); then
    echo "All prerequisite packages are already installed."
    return
  fi

  echo "Installing prerequisite packages: ${missing[*]}"
  if [[ $EUID -eq 0 ]]; then
    install_cmd=(pacman -S --needed)
  elif command -v sudo >/dev/null 2>&1; then
    install_cmd=(sudo pacman -S --needed)
  else
    echo "sudo is not available; please install the following packages manually: ${missing[*]}"
    return 1
  fi
  "${install_cmd[@]}" "${missing[@]}"
}

PAGE_CMD="cat"
if command -v less >/dev/null 2>&1; then
  PAGE_CMD="less"
fi

pause() {
  read -r -p "Press Enter to continue..." _
}

show_section() {
  local title="$1"
  shift
  local body="$*"
  printf '\n=== %s ===\n\n' "$title"
  printf '%s\n' "$body"
}

run_tutorial() {
  ensure_packages_installed
  pause

  show_section "Purpose" \
"This walkthrough helps absolute beginners install and configure a lightweight window manager. We focus on Openbox on Arch Linux, but the same workflow applies to other window managers." | $PAGE_CMD
  pause

  show_section "Before You Begin" \
    "1. Boot into your Arch Linux system or chroot.
  2. Ensure pacman mirrors are updated: sudo pacman -Syu" | $PAGE_CMD
  pause

  show_section "Install Core Graphics Stack" \
  "To run any graphical session, you need the X.Org display server and a login manager.

  The tutorial has already installed xorg-server, xorg-apps, xorg-xinit, and LightDM for you. If you need to reinstall manually:

  sudo pacman -S xorg-server xorg-apps xorg-xinit
  sudo pacman -S lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings
  sudo systemctl enable lightdm" | $PAGE_CMD
  pause

  show_section "Install Openbox" \
  "Openbox itself installs quickly. Add a few helper tools to smooth the experience.

  The tutorial has already installed openbox, obconf, obmenu-generator, nitrogen, picom, rofi, lxappearance, tint2, and alacritty. Reinstall manually if needed:

  sudo pacman -S openbox obconf obmenu-generator nitrogen picom rofi lxappearance tint2 alacritty

  What each tool does:
- obconf: GUI tool to tweak Openbox themes
- obmenu-generator: auto-builds right-click menus
- nitrogen: sets wallpapers
- picom: compositor for transparency and shadows
- rofi: application launcher
- lxappearance: GTK theme manager" | $PAGE_CMD
  pause

  show_section "Seed Configuration Files" \
"Openbox stores user settings in ~/.config/openbox. Start with the default templates:

mkdir -p ~/.config/openbox
cp /etc/xdg/openbox/{menu.xml,rc.xml,autostart} ~/.config/openbox/

These files control:
- rc.xml: keybinds, window behavior, theme
- menu.xml: right-click menu entries
- autostart: programs that launch with your session (nitrogen, picom, panels)" | $PAGE_CMD
  pause

  show_section "Customize Autostart" \
"Edit ~/.config/openbox/autostart to launch wallpaper, compositor, and panel.

Example starter autostart:

nitrogen --restore &
picom --config ~/.config/picom/picom.conf &
tint2 &

  Tint2 was installed earlier; reinstall manually if you removed it: sudo pacman -S tint2" | $PAGE_CMD
  pause

  show_section "Edit Keybindings" \
"Keybindings live in rc.xml. Open it in your editor (nano, vim, or graphical editors once installed).

For example, to set Super+Enter to open a terminal:

<keybind key=\"W-Return\">
  <action name=\"Execute\">
    <command>alacritty</command>
  </action>
</keybind>

After editing rc.xml, reload Openbox (Super+Shift+R or run openbox --reconfigure) to apply changes." | $PAGE_CMD
  pause

  show_section "Build a Menu" \
"Menu.xml controls the right-click menu. obmenu-generator can create menus that follow your installed apps:

sudo pacman -S obmenu-generator
mkdir -p ~/.config/obmenu-generator
obmenu-generator -p  # generates a Perl config template
obmenu-generator -s  # creates ~/.config/openbox/menu.xml

Rerun obmenu-generator -s whenever you install new desktop apps." | $PAGE_CMD
  pause

  show_section "Quality-of-Life Packages" \
  "Consider adding:
  - kitty (alternative terminal)
- thunar or pcmanfm (file managers)
- gvfs gvfs-smb (network shares in file managers)
- network-manager-applet (system tray controls)
- volumeicon (sound tray control)

  Install with pacman as needed." | $PAGE_CMD
  pause

  show_section "Enable Services" \
"To ensure your desktop is ready after login:

sudo systemctl enable NetworkManager
sudo systemctl enable bluetooth    # only if using Bluetooth
sudo systemctl enable --now upower # useful for laptops

These provide connectivity, device power info, and background services." | $PAGE_CMD
  pause

  show_section "Testing the Session" \
"1. Start your display manager: sudo systemctl start lightdm
2. Log in and pick \"Openbox\" from the session menu.
3. If you prefer starting from the console, add this to ~/.xinitrc:

exec openbox-session

Then run startx." | $PAGE_CMD
  pause

  show_section "Troubleshooting" \
"Common issues:
- Black screen after login: ensure nitrogen restores a wallpaper or set one manually.
- No panel or launcher: confirm tint2/rofi are in autostart or bind rofi to a key.
- Fonts look rough: install ttf-dejavu noto-fonts noto-fonts-emoji.
- Config changes ignored: reload Openbox with openbox --reconfigure.

Check ~/.xsession-errors or journalctl --user -b for clues." | $PAGE_CMD
  pause

  show_section "Next Steps" \
"Experiment with other window managers once you are comfortable:
- i3-gaps or sway (tiling)
- bspwm with sxhkd (binary space partitioning)
- awesome or qtile (lua/python scripted)

For each, repeat the same pattern: install packages, copy default configs, adjust keybindings, enable your login manager." | $PAGE_CMD
  pause

  show_section "Resources" \
"Documentation worth bookmarking:
- Arch Wiki: https://wiki.archlinux.org/title/Openbox
- Arch Wiki: https://wiki.archlinux.org/title/Window_manager
- Project sites: https://openbox.org, https://github.com/davatorium/rofi

Repeat the tutorial whenever you need a refresher." | $PAGE_CMD
}

run_tutorial
