#!/usr/bin/env bash
#
# Intune & Microsoft Edge Setup for Fedora KDE Plasma
# Repo: https://github.com/Ravadosh/intune-fedora-kde
#

set -euo pipefail

# Colors for terminal output
RED='\031[0;31m'
GREEN='\032[0;32m'
BLUE='\034[0;34m'
NC='\030[0m' # No Color

echo -e "${BLUE}========================================================"${NC}
echo -e "${BLUE}   Intune & Microsoft Edge Installer for Fedora KDE    "${NC}
echo -e "${BLUE}========================================================"${NC}

# 1. Root check
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[!] Please run this script with sudo or as root.${NC}"
  exit 1
fi

# 2. Detect Package Manager (DNF vs DNF5)
if command -v dnf5 &>/dev/null; then
  PKG_MGR="dnf5"
else
  PKG_MGR="dnf"
fi
echo -e "${GREEN}[*] Using package manager: ${PKG_MGR}${NC}"

# 3. Detect Fedora Version
FEDORA_VER=$(rpm -E %fedora)
echo -e "${GREEN}[*] Detected Fedora release: ${FEDORA_VER}${NC}"

# 4. Enable EPEL & CodeReady/CRB if available (Safe failover)
echo -e "${GREEN}[1/6] Installing EPEL and enabling CRB repository...${NC}"
$PKG_MGR install -y epel-release || true
if [ "$PKG_MGR" = "dnf5" ]; then
  $PKG_MGR config-manager setopt crb.enabled=1 || true
else
  $PKG_MGR config-manager --set-enabled crb || true
fi

# 5. Import Microsoft GPG Keys
echo -e "${GREEN}[2/6] Importing Microsoft GPG Keys...${NC}"
rpm --import https://packages.microsoft.com/keys/microsoft.asc

# Check for version-specific RHEL/Fedora GPG key fallback if needed
if curl -sI "https://packages.microsoft.com/fedora/${FEDORA_VER}/prod/repodata/repomd.xml.key" | grep -q "200 OK"; then
  rpm --import "https://packages.microsoft.com/fedora/${FEDORA_VER}/prod/repodata/repomd.xml.key"
fi

# 6. Configure Repositories
echo -e "${GREEN}[3/6] Setting up Microsoft Repositories...${NC}"

# Edge Repo
tee /etc/yum.repos.d/microsoft-edge.repo > /dev/null << 'EOF'
[microsoft-edge]
name=Microsoft Edge
baseurl=https://packages.microsoft.com/yumrepos/edge/
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF

# Dynamic Fedora Intune Repo
tee /etc/yum.repos.d/microsoft-fedora-prod.repo > /dev/null << EOF
[microsoft-fedora-prod]
name=Microsoft Fedora ${FEDORA_VER} Production
baseurl=https://packages.microsoft.com/fedora/${FEDORA_VER}/prod/
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF

# 7. Refresh Cache & Install
echo -e "${GREEN}[4/6] Refreshing cache and installing packages...${NC}"
$PKG_MGR clean all > /dev/null
$PKG_MGR makecache

echo -e "${GREEN}[5/6] Installing Java 21, KDE Secret Storage, Edge, and Intune...${NC}"
$PKG_MGR install -y \
    java-21-openjdk \
    gnome-keyring \
    libsecret \
    microsoft-edge-stable \
    intune-portal \
    microsoft-identity-broker

# 8. User Service Setup Context (for non-root target user)
TARGET_USER=${SUDO_USER:-$USER}

if [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ]; then
  USER_ID=$(id -u "$TARGET_USER")
  echo -e "${GREEN}[6/6] Enabling Intune systemd user services for user: ${TARGET_USER}...${NC}"
  
  # Enable user services via systemctl within the user's DBus session
  sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/${USER_ID}" systemctl --user enable microsoft-identity-broker.service || true
  sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/${USER_ID}" systemctl --user enable intune-agent.timer || true
fi

echo -e "${BLUE}========================================================"${NC}
echo -e "${GREEN} Setup Complete!${NC}"
echo -e "${BLUE}========================================================"${NC}
echo "RECOMMENDED NEXT STEPS:"
echo "1. Reboot your machine to initialize GNOME Keyring & Identity Broker:"
echo "   sudo reboot"
echo ""
echo "2. Launch 'Microsoft Intune' from your application menu and complete enrollment."
echo "3. Open 'Microsoft Edge' and sign into your work profile."
echo -e "${BLUE}========================================================"${NC}
