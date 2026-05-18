#!/usr/bin/env bash
# Post-install setup for CachyOS + Hyprland: keyring + Git Credential Manager.
set -euo pipefail

HYPR_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprland.conf"

DBUS_EXEC='exec-once = dbus-update-activation-environment --all'
KEYRING_EXEC='exec-once = gnome-keyring-daemon --start --components=secrets'

log() { printf '==> %s\n' "$*"; }

hypr_has_line() {
  grep -qF "$1" "$2"
}

keyring_running() {
  pgrep -f '[g]nome-keyring-daemon' &>/dev/null
}

install_packages() {
  log 'ensuring gnome-keyring libsecret are installed'
  sudo pacman -S --needed --noconfirm gnome-keyring libsecret

  if pacman -Qi git-credential-manager &>/dev/null; then
    log 'git-credential-manager already installed'
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

  local -a missing=()
  hypr_has_line "$DBUS_EXEC" "$HYPR_CONF" || missing+=("$DBUS_EXEC")
  hypr_has_line "$KEYRING_EXEC" "$HYPR_CONF" || missing+=("$KEYRING_EXEC")

  if ((${#missing[@]} == 0)); then
    log "Hyprland keyring exec-once already in $HYPR_CONF"
    return
  fi

  local tmp
  tmp="$(mktemp)"
  { printf '%s\n' "${missing[@]}"; printf '\n'; cat "$HYPR_CONF"; } >"$tmp"
  mv "$tmp" "$HYPR_CONF"
  log "added ${#missing[@]} exec-once line(s) to $HYPR_CONF"
}

start_keyring_session() {
  if keyring_running; then
    log 'gnome-keyring already running'
    return
  fi

  if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    log 'no DBus session here — keyring will start on next Hyprland login'
    return
  fi

  command -v gnome-keyring-daemon >/dev/null || return

  if command -v dbus-update-activation-environment >/dev/null; then
    dbus-update-activation-environment --all
  fi

  # Export SSH_AUTH_SOCK etc. for this shell; daemon may not show as "gnome-keyring-daemon" in pgrep -x.
  eval "$(gnome-keyring-daemon --start --components=secrets 2>/dev/null)" || true

  if keyring_running; then
    log 'started gnome-keyring in current session'
  else
    log 'could not start keyring in this shell — log out and back in'
  fi
}

configure_git() {
  local current_helper
  current_helper="$(git config --global --get credential.helper 2>/dev/null || true)"

  if [[ "$current_helper" != 'manager' ]]; then
    git config --global --unset-all credential.helper 2>/dev/null || true
    git config --global credential.helper manager
  fi

  if [[ "$(git config --global --get credential.credentialStore 2>/dev/null || true)" != 'secretservice' ]]; then
    git config --global credential.credentialStore secretservice
  fi

  if [[ "$(git config --global --get credential.guiPrompt 2>/dev/null || true)" != 'false' ]]; then
    git config --global credential.guiPrompt false
  fi

  log 'git configured for Git Credential Manager'
}

verify_setup() {
  if keyring_running; then
    log 'gnome-keyring process found'
  else
    printf 'note: no gnome-keyring process yet (re-login if you ran this outside Hyprland)\n'
  fi

  if command -v secret-tool >/dev/null 2>&1; then
    if secret-tool lookup foo bar 2>&1 | grep -qi 'not activatable'; then
      printf 'note: secret service not activatable yet\n'
    else
      log 'secret service is reachable'
    fi
  fi
}

main() {
  command -v pacman >/dev/null || { printf 'error: pacman not found\n' >&2; exit 1; }
  command -v git >/dev/null || { printf 'error: git not found\n' >&2; exit 1; }

  install_packages
  configure_hyprland
  start_keyring_session
  configure_git
  verify_setup

  cat <<'EOF'

Done. If keyring was not started above, log out and back in (or reboot).

Verify:
  pgrep -af gnome-keyring          # comm is truncated; -f matches the full command
  secret-tool lookup foo bar       # should not say "not activatable"

EOF
}

main "$@"
