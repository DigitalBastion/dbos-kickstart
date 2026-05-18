#!/usr/bin/env bash
# Post-install setup for CachyOS + Hyprland: keyring + Git Credential Manager.
set -euo pipefail

HYPR_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprland.conf"
KEYRINGS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/keyrings"
LOGIN_KEYRING="${KEYRINGS_DIR}/login.keyring"

DBUS_EXEC='exec-once = dbus-update-activation-environment --all'
# Full components so the login collection can be used (secrets alone is not enough).
KEYRING_EXEC='exec-once = gnome-keyring-daemon --start --components=pkcs11,secrets,ssh,gpg'

log() { printf '==> %s\n' "$*"; }

hypr_has_line() {
  grep -qF "$1" "$2"
}

hypr_has_keyring_exec() {
  grep -q 'gnome-keyring-daemon --start' "$1"
}

keyring_running() {
  pgrep -f '[g]nome-keyring-daemon' &>/dev/null
}

login_keyring_exists() {
  [[ -f "$LOGIN_KEYRING" ]]
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

configure_pam() {
  local pam_file
  for pam_file in /etc/pam.d/sddm /etc/pam.d/greetd /etc/pam.d/login; do
    [[ -f "$pam_file" ]] || continue
    if grep -q 'pam_gnome_keyring\.so' "$pam_file"; then
      log "PAM keyring already configured in $pam_file"
      return
    fi
  done

  pam_file=/etc/pam.d/sddm
  [[ -f "$pam_file" ]] || pam_file=/etc/pam.d/login
  [[ -f "$pam_file" ]] || return

  log "adding pam_gnome_keyring to $pam_file (log out/in after kickstart)"
  sudo cp -a "$pam_file" "${pam_file}.bak.dbos-kickstart"
  sudo tee -a "$pam_file" >/dev/null <<'EOF'

# dbos-kickstart: create/unlock login keyring at login
auth     optional     pam_gnome_keyring.so
session  optional     pam_gnome_keyring.so auto_start
EOF
}

upgrade_hypr_keyring_line() {
  if grep -q 'gnome-keyring-daemon --start' "$HYPR_CONF" \
    && ! grep -qF 'pkcs11,secrets,ssh,gpg' "$HYPR_CONF"; then
    sed -i 's|--components=secrets|--components=pkcs11,secrets,ssh,gpg|g' "$HYPR_CONF"
    log 'upgraded Hyprland keyring to full components'
  fi
}

configure_hyprland() {
  mkdir -p "$(dirname "$HYPR_CONF")"
  touch "$HYPR_CONF"
  upgrade_hypr_keyring_line

  local -a missing=()
  hypr_has_line "$DBUS_EXEC" "$HYPR_CONF" || missing+=("$DBUS_EXEC")
  if ! hypr_has_keyring_exec "$HYPR_CONF"; then
    missing+=("$KEYRING_EXEC")
  fi

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

enable_keyring_systemd() {
  command -v systemctl >/dev/null || return
  systemctl --user enable --now gnome-keyring-daemon.socket gnome-keyring-daemon.service 2>/dev/null || true
  systemctl --user restart gnome-keyring-daemon.service 2>/dev/null || true
}

start_keyring_session() {
  mkdir -p "$KEYRINGS_DIR"
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

  enable_keyring_systemd

  if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    log 'no DBus session — keyring starts on next Hyprland login'
    return
  fi

  command -v gnome-keyring-daemon >/dev/null || return

  if command -v dbus-update-activation-environment >/dev/null; then
    dbus-update-activation-environment --all
  fi

  eval "$(gnome-keyring-daemon --start --components=pkcs11,secrets,ssh,gpg 2>/dev/null)" || true

  if login_keyring_exists; then
    log 'login keyring file present'
    return
  fi

  if [[ ! -t 0 ]]; then
    log 'login keyring not created yet — log out and back in after kickstart (PAM creates it)'
    return
  fi

  log 'no login keyring yet — enter a password for the new Login keyring (empty = store unencrypted)'
  read -rsp 'Login keyring password: ' kr_pass
  printf '\n'
  printf '%s' "$kr_pass" | gnome-keyring-daemon --unlock
  unset kr_pass

  if login_keyring_exists; then
    log 'created login keyring'
  else
    log 'could not create login keyring — log out and back in'
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

VERIFY_OK=0
VERIFY_FAIL=0

verify_check() {
  local name="$1"
  shift
  if "$@"; then
    printf '  [ok] %s\n' "$name"
    VERIFY_OK=$((VERIFY_OK + 1))
  else
    printf '  [FAIL] %s\n' "$name"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
  fi
}

pam_configured() {
  local pam_file
  for pam_file in /etc/pam.d/sddm /etc/pam.d/greetd /etc/pam.d/login; do
    [[ -f "$pam_file" ]] || continue
    grep -q 'pam_gnome_keyring\.so' "$pam_file" && return 0
  done
  return 1
}

hypr_keyring_full_components() {
  hypr_has_keyring_exec "$HYPR_CONF" && grep -qF 'pkcs11,secrets,ssh,gpg' "$HYPR_CONF"
}

secret_service_ok() {
  command -v secret-tool >/dev/null || return 1
  ! secret-tool lookup foo bar 2>&1 | grep -qi 'not activatable'
}

login_collection_ok() {
  busctl --user tree org.freedesktop.secrets 2>/dev/null \
    | grep -qF '/org/freedesktop/secrets/collection/login'
}

git_config_ok() {
  [[ "$(git config --global --get credential.helper 2>/dev/null)" == 'manager' ]] \
    && [[ "$(git config --global --get credential.credentialStore 2>/dev/null)" == 'secretservice' ]] \
    && [[ "$(git config --global --get credential.guiPrompt 2>/dev/null)" == 'false' ]]
}

verify_setup() {
  VERIFY_OK=0
  VERIFY_FAIL=0

  log 'verification'
  verify_check 'gnome-keyring installed' pacman -Qi gnome-keyring
  verify_check 'libsecret installed' pacman -Qi libsecret
  verify_check 'git-credential-manager installed' pacman -Qi git-credential-manager
  verify_check 'PAM gnome-keyring configured' pam_configured
  verify_check 'Hyprland dbus exec-once' hypr_has_line "$DBUS_EXEC" "$HYPR_CONF"
  verify_check 'Hyprland keyring exec-once (full components)' hypr_keyring_full_components
  verify_check 'git credential helper = manager' git_config_ok
  verify_check 'gnome-keyring process running' keyring_running
  verify_check 'login keyring file exists' login_keyring_exists
  verify_check 'secret service activatable' secret_service_ok
  verify_check 'login secret collection (/collection/login)' login_collection_ok

  printf '\n'
  if ((VERIFY_FAIL == 0)); then
    log "all ${VERIFY_OK} checks passed"
    return 0
  fi

  printf '==> %d passed, %d failed\n' "$VERIFY_OK" "$VERIFY_FAIL"
  if ! login_keyring_exists || ! login_collection_ok; then
    printf '    → log out and back in so PAM unlocks the login keyring\n'
  fi
  if ! keyring_running || ! secret_service_ok; then
    printf '    → ensure Hyprland exec-once lines ran (re-login or reboot)\n'
  fi
  if ! login_collection_ok && login_keyring_exists; then
    printf '    → unlock Login in Seahorse (Passwords and Keys), then re-run this script\n'
  fi
  return 1
}

main() {
  command -v pacman >/dev/null || { printf 'error: pacman not found\n' >&2; exit 1; }
  command -v git >/dev/null || { printf 'error: git not found\n' >&2; exit 1; }

  install_packages
  configure_pam
  configure_hyprland
  start_keyring_session
  configure_git

  if verify_setup; then
    exit 0
  fi
  exit 1
}

main "$@"
