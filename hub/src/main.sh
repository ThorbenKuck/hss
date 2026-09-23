#!/bin/bash
set -euo pipefail

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

# Helper function to ask yes/no questions requiring explicit 'Ja'
ask_yes_no() {
  local prompt_text="$1"
  if [ "$ASSUME_YES" = true ]; then
    return 0
  fi

  while true; do
    read -rp "${prompt_text} (Tippe 'Ja' zum Aktivieren, 'nein' zum Überspringen): " response
    case "$response" in
      [jJ][aA]|[yY]|[yY][eE][sS])
        return 0
        ;;
      [nN][eE][iI][nN]|[nN]|[nN][oO])
        return 1
        ;;
      *)
        echo "Bitte antworte explizit mit 'Ja' oder 'nein'."
        ;;
    esac
  done
}

# Helper function to prompt for values with a default option
ask_value() {
  local prompt_text="$1"
  local default_value="$2"

  if [ "$ASSUME_YES" = true ]; then
    echo "$default_value"
    return
  fi

  read -rp "${prompt_text} [Standard: ${default_value}]: " response
  if [ -z "$response" ]; then
    echo "$default_value"
  else
    echo "$response"
  fi
}

echo "=== HSS Central Audio Hub Interactive Setup ==="
echo

# Gather configuration parameters upfront
NEW_HOSTNAME=$(ask_value "Gib den gewünschten Hostnamen ein" "hss")
HOTSPOT_SSID=$(ask_value "Gib den SSID-Namen für den Setup-Hotspot ein" "HSS-Setup")

echo
if ask_yes_no "Möchtest du CPU-Optimierungen und Energiespar-Mechanismen installieren?"; then
  INSTALL_CPU_OPT=true
else
  INSTALL_CPU_OPT=false
fi

if ask_yes_no "Möchtest du das Snapweb-Webinterface installieren?"; then
  INSTALL_SNAPWEB=true
  SNAPWEB_PORT=$(ask_value "Gib den Port für das Snapweb-Interface ein" "1780")
else
  INSTALL_SNAPWEB=false
  SNAPWEB_PORT="1780"
fi

if ask_yes_no "Möchtest du die Lautstärkesteuerung via Potentiometer (ADS1015/1115) installieren?"; then
  INSTALL_POTI=true
else
  INSTALL_POTI=false
fi

echo
echo "=== Starten der Installation mit deiner Konfiguration ==="
echo

POT_SERVICE_PATH="/usr/local/bin/hss_volume_control.py"
PORTAL_SCRIPT_PATH="/usr/local/bin/hss_wifi_portal.py"

# 1. Update system and install required base packages
echo "[1/7] Updating system and installing base packages..."
apt update && apt upgrade -y

BASE_PACKAGES="snapserver avahi-daemon ssh python3 python3-pip git alsa-utils network-manager shairport-sync librespot"
if [ "$INSTALL_SNAPWEB" = true ]; then
  BASE_PACKAGES="$BASE_PACKAGES snapweb"
fi
if [ "$INSTALL_POTI" = true ]; then
  BASE_PACKAGES="$BASE_PACKAGES i2c-tools"
fi

apt install -y $BASE_PACKAGES

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

# Configure Librespot (Spotify Connect) Service
# @embed_file services/librespot.service /etc/systemd/system/librespot.service

SNAPCONF="/etc/snapserver.conf"
if [ -f "$SNAPCONF" ]; then
  cp "$SNAPCONF" "${SNAPCONF}.bak"
  sed -i '/^source = pipe:\/\/\/tmp\/airplayfifo/d' "$SNAPCONF"
  sed -i '/^source = pipe:\/\/\/tmp\/spotifyfifo/d' "$SNAPCONF"

  if [ "$INSTALL_SNAPWEB" = true ]; then
    if grep -q "\[http\]" "$SNAPCONF"; then
      sed -i '/\[http\]/,/\[/ s/^#*doc_root =.*/doc_root = \/usr\/share\/snapserver\/snapweb/' "$SNAPCONF"
      sed -i '/\[http\]/,/\[/ s/^#*enabled =.*/enabled = true/' "$SNAPCONF"
      sed -i "/\[http\]/,/\[/ s/^#*port =.*/port = $SNAPWEB_PORT/" "$SNAPCONF"
    else
      cat >> "$SNAPCONF" <<EOF

[http]
enabled = true
doc_root = /usr/share/snapserver/snapweb
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