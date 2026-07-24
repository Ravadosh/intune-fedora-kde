#!/usr/bin/env bash
#
# enforce-gnome-keyring.sh
#
# Run this ONCE, right after the base Fedora Workstation (GNOME) install,
# BEFORE installing any KDE workspace packages.
#
# Purpose: guarantee gnome-keyring stays the org.freedesktop.secrets
# provider even after KDE Plasma is layered on top later. Without this,
# KDE's ksecretd wins the Secret Service portal backend by default in a
# KDE session, which breaks intune-portal's token/enrollment storage.
#
# Root cause confirmed via testing: the conflict is NOT a plain D-Bus
# service-file activation race (org.freedesktop.secrets.service) — it's
# the xdg-desktop-portal Secret interface, which in a KDE session
# defaults to routing through org.freedesktop.impl.portal.desktop.kwallet.
# That backend, once spawned, also grabs org.freedesktop.secrets directly.
# The fix is telling the portal to prefer gnome-keyring's backend instead.
#
# This script:
#   1. Confirms gnome-keyring is installed and running.
#   2. Installs xdg-desktop-portal-gtk (provides the gnome-keyring portal backend).
#   3. Writes a portal config forcing Secret -> gnome-keyring, for both
#      GNOME and (pre-emptively, for when it's installed later) KDE sessions.
#   4. Plants a D-Bus service-file override as defense-in-depth (harmless,
#      not the primary fix, but costs nothing and covers the plain
#      lazy-activation case too).
#   5. Optionally (--disable-kwallet flag) disables KWallet's own Secret
#      Service participation at the config level, as a blunter fallback —
#      NOT applied by default, since the portal fix alone was sufficient
#      in testing.
#
# Usage:
#   sudo ./enforce-gnome-keyring.sh                  # portal fix only (recommended default)
#   sudo ./enforce-gnome-keyring.sh --disable-kwallet # also disables kwallet as backup
#
set -euo pipefail

DISABLE_KWALLET=false
for arg in "$@"; do
    case "$arg" in
        --disable-kwallet) DISABLE_KWALLET=true ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

log()  { echo -e "\e[1;34m[*]\e[0m $*"; }
ok()   { echo -e "\e[1;32m[OK]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
die()  { echo -e "\e[1;31m[FAIL]\e[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo $0)"

REAL_USER="${SUDO_USER:-$USER}"
[[ "$REAL_USER" != "root" ]] || warn "Running as literal root user, not via sudo — session-level checks below will be less meaningful."

# ---------------------------------------------------------------------------
log "1/5 — Confirm gnome-keyring present"
# ---------------------------------------------------------------------------
rpm -q gnome-keyring &>/dev/null || dnf install -y gnome-keyring
ok "gnome-keyring package present."

# ---------------------------------------------------------------------------
log "2/5 — Install xdg-desktop-portal-gtk (gnome-keyring's portal backend)"
# ---------------------------------------------------------------------------
rpm -q xdg-desktop-portal-gtk &>/dev/null || dnf install -y xdg-desktop-portal-gtk
ok "xdg-desktop-portal-gtk present."

# ---------------------------------------------------------------------------
log "3/5 — Portal config: force Secret interface to gnome-keyring"
# ---------------------------------------------------------------------------
# Written for both possible session portal configs. The kde-portals.conf
# file has no effect until KDE's portal backend is actually installed,
# but writing it now means it's already in place by the time that happens.
install -d -m 0755 /etc/xdg/xdg-desktop-portal

for conf in gnome-portals.conf kde-portals.conf; do
    target="/etc/xdg/xdg-desktop-portal/${conf}"
    default_backend="gnome"
    [[ "$conf" == "kde-portals.conf" ]] && default_backend="kde"

    if [[ -f "$target" ]] && grep -q "^org.freedesktop.impl.portal.Secret=gnome-keyring" "$target"; then
        ok "${conf} already configured, skipping."
        continue
    fi

    tee "$target" > /dev/null << EOF
[preferred]
default=${default_backend}
org.freedesktop.impl.portal.Secret=gnome-keyring
EOF
    ok "Wrote ${target}"
done

# ---------------------------------------------------------------------------
log "4/5 — D-Bus service-file override (defense-in-depth, plain activation case)"
# ---------------------------------------------------------------------------
# Belt-and-suspenders: covers the case where something requests
# org.freedesktop.secrets directly via lazy D-Bus activation rather than
# through the portal. Not the primary fix (testing showed the portal
# config above was what actually mattered), but harmless to have.
OVERRIDE_DIR="/usr/local/share/dbus-1/services"
OVERRIDE_FILE="${OVERRIDE_DIR}/org.freedesktop.secrets.service"
if [[ -f "$OVERRIDE_FILE" ]]; then
    ok "D-Bus override already present, skipping."
else
    install -d -m 0755 "$OVERRIDE_DIR"
    tee "$OVERRIDE_FILE" > /dev/null << 'EOF'
[D-BUS Service]
Name=org.freedesktop.secrets
Exec=/usr/bin/gnome-keyring-daemon --start --foreground --components=secrets
EOF
    ok "Wrote ${OVERRIDE_FILE}"
fi

# ---------------------------------------------------------------------------
log "5/5 — Optional: disable KWallet's Secret Service participation"
# ---------------------------------------------------------------------------
if $DISABLE_KWALLET; then
    USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
    if command -v kwriteconfig6 &>/dev/null; then
        sudo -u "$REAL_USER" kwriteconfig6 --file kwalletrc --group Wallet --key "Enabled" false
        ok "kwalletrc Enabled=false set for ${REAL_USER} (kwriteconfig6 not present yet if KDE isn't installed — safe to re-run this flag later once it is)."
    else
        warn "kwriteconfig6 not found (KDE likely not installed yet). Re-run this script with --disable-kwallet after KDE is installed if you want this fallback applied."
    fi
else
    log "Skipping KWallet disable (not requested). Portal config above was sufficient in testing."
fi

# ---------------------------------------------------------------------------
cat <<EOF

Done. Verification (after a fresh login, not just this shell):

  busctl --user list | grep -i secrets
      -> should show gnome-keyring-daemon, not ksecretd

  gdbus introspect --session --dest org.freedesktop.secrets \\
      --object-path /org/freedesktop/secrets
      -> should return a method/property listing, not an error

Run this BEFORE installing KDE workspaces:
  sudo dnf environment install kde-desktop-environment

Then reboot into the KDE session specifically and re-run the two
verification commands above. If ksecretd still wins after KDE is
installed, re-run this script with --disable-kwallet.
EOF
