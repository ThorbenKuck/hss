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
if ask_yes_no "Install CPU optimizations and power-saving measures?" "Yes"; then
  INSTALL_CPU_OPT=true
else
  INSTALL_CPU_OPT=false
fi

if ask_yes_no "Install the Snapweb web interface?" "Yes"; then
  INSTALL_SNAPWEB=true
else
  INSTALL_SNAPWEB=false
fi

if ask_yes_no "Install Raspotify (Spotify Client)?" "Yes"; then
  INSTALL_RASPOTIFY=true
else
  INSTALL_RASPOTIFY=false
fi

if ask_yes_no "Install HSS-Control?" "Yes"; then
  INSTALL_CONTROL=true
else
  INSTALL_CONTROL=false
fi

if ask_yes_no "Enable the universal audio pipe?" "Yes"; then
  INSTALL_UNIVERSAL=true
else
  INSTALL_UNIVERSAL=false
fi

if ask_yes_no "Would you like to setup the volume control display?" "Yes"; then
  INSTALL_DISPLAY=true
else
  INSTALL_DISPLAY=false
fi

echo
echo "=== Starting installation with your configuration ==="
echo

VOLUME_CONTROL_PATH="/opt/hss_volume_control.py"
BOOT_ANIMATION_PATH="/opt/hss_boot_animation.py"
DISPLAY_VENV="/opt/hss_display_venv"
DISPLAY_OWNER="${SUDO_USER:-root}"
PORTAL_SCRIPT_PATH="/usr/local/bin/hss_wifi_portal.py"
SNAPWEB_ROOT="/var/www/snapweb"
HSS_CONTROL_ROOT="/var/www/hss-control"
HSS_CONTROL_UPDATER="/usr/local/bin/update_hss_control.sh"
HSS_CONTROL_NGINX_CONF="/etc/nginx/sites-available/hss-control"
SNAPSERVER_SYSTEMD_DROP_IN_DIR="/etc/systemd/system/snapserver.service.d"
SNAPSERVER_SYSTEMD_OVERRIDE="${SNAPSERVER_SYSTEMD_DROP_IN_DIR}/override.conf"

install_raspotify() {
  echo "Installing Raspotify from the official APT repository..."

  apt-get update
  apt-get install -y curl apt-transport-https gnupg
  curl --fail --silent --show-error --location \
    https://dtcooper.github.io/raspotify/key.asc |
    gpg --dearmor --yes -o /usr/share/keyrings/raspotify-archive-keyring.gpg
  printf '%s\n' \
    'deb [signed-by=/usr/share/keyrings/raspotify-archive-keyring.gpg] https://dtcooper.github.io/raspotify raspotify main' \
    > /etc/apt/sources.list.d/raspotify.list
  apt-get update
  apt-get install -y raspotify
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

install_hss_control() {
  if [ "$INSTALL_CONTROL" = true ]; then
    echo "Installing HSS Control PWA..."
    # @embed_file scripts/update_hss_control.sh /usr/local/bin/update_hss_control.sh
    chmod 755 "$HSS_CONTROL_UPDATER"
    "$HSS_CONTROL_UPDATER"
  fi

  # @embed_file config/hss-control.nginx /etc/nginx/sites-available/hss-control
  ln -sfn "$HSS_CONTROL_NGINX_CONF" /etc/nginx/sites-enabled/hss-control
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
}

# 1. Update system and install required base packages
echo "[1/7] Updating system and installing base packages..."
apt update && apt upgrade -y

BASE_PACKAGES="snapserver avahi-daemon ssh python3 python3-pip git alsa-utils network-manager shairport-sync curl unzip nginx"
if [ "$INSTALL_DISPLAY" = true ]; then
  BASE_PACKAGES="$BASE_PACKAGES i2c-tools"
fi

apt install -y $BASE_PACKAGES

if [ "$INSTALL_RASPOTIFY" = true ]; then
  install_raspotify
fi
if [ "$INSTALL_SNAPWEB" = true ]; then
  install_snapweb
fi
install_hss_control

mkdir -p "$SNAPSERVER_SYSTEMD_DROP_IN_DIR"
cat > "$SNAPSERVER_SYSTEMD_OVERRIDE" <<'EOF'
[Service]
RuntimeDirectory=snapserver
RuntimeDirectoryMode=0775
EOF
systemctl daemon-reload
cat > /etc/tmpfiles.d/snapserver.conf <<'EOF'
d /run/snapserver 0775 _snapserver _snapserver -
EOF
systemd-tmpfiles --create /etc/tmpfiles.d/snapserver.conf

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

# Configure hardware overlays for ADC if the volume control display is enabled
if [ "$INSTALL_DISPLAY" = true ]; then
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
echo "[4/7] Setting up audio pipes and Snapserver configuration..."
SNAPSERVER_RUNTIME_DIR="/run/snapserver"
MASTER_FIFO="$SNAPSERVER_RUNTIME_DIR/master"
AIRPLAY_FIFO="$SNAPSERVER_RUNTIME_DIR/airplay"
SPOTIFY_FIFO="$SNAPSERVER_RUNTIME_DIR/spotify"
UNIVERSAL_FIFO="$SNAPSERVER_RUNTIME_DIR/universal"

sudo mkdir -p "$SNAPSERVER_RUNTIME_DIR"
sudo chmod 777 "$SNAPSERVER_RUNTIME_DIR"
mkfifo "$MASTER_FIFO" 2>/dev/null || true
chmod 666 "$MASTER_FIFO"

if [ "$INSTALL_RASPOTIFY" = true ]; then
  mkfifo "$SPOTIFY_FIFO" 2>/dev/null || true
  chmod 666 "$SPOTIFY_FIFO"
else
  rm -f "$SPOTIFY_FIFO"
fi

if [ "$INSTALL_UNIVERSAL" = true ]; then
  mkfifo "$UNIVERSAL_FIFO" 2>/dev/null || true
  chmod 666 "$UNIVERSAL_FIFO"
else
  rm -f "$UNIVERSAL_FIFO"
fi

mkfifo "$AIRPLAY_FIFO" 2>/dev/null || true
chmod 666 "$AIRPLAY_FIFO"

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
    path = "/run/snapserver/airplay";
};
EOF

if [ "$INSTALL_RASPOTIFY" = true ]; then
  # Configure Raspotify (Spotify Connect) to write into Snapcast's FIFO.
  cat > /etc/raspotify/conf <<'EOF'
LIBRESPOT_BACKEND="pipe"
LIBRESPOT_DEVICE="/run/snapserver/spotify"
LIBRESPOT_NAME="HSS Spotify"
LIBRESPOT_BITRATE="320"
LIBRESPOT_INITIAL_VOLUME="100"
EOF
else
  systemctl disable --now raspotify.service 2>/dev/null || true
fi

SNAPCONF="/etc/snapserver.conf"
if [ -f "$SNAPCONF" ]; then
  cp "$SNAPCONF" "${SNAPCONF}.bak"
else
  touch "$SNAPCONF"
fi

if grep -q "^[[:space:]]*\[http\][[:space:]]*$" "$SNAPCONF"; then
  # Keep Snapcast's HTTP interface enabled so Snapweb remains available on port 1780.
  if sed -n '/^[[:space:]]*\[http\][[:space:]]*$/,/^[[:space:]]*\[[^]]*\][[:space:]]*$/p' "$SNAPCONF" |
    grep -q '^[[:space:]]*#*[[:space:]]*enabled[[:space:]]*='; then
    sed -i "/^[[:space:]]*\[http\][[:space:]]*$/,/^[[:space:]]*\[[^]]*\][[:space:]]*$/ s/^[[:space:]]*#*[[:space:]]*enabled[[:space:]]*=.*/enabled = true/" "$SNAPCONF"
  else
    sed -i "/^[[:space:]]*\[http\][[:space:]]*$/a enabled = true" "$SNAPCONF"
  fi
else
  printf '\n[http]\nenabled = true\n' >> "$SNAPCONF"
fi

# Replace the generated stream section instead of appending duplicate sources.
SNAPCONF_BASE=$(mktemp)
awk '
  /^\[stream\][[:space:]]*$/ { in_stream = 1; next }
  in_stream && /^\[[^]]+\][[:space:]]*$/ { in_stream = 0 }
  in_stream { next }
  /^[[:space:]]*source[[:space:]]*=/ { next }
  { print }
' "$SNAPCONF" > "$SNAPCONF_BASE"

# Build the automatic Meta-Stream path from the enabled physical sources.
META_SOURCES="TCP/Airplay"
if [ "$INSTALL_RASPOTIFY" = true ]; then
  META_SOURCES="$META_SOURCES/Spotify"
fi
if [ "$INSTALL_UNIVERSAL" = true ]; then
  META_SOURCES="$META_SOURCES/Universal"
fi

{
  printf '\n[stream]\n'
  printf 'source = meta:///%s?name=Automatic\n' "$META_SOURCES"
  printf 'source = tcp://0.0.0.0:4953?name=TCP&sampleformat=48000:16:2\n'
  printf 'source = pipe:///run/snapserver/airplay?name=Airplay&mode=create&sampleformat=44100:16:2\n'

  if [ "$INSTALL_RASPOTIFY" = true ]; then
    printf 'source = pipe:///run/snapserver/spotify?name=Spotify&mode=create&sampleformat=48000:16:2\n'
  fi

  if [ "$INSTALL_UNIVERSAL" = true ]; then
    printf 'source = pipe:///run/snapserver/universal?name=Universal&mode=create&sampleformat=44100:16:2\n'
  fi
} >> "$SNAPCONF_BASE"
mv "$SNAPCONF_BASE" "$SNAPCONF"

# Snapserver persists stream state in server.json; rebuild it from the configuration.
rm -f /var/lib/snapserver/server.json

# 5. NetworkManager Hotspot Fallback & Provisioning Web Portal
echo "[5/7] Setting up NetworkManager Hotspot and Wi-Fi provisioning portal..."
nmcli connection add type wifi ifname wlan0 mode ap con-name "HSS-Hotspot" ssid "$HOTSPOT_SSID" 2>/dev/null || true
nmcli connection modify "HSS-Hotspot" 802-11-wireless.band bg 2>/dev/null || true
nmcli connection modify "HSS-Hotspot" 802-11-wireless.channel 6 2>/dev/null || true
nmcli connection modify "HSS-Hotspot" ipv4.method shared 2>/dev/null || true
nmcli connection modify "HSS-Hotspot" connection.autoconnect yes 2>/dev/null || true
# Set lower priority so client networks are preferred over hotspot
nmcli connection modify "HSS-Hotspot" connection.autoconnect-priority -10 2>/dev/null || true

# @embed_file scripts/hss_wifi_portal.py /usr/local/bin/hss_wifi_portal.py

chmod +x "$PORTAL_SCRIPT_PATH"

# @embed_file services/hss-wifi-portal.service /etc/systemd/system/hss-wifi-portal.service

systemctl daemon-reload
systemctl enable --now nginx.service hss-wifi-portal.service

# 6. Potentiometer Control Script (Optional)
if [ "$INSTALL_DISPLAY" = true ]; then
  echo "[6/7] Deploying volume control display..."
  apt-get install -y python3-venv python3-dev python3-pip libjpeg-dev zlib1g-dev

  if [ ! -d "$DISPLAY_VENV" ]; then
    python3 -m venv "$DISPLAY_VENV"
  fi
  "$DISPLAY_VENV/bin/pip" install --upgrade pip setuptools wheel
  "$DISPLAY_VENV/bin/pip" install spidev RPi.GPIO Pillow

  # @embed_file scripts/hss_volume_control.py /opt/hss_volume_control.py
  # @embed_file scripts/hss_boot_animation.py /opt/hss_boot_animation.py

  chmod +x "$VOLUME_CONTROL_PATH" "$BOOT_ANIMATION_PATH"
  chown -R "$DISPLAY_OWNER:$DISPLAY_OWNER" \
    "$VOLUME_CONTROL_PATH" "$BOOT_ANIMATION_PATH" "$DISPLAY_VENV"

  # @embed_file services/hss-boot-animation.service /etc/systemd/system/hss-boot-animation.service
  # @embed_file services/hss-volume-control.service /etc/systemd/system/hss-volume-control.service

  systemctl daemon-reload
  systemctl disable --now hss-volume.service 2>/dev/null || true
  systemctl enable hss-boot-animation.service hss-volume-control.service
else
  echo "[6/7] Skipping volume control display setup..."
  systemctl disable --now hss-boot-animation.service hss-volume-control.service hss-volume.service 2>/dev/null || true
fi

# 7. Enable Services & Finalize
echo "[7/7] Enabling core services and finalizing installation..."
chmod 0644 /etc/snapserver.conf /etc/default/snapserver
systemctl daemon-reload
systemctl enable --now shairport-sync
systemctl enable --now snapserver.service
systemctl restart snapserver.service
if [ "$INSTALL_RASPOTIFY" = true ]; then
  systemctl enable --now raspotify.service
fi

echo
echo "=== HSS HUB SETUP COMPLETE ==="
if [ "$INSTALL_SNAPWEB" = true ]; then
  echo "Snapweb is available at http://${NEW_HOSTNAME}.local/snapweb/"
fi
echo "Please reboot your Raspberry Pi to ensure all configurations and hardware overlays take effect."
