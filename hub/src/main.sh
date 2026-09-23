#!/bin/bash
set -euo pipefail

# Shared interactive helpers
# @include shared/ask_yes_no.sh
# @include shared/ask_value.sh
# @include modules/systemd.sh


# Parse command line flags
ASSUME_YES=false
for arg in "$@"; do
  case $arg in
    -y|--yes)
      ASSUME_YES=true
      shift
      ;;
  esac
done

# Ensure running as root
if [ "$(id -u)" -ne 0 ]; then
  echo "Error: Run this script with sudo." >&2
  exit 1
fi

echo "=== HSS Central Audio Hub Interactive Setup ==="
echo

# Gather configuration parameters upfront
NEW_HOSTNAME=$(ask_value "Enter the desired hostname" "hss")
HOTSPOT_SSID=$(ask_value "Enter the SSID for the setup hotspot" "HSS-Setup")

echo
if ask_yes_no "Install CPU optimizations and power-saving measures?"; then
  INSTALL_CPU_OPT=true
else
  INSTALL_CPU_OPT=false
fi

if ask_yes_no "Install the Snapweb web interface?"; then
  INSTALL_SNAPWEB=true
  SNAPWEB_PORT=$(ask_value "Enter the port for the Snapweb interface" "1780")
else
  INSTALL_SNAPWEB=false
  SNAPWEB_PORT="1780"
fi

if ask_yes_no "Install potentiometer volume control (ADS1015/1115)?"; then
  INSTALL_POTI=true
else
  INSTALL_POTI=false
fi

echo
echo "=== Starting installation with your configuration ==="
echo

POT_SERVICE_PATH="/usr/local/bin/hss_volume_control.py"
PORTAL_SCRIPT_PATH="/usr/local/bin/hss_wifi_portal.py"
LIBRESPOT_PATH="/usr/local/bin/librespot"
SNAPWEB_ROOT="/var/www/snapweb"

install_librespot() {
  echo "Installing the latest Librespot release..."

  local architecture asset_url release_json
  case "$(uname -m)" in
    aarch64) architecture="aarch64|arm64" ;;
    armv7l|armv7) architecture="armv7|armhf|arm-unknown" ;;
    armv6l|armv6) architecture="armv6|arm-unknown" ;;
    x86_64) architecture="x86_64" ;;
    *)
      echo "Error: Unsupported CPU architecture for Librespot: $(uname -m)" >&2
      exit 1
      ;;
  esac

  release_json=$(mktemp)
  trap 'rm -f "$release_json"' RETURN
  curl --fail --silent --show-error --location \
    https://api.github.com/repos/librespot-org/librespot/releases/latest \
    -o "$release_json"

  asset_url=$(python3 - "$release_json" "$architecture" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as release_file:
    release = json.load(release_file)

architecture_patterns = sys.argv[2].split("|")
for asset in release.get("assets", []):
    name = asset.get("name", "").lower()
    if any(re.search(pattern, name) for pattern in architecture_patterns) and ("linux" in name or "gnu" in name):
        print(asset["browser_download_url"])
        break
PY
)

  if [ -z "$asset_url" ]; then
    echo "Error: The latest Librespot release has no pre-compiled Linux ${architecture} binary." >&2
    echo "       Check https://github.com/librespot-org/librespot/releases for a compatible release asset." >&2
    exit 1
  fi

  curl --fail --silent --show-error --location "$asset_url" -o "$LIBRESPOT_PATH"
  chmod 755 "$LIBRESPOT_PATH"
  if ! id librespot >/dev/null 2>&1; then
    useradd --system --home-dir /var/lib/librespot --create-home --shell /usr/sbin/nologin librespot
  fi
  chown librespot:librespot "$LIBRESPOT_PATH"
}

install_snapweb() {
  echo "Installing the latest Snapweb release..."

  local snapweb_archive
  snapweb_archive=$(mktemp --suffix=.zip)
  trap 'rm -f "$snapweb_archive"' RETURN
  curl --fail --silent --show-error --location \
    https://github.com/snapcast/snapweb/releases/latest/download/snapweb.zip \
    -o "$snapweb_archive"

  rm -rf "$SNAPWEB_ROOT"
  mkdir -p "$SNAPWEB_ROOT"
  unzip -q "$snapweb_archive" -d "$SNAPWEB_ROOT"

  # Releases may contain a top-level directory; flatten it when appropriate.
  if [ ! -f "$SNAPWEB_ROOT/index.html" ]; then
    local web_root
    web_root=$(find "$SNAPWEB_ROOT" -mindepth 2 -maxdepth 2 -name index.html -print -quit | xargs -r dirname)
    if [ -n "$web_root" ]; then
      cp -a "$web_root"/. "$SNAPWEB_ROOT"/
      rm -rf "$web_root"
    fi
  fi

  chown -R root:root "$SNAPWEB_ROOT"
  find "$SNAPWEB_ROOT" -type d -exec chmod 755 {} +
  find "$SNAPWEB_ROOT" -type f -exec chmod 644 {} +
}

# 1. Update system and install required base packages
echo "[1/7] Updating system and installing base packages..."
apt update && apt upgrade -y

BASE_PACKAGES="snapserver avahi-daemon ssh python3 python3-pip git alsa-utils network-manager shairport-sync curl unzip"
if [ "$INSTALL_POTI" = true ]; then
  BASE_PACKAGES="$BASE_PACKAGES i2c-tools"
fi

apt install -y $BASE_PACKAGES
install_librespot
if [ "$INSTALL_SNAPWEB" = true ]; then
  install_snapweb
fi

# 2. Configure Hostname
echo "[2/7] Setting system hostname to '${NEW_HOSTNAME}'..."
hostnamectl set-hostname "$NEW_HOSTNAME"
if grep -q "127.0.1.1" /etc/hosts; then
  sed -i "s/127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME/g" /etc/hosts
else
  echo -e "127.0.1.1\t$NEW_HOSTNAME" >> /etc/hosts
fi
systemctl restart avahi-daemon

# 3. CPU and Performance Optimizations (Optional)
if [ "$INSTALL_CPU_OPT" = true ]; then
  echo "[3/7] Applying energy-saving and performance tweaks..."

  # Disable Swap
  dphys-swapfile swapoff 2>/dev/null || true
  dphys-swapfile uninstall 2>/dev/null || true
  systemctl disable dphys-swapfile.service 2>/dev/null || true
  systemctl mask dphys-swapfile.service 2>/dev/null || true

  # Disable background services
  systemctl disable --now ModemManager.service 2>/dev/null || true
  systemctl mask ModemManager.service 2>/dev/null || true
  systemctl disable --now triggerhappy.service 2>/dev/null || true
  systemctl mask triggerhappy.service 2>/dev/null || true
  systemctl disable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

  # Disable Bluetooth in boot configuration
  CONFIG_FILE="/boot/firmware/config.txt"
  if [ ! -f "$CONFIG_FILE" ]; then
    CONFIG_FILE="/boot/config.txt"
  fi

  if [ -f "$CONFIG_FILE" ]; then
    grep -q "dtoverlay=disable-bt" "$CONFIG_FILE" || echo "dtoverlay=disable-bt" >> "$CONFIG_FILE"
  fi
  systemctl disable --now bluetooth.service hciuart.service 2>/dev/null || true
  systemctl mask bluetooth.service hciuart.service 2>/dev/null || true

  # Turn off HDMI on boot
  # @embed_file services/hdmi-off.service /etc/systemd/system/hdmi-off.service

  systemctl daemon-reload
  systemctl enable hdmi-off.service

  # Optimize CPU Governor to schedutil
  if [ -d "/sys/devices/system/cpu/cpu0/cpufreq" ]; then
    # @embed_file services/cpu-governor.service /etc/systemd/system/cpu-governor.service
    systemctl enable cpu-governor.service
  fi
else
  echo "[3/7] Skipping CPU and performance optimizations..."
fi

# Configure hardware overlays for ADC if potentiometer is enabled
if [ "$INSTALL_POTI" = true ]; then
  CONFIG_FILE="/boot/firmware/config.txt"
  if [ ! -f "$CONFIG_FILE" ]; then
    CONFIG_FILE="/boot/config.txt"
  fi

  if [ -f "$CONFIG_FILE" ]; then
    grep -q "dtparam=i2c_arm=on" "$CONFIG_FILE" || echo "dtparam=i2c_arm=on" >> "$CONFIG_FILE"
    grep -q "dtoverlay=ads1015" "$CONFIG_FILE" || echo "dtoverlay=ads1015" >> "$CONFIG_FILE"
  fi
fi

# 4. Configure Audio Sources and Snapserver
echo "[4/7] Setting up AirPlay, Spotify audio pipes and Snapserver configuration..."
mkdir -p /tmp/snapfifo
mkfifo /tmp/airplayfifo 2>/dev/null || true
mkfifo /tmp/spotifyfifo 2>/dev/null || true
chmod 666 /tmp/airplayfifo /tmp/spotifyfifo

# Configure Shairport-Sync (AirPlay)
cat > /etc/shairport-sync.conf <<'EOF'
general = {
    name = "HSS AirPlay";
};

sessioncontrol = {
    active_state_timeout = 10.0;
};

output_backend = "pipe";
pipe = {
    path = "/tmp/airplayfifo";
};
EOF

# Configure Librespot (Spotify Connect) service
# @embed_file services/librespot.service /etc/systemd/system/librespot.service

SNAPCONF="/etc/snapserver.conf"
if [ -f "$SNAPCONF" ]; then
  cp "$SNAPCONF" "${SNAPCONF}.bak"
  sed -i '/^source = pipe:\/\/\/tmp\/airplayfifo/d' "$SNAPCONF"
  sed -i '/^source = pipe:\/\/\/tmp\/spotifyfifo/d' "$SNAPCONF"

  if [ "$INSTALL_SNAPWEB" = true ]; then
    if grep -q "\[http\]" "$SNAPCONF"; then
      sed -i "/\[http\]/,/\[/ s|^#*doc_root =.*|doc_root = $SNAPWEB_ROOT|" "$SNAPCONF"
      sed -i '/\[http\]/,/\[/ s/^#*enabled =.*/enabled = true/' "$SNAPCONF"
      sed -i "/\[http\]/,/\[/ s/^#*port =.*/port = $SNAPWEB_PORT/" "$SNAPCONF"
    else
      cat >> "$SNAPCONF" <<EOF

[http]
enabled = true
doc_root = $SNAPWEB_ROOT
host = 0.0.0.0
port = $SNAPWEB_PORT
EOF
    fi
  fi

  cat >> "$SNAPCONF" <<'EOF'

# HSS Audio Sources
source = pipe:///tmp/airplayfifo?name=AirPlay&sampleformat=44100:16:2
source = pipe:///tmp/spotifyfifo?name=Spotify&sampleformat=44100:16:2
EOF
fi

# 5. NetworkManager Hotspot Fallback & Provisioning Web Portal
echo "[5/7] Setting up NetworkManager Hotspot and Wi-Fi provisioning portal..."
nmcli connection add type wifi ifname wlan0 mode ap con-name "HSS-Hotspot" ssid "$HOTSPOT_SSID" 2>/dev/null || true
nmcli connection modify "HSS-Hotspot" 802-11-wireless.band bg 2>/dev/null || true
nmcli connection modify "HSS-Hotspot" 802-11-wireless.channel 6 2>/dev/null || true
nmcli connection modify "HSS-Hotspot" ipv4.method shared 2>/dev/null || true
nmcli connection modify "HSS-Hotspot" connection.autoconnect yes 2>/dev/null || true
nmcli connection modify "HSS-Hotspot" connection.autoconnect-priority 1 2>/dev/null || true

# @embed_file scripts/hss_wifi_portal.py /usr/local/bin/hss_wifi_portal.py

chmod +x "$PORTAL_SCRIPT_PATH"

# @embed_file services/hss-wifi-portal.service /etc/systemd/system/hss-wifi-portal.service

systemctl daemon-reload
systemctl enable hss-wifi-portal.service

# 6. Potentiometer Control Script (Optional)
if [ "$INSTALL_POTI" = true ]; then
  echo "[6/7] Deploying potentiometer control script..."
  # @embed_file scripts/hss_volume_control.py /usr/local/bin/hss_volume_control.py

  chmod +x "$POT_SERVICE_PATH"

  # @embed_file services/hss-volume.service /etc/systemd/system/hss-volume.service

  systemctl daemon-reload
  systemctl enable --now hss-volume.service
else
  echo "[6/7] Skipping potentiometer setup..."
fi

# 7. Enable Services & Finalize
echo "[7/7] Enabling core services and finalizing installation..."
systemctl daemon-reload
systemctl enable --now shairport-sync
systemctl enable --now librespot
systemctl enable --now snapserver.service

echo
echo "=== HSS HUB SETUP COMPLETE ==="
if [ "$INSTALL_SNAPWEB" = true ]; then
  echo "Snapweb is available at http://${NEW_HOSTNAME}.local:${SNAPWEB_PORT}"
fi
echo "Please reboot your Raspberry Pi to ensure all configurations and hardware overlays take effect."
