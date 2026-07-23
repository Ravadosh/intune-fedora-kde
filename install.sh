#!/usr/bin/env bash
#
# Intune & Microsoft Edge Setup for Fedora KDE Plasma
# Repo: https://github.com/Ravadosh/intune-fedora-kde
#

set -euo pipefail

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================================"${NC}
echo -e "${BLUE}   Intune & Microsoft Edge Installer for Fedora KDE    "${NC}
echo -e "${BLUE}========================================================"${NC}

# 1. Root check
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[!] Please run this script with sudo or as root.${NC}"
  exit 1
fi

# 2. Detect Package Manager (DNF5 vs DNF4)
if command -v dnf5 &>/dev/null; then
  PKG_MGR="dnf5"
else
  PKG_MGR="dnf"
fi
echo -e "${GREEN}[*] Using package manager: ${PKG_MGR}${NC}"

FEDORA_VER=$(rpm -E %fedora)
echo -e "${GREEN}[*] Target System: Fedora ${FEDORA_VER}${NC}"

# 3. Import Microsoft GPG Keys
echo -e "${GREEN}[1/5] Importing Microsoft GPG Keys...${NC}"
rpm --import https://packages.microsoft.com/keys/microsoft.asc

# 4. Configure Microsoft Repositories
echo -e "${GREEN}[2/5] Configuring Microsoft Edge & RHEL-Prod Repositories...${NC}"

# Edge Repo
tee /etc/yum.repos.d/microsoft-edge.repo > /dev/null << 'EOF'
[microsoft-edge]
name=Microsoft Edge
baseurl=https://packages.microsoft.com/yumrepos/edge/
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF

# Intune Repo (Microsoft hosts intune-portal under the RHEL prod channels)
# Add both Microsoft keys to the gpgkey parameter for RHEL 10
tee /etc/yum.repos.d/microsoft-rhel-prod.repo > /dev/null << 'EOF'
[microsoft-rhel10-prod]
name=Microsoft RHEL 10 Production (Intune)
baseurl=https://packages.microsoft.com/rhel/10/prod/
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
       https://packages.microsoft.com/rhel/10/prod/repodata/repomd.xml.key
EOF

# 5. Refresh Cache
echo -e "${GREEN}[3/5] Refreshing DNF metadata...${NC}"
$PKG_MGR clean all > /dev/null
$PKG_MGR makecache

# 6. Install Java (Fallback for Fedora 44+ Java package renaming)
echo -e "${GREEN}[4/5] Installing OpenJDK...${NC}"
if $PKG_MGR list available java-21-openjdk &>/dev/null; then
  JAVA_PKG="java-21-openjdk"
elif $PKG_MGR list available java-25-openjdk &>/dev/null; then
  JAVA_PKG="java-25-openjdk"
else
  JAVA_PKG="java-latest-openjdk"
fi

echo -e "${GREEN}[5/5] Installing ${JAVA_PKG}, Edge, and Intune...${NC}"
$PKG_MGR install -y \
    "${JAVA_PKG}" \
    gnome-keyring \
    libsecret \
    microsoft-edge-stable \
    intune-portal \
    microsoft-identity-broker

# Disable the RHEL prod repo after install so it doesn't conflict with native Fedora updates
$PKG_MGR config-manager setopt microsoft-rhel-prod.enabled=0 2>/dev/null || $PKG_MGR config-manager --set-disabled microsoft-rhel-prod 2>/dev/null || true

# 7. Enable Background Sync Timers & Services
TARGET_USER=${SUDO_USER:-$USER}
if [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ]; then
  USER_ID=$(id -u "$TARGET_USER")
  echo -e "${GREEN}[*] Enabling Intune systemd user services for ${TARGET_USER}...${NC}"
  
  # Enable Intune background sync timer (if present)
  sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/${USER_ID}" systemctl --user enable intune-agent.timer 2>/dev/null || true
fi

echo -e "${BLUE}========================================================"${NC}
echo -e "${GREEN} Setup Complete!${NC}"
echo -e "${BLUE}========================================================"${NC}
echo "1. Reboot your machine: sudo reboot"
echo "2. Launch 'Microsoft Intune' and sign in."
echo "3. Open 'Microsoft Edge' and log into your work profile."
echo -e "${BLUE}========================================================"${NC}
