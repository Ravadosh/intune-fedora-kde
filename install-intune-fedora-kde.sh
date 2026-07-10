#!/usr/bin/env bash
#
# install-intune-fedora-kde.sh
#
# Provisions Microsoft Intune Portal on Fedora KDE Plasma.
# Unofficial/community workaround: Microsoft only officially supports
# Ubuntu 24.04/26.04 LTS and RHEL 8/9 with a GNOME session. This script
# reconstructs what that combination provides natively, for Fedora KDE.
#
# Scope: this script takes you from a clean Fedora KDE Plasma install to
# "intune-portal launches and shows the sign-in screen." It deliberately
# stops BEFORE actual sign-in/enrollment — that step touches your org's
# identity tenant and should be a deliberate, approved action, not something
# a provisioning script does unattended.
#
# Tested on: Fedora 44, KDE Plasma (Plasma 6 / ksecretd).
#
# Usage:
#   sudo ./install-intune-fedora-kde.sh
#
set -euo pipefail

LEGACY_LIB_DIR="/opt/intune-legacy-libs"
WORK_DIR="$(mktemp -d /tmp/intune-fedora-kde.XXXXXX)"
FEDORA39_UPDATES="https://archives.fedoraproject.org/pub/archive/fedora/linux/updates/39/Everything/x86_64/Packages"
FEDORA39_RELEASES="https://archives.fedoraproject.org/pub/archive/fedora/linux/releases/39/Everything/x86_64/os/Packages"

log()  { echo -e "\e[1;34m[*]\e[0m $*"; }
ok()   { echo -e "\e[1;32m[OK]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
die()  { echo -e "\e[1;31m[FAIL]\e[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo $0)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ---------------------------------------------------------------------------
log "Step 0 — Microsoft repos"
# ---------------------------------------------------------------------------
# IMPORTANT: dnf5's 'config-manager addrepo --from-repofile=' always writes
# the result to /etc/yum.repos.d/config.repo, regardless of source filename
# or repo ID inside it. Checking for a specific .repo filename here is
# useless (the file we'd be checking for is never the one actually created)
# and re-running the same addrepo command a second time fails because
# config.repo already exists. Check by repo ID via `dnf repolist` instead —
# that's stable across dnf4/dnf5 and across however the file got named.
repo_registered() { dnf repolist --all 2>/dev/null | grep -q "^$1"; }

if repo_registered "microsoft-rhel9.0-prod"; then
  ok "intune-portal repo already configured, skipping."
else
  rpm --import https://packages.microsoft.com/keys/microsoft.asc
  # NOTE: must point at config.repo directly — the bare directory URL
  # returns an HTML index page, which dnf will fail to parse as ini.
  dnf config-manager addrepo \
    --from-repofile=https://packages.microsoft.com/yumrepos/microsoft-rhel9.0-prod/config.repo
  ok "intune-portal repo added."
fi

if repo_registered "microsoft-edge"; then
  ok "Edge repo already configured, skipping."
else
  # dnf5 syntax: '--add-repo' (dnf4) is not recognized and errors with
  # 'Unknown argument "--add-repo"'. dnf5 uses 'addrepo --from-repofile='
  # even for a plain .repo file URL (not just config.repo endpoints).
  dnf config-manager addrepo \
    --from-repofile=https://packages.microsoft.com/yumrepos/edge
  ok "Edge repo added."
fi

# ---------------------------------------------------------------------------
log "Step 1 — Microsoft Edge (auth WebView prerequisite — was previously missing)"
# ---------------------------------------------------------------------------
# intune-portal's sign-in flow hands the actual Entra ID auth screen off to
# Edge's WebView; it does not implement its own web auth. On Microsoft's
# supported platforms (Ubuntu/RHEL base images) Edge is often already present
# or pulled in some other way, so intune-portal's own RPM does NOT declare it
# as a hard dependency. On Fedora, nothing installs it unless we do so
# explicitly here — this was the gap that surfaced on real hardware testing.
if rpm -q microsoft-edge-stable &>/dev/null; then
  ok "Microsoft Edge already installed, skipping."
else
  dnf install -y microsoft-edge-stable
  ok "Microsoft Edge installed."
fi

# ---------------------------------------------------------------------------
log "Step 2 — Legacy WebKit / JavaScriptCore (install-time blocker)"
# ---------------------------------------------------------------------------
# Fedora dropped the WebKitGTK 4.0 branch entirely; nothing on Fedora 44
# provides libwebkit2gtk-4.0.so.37, and dnf will refuse to even install
# intune-portal without it. Force-register the legacy RPMs so dnf's
# solver sees the soname satisfied, without touching real dependencies.
if ldconfig -p | grep -q 'libwebkit2gtk-4.0.so.37'; then
  ok "libwebkit2gtk-4.0.so.37 already present, skipping."
else
  pushd "$WORK_DIR" >/dev/null
  curl -fsSLO "${FEDORA39_UPDATES}/w/webkit2gtk4.0-2.46.3-1.fc39.x86_64.rpm"
  curl -fsSLO "${FEDORA39_UPDATES}/j/javascriptcoregtk4.0-2.46.3-1.fc39.x86_64.rpm"
  rpm -ivh --nodeps ./webkit2gtk4.0-2.46.3-1.fc39.x86_64.rpm \
                     ./javascriptcoregtk4.0-2.46.3-1.fc39.x86_64.rpm
  popd >/dev/null
  ok "Legacy WebKit RPMs registered."
fi

# ---------------------------------------------------------------------------
log "Step 3 — intune-portal"
# ---------------------------------------------------------------------------
if rpm -q intune-portal &>/dev/null; then
  ok "intune-portal already installed, skipping."
else
  dnf install -y intune-portal
  ok "intune-portal installed."
fi

# microsoft-identity-broker: DO NOT trust this landed transitively.
# Previous version of this script assumed intune-portal's dependency graph
# would always pull this in — that held on the test VM but did NOT hold on
# real corporate hardware. Verify explicitly and install directly if absent.
if rpm -q microsoft-identity-broker &>/dev/null; then
  ok "microsoft-identity-broker already installed."
else
  warn "microsoft-identity-broker did not come in as a transitive dependency of intune-portal — installing explicitly."
  dnf install -y microsoft-identity-broker
  ok "microsoft-identity-broker installed explicitly."
fi

if systemctl is-enabled microsoft-identity-broker &>/dev/null; then
  ok "microsoft-identity-broker service already enabled."
else
  systemctl enable --now microsoft-identity-broker
  ok "microsoft-identity-broker service enabled and started."
fi

# SSSD: microsoft-identity-broker's postinstall creates an authselect
# profile and expects SSSD to be present/enabled.
if systemctl is-enabled sssd &>/dev/null; then
  ok "SSSD already enabled."
else
  dnf install -y sssd-common
  systemctl enable --now sssd
  ok "SSSD installed and enabled."
fi

# ---------------------------------------------------------------------------
log "Step 4 — Font/decoder libraries"
# ---------------------------------------------------------------------------
dnf install -y woff2 libmanette
ok "woff2 / libmanette present."

# ---------------------------------------------------------------------------
log "Step 5 — Isolated ICU 73 (symbol lookup fix)"
# ---------------------------------------------------------------------------
# WebKit's JS engine needs exact ICU 73 internal symbols that don't exist
# in Fedora 44's ICU 77+. Extracted in isolation, never exposed globally.
if compgen -G "${LEGACY_LIB_DIR}/libicui18n.so.73*" > /dev/null; then
  ok "ICU 73 shim already present, skipping."
else
  pushd "$WORK_DIR" >/dev/null
  curl -fsSLO "${FEDORA39_RELEASES}/l/libicu-73.2-2.fc39.x86_64.rpm"
  rpm2cpio libicu-73.2-2.fc39.x86_64.rpm | cpio -idm
  mkdir -p "$LEGACY_LIB_DIR"
  cp usr/lib64/libicui18n.so.73* "$LEGACY_LIB_DIR"/
  cp usr/lib64/libicuuc.so.73*   "$LEGACY_LIB_DIR"/
  cp usr/lib64/libicudata.so.73* "$LEGACY_LIB_DIR"/
  popd >/dev/null
  ok "ICU 73 shim installed to ${LEGACY_LIB_DIR}."
fi

# ---------------------------------------------------------------------------
log "Step 6 — Image codec symlinks (version-detected, not hardcoded)"
# ---------------------------------------------------------------------------
link_codec() {
  local base="$1" want_major_minor="$2"
  local target
  target=$(ls /usr/lib64/${base}.so.${want_major_minor}.* 2>/dev/null | head -n1 || true)
  if [[ -z "$target" ]]; then
    warn "No installed ${base}.so.${want_major_minor}.* found — check manually, WebKit may need a different major version than expected."
    return
  fi
  local legacy_name
  case "$base" in
    libjxl)  legacy_name="libjxl.so.0.8" ;;
    libavif) legacy_name="libavif.so.15" ;;
    *) die "Unknown codec base $base" ;;
  esac
  if [[ -e "/usr/lib64/${legacy_name}" ]]; then
    ok "${legacy_name} already linked, skipping."
  else
    ln -s "$target" "/usr/lib64/${legacy_name}"
    ok "Linked ${legacy_name} -> $(basename "$target")"
  fi
}
link_codec libjxl 0.11
link_codec libavif 16
warn "These symlinks assume ABI compatibility across the version jump — the weakest link in this chain. If WebKit segfaults (not a clean symbol-lookup error) rather than launching, suspect this step first."

# ---------------------------------------------------------------------------
log "Step 7 — Verify link resolution"
# ---------------------------------------------------------------------------
MISSING=$(LD_LIBRARY_PATH="$LEGACY_LIB_DIR" ldd /usr/lib64/libwebkit2gtk-4.0.so.37 2>&1 | grep "not found" || true)
MISSING+=$(LD_LIBRARY_PATH="$LEGACY_LIB_DIR" ldd /usr/lib64/libjavascriptcoregtk-4.0.so.18 2>&1 | grep "not found" || true)
if [[ -n "$MISSING" ]]; then
  warn "Unresolved dependencies remain:"
  echo "$MISSING"
  warn "Check 'dnf provides */<libname>' for each — if Fedora still packages it, dnf install it directly; if not, repeat Step 5's extract-to-${LEGACY_LIB_DIR} method."
else
  ok "All WebKit/JavaScriptCore dependencies resolved."
fi

# ---------------------------------------------------------------------------
log "Step 8 — Persistence: alias + desktop launcher"
# ---------------------------------------------------------------------------
LAUNCH_ENV="WEBKIT_DISABLE_DMABUF_RENDERER=1 LD_LIBRARY_PATH=${LEGACY_LIB_DIR}"
# WEBKIT_DISABLE_DMABUF_RENDERER=1: without GPU passthrough, WebKit's DMA-BUF
# renderer fails and retries every frame ("Failed to get GBM device" spam,
# blank/frozen login window). This forces software rendering instead.

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

for rc in "$REAL_HOME/.bashrc" "$REAL_HOME/.zshrc"; do
  [[ -f "$rc" ]] || continue
  if grep -q "^alias intune=" "$rc" 2>/dev/null; then
    ok "Alias already present in $rc"
  else
    echo "alias intune='${LAUNCH_ENV} intune-portal'" >> "$rc"
    ok "Alias added to $rc"
  fi
done

DESKTOP_SRC="/usr/share/applications/intune-portal.desktop"
DESKTOP_DST="$REAL_HOME/.local/share/applications/intune-portal.desktop"
if [[ -f "$DESKTOP_SRC" ]]; then
  mkdir -p "$(dirname "$DESKTOP_DST")"
  sed "s|^Exec=.*|Exec=env ${LAUNCH_ENV} intune-portal|" "$DESKTOP_SRC" > "$DESKTOP_DST"
  chown "$REAL_USER:$REAL_USER" "$DESKTOP_DST"
  ok "Desktop launcher overridden at $DESKTOP_DST"
else
  warn "No system .desktop file found at $DESKTOP_SRC — skipping launcher override, use the shell alias instead."
fi

# ---------------------------------------------------------------------------
log "Done. Provisioning complete through 'launch-ready' state."
# ---------------------------------------------------------------------------
cat <<EOF

Next steps (manual, requires your org's approval — NOT run by this script):

  1. Log in to the KDE session as the end user (not SSH — this needs a
     real graphical session and its D-Bus bus).
  2. Launch via the 'intune' alias (new shell) or the updated desktop icon.
  3. On this Plasma 6 test system, KDE's own ksecretd already owns
     org.freedesktop.secrets (via org.kde.secretservicecompat), so no
     gnome-keyring portal override was needed. Verify this still holds
     on your target image with:

       busctl --user list | grep -i secrets

     If org.freedesktop.secrets is NOT owned on your image, see the
     gnome-keyring portal override in the project README before sign-in.
  4. Sign in with the work/school account and confirm the device reaches
     enrollment/compliance screens without a [4kv4v] error.

This script does not perform sign-in or enrollment.
EOF
