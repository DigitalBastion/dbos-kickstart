#!/usr/bin/env bash
# Post-install setup for CachyOS + Hyprland: keyring + Git Credential Manager.
set -euo pipefail

HYPR_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprland.conf"

DBUS_EXEC='exec-once = dbus-update-activation-environment --all'
KEYRING_EXEC='exec-once = gnome-keyring-daemon --start --components=secrets'

log() { printf '==> %s\n' "$*"; }

install_packages() {
  log 'installing gnome-keyring libsecret'
  sudo pacman -S --needed --noconfirm gnome-keyring libsecret

  if pacman -Qi git-credential-manager &>/dev/null; then
    return
  fi

  if pacman -Si git-credential-manager &>/dev/null 2>&1; then
    log 'installing git-credential-manager'
    sudo pacman -S --needed --noconfirm git-credential-manager
    return
  fi

  log 'installing git-credential-manager from AUR'
  if command -v yay &>/dev/null; then
    yay -S --needed --noconfirm git-credential-manager
  elif command -v paru &>/dev/null; then
    paru -S --needed --noconfirm git-credential-manager
  else
    printf 'error: install yay or paru for AUR (git-credential-manager)\n' >&2
    exit 1
  fi
}

configure_hyprland() {
  mkdir -p "$(dirname "$HYPR_CONF")"
  touch "$HYPR_CONF"

  if grep -qF 'gnome-keyring-daemon' "$HYPR_CONF"; then
    log "keyring exec-once already in $HYPR_CONF"
    return
  fi

  local tmp
  tmp="$(mktemp)"
  printf '%s\n%s\n\n' "$DBUS_EXEC" "$KEYRING_EXEC" | cat - "$HYPR_CONF" >"$tmp"
  mv "$tmp" "$HYPR_CONF"
  log "prepended keyring exec-once to $HYPR_CONF"
}

configure_git() {
  git config --global --unset-all credential.helper 2>/dev/null || true
  git config --global credential.helper manager
  git config --global credential.credentialStore secretservice
  git config --global credential.guiPrompt false
  log 'git configured for Git Credential Manager'
}

main() {
  command -v pacman >/dev/null || { printf 'error: pacman not found\n' >&2; exit 1; }
  command -v git >/dev/null || { printf 'error: git not found\n' >&2; exit 1; }

  install_packages
  configure_hyprland
  configure_git

  cat <<'EOF'

Done. Log out and back in (or reboot) so Hyprland starts the keyring.

Verify after re-login:
  pgrep -a gnome-keyring-daemon
  secret-tool lookup foo bar    # should not say "not activatable"

EOF
}

main "$@"
