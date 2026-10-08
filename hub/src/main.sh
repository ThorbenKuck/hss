#!/bin/bash
set -euo pipefail

# Shared interactive helpers
# @include shared/ask_yes_no.sh
# @include shared/ask_value.sh
# @include shared/lifecycle.sh
# @include shared/network.sh
# @include shared/systemd.sh
# @include shared/ui.sh
# @include shared/validation.sh

ASSUME_YES=false
HSS_SETUP_ROLE="Hub"
HSS_UI_TOTAL_STEPS=7
ROLLBACK_DIR=""
ROLLBACK_FILES=()
SNAPCONF_BASE=""

configuration_phase() {
  ui_section "Initial configuration"

  NEW_HOSTNAME=$(ask_value "Enter the desired hostname" "hss")
  HOTSPOT_SSID=$(ask_value "Enter the SSID for the setup hotspot" "HSS-Setup")

  if ask_yes_no "Install CPU optimizations and power-saving measures?" "Yes"; then
    INSTALL_CPU_OPT=true
  else
    INSTALL_CPU_OPT=false
  fi

  if ask_yes_no "Enable a read-only OverlayFS for SD-card protection?" "No"; then
    INSTALL_OVERLAYFS=true
  else
    INSTALL_OVERLAYFS=false
  fi

  if ask_yes_no "Install the Snapweb web interface?" "Yes"; then
    INSTALL_SNAPWEB=true
  else
    INSTALL_SNAPWEB=false
  fi

  if ask_yes_no "Install Raspotify (Spotify client)?" "Yes"; then
    INSTALL_RASPOTIFY=true
  else
    INSTALL_RASPOTIFY=false
  fi

  if ask_yes_no "Install HSS Control?" "Yes"; then
    INSTALL_CONTROL=true
    HSS_SPOTIFY_NAME=$(ask_value "What would you like to call HSS in Spotify" "HSS")
  else
    INSTALL_CONTROL=false
    HSS_SPOTIFY_NAME="HSS"
  fi

  if ask_yes_no "Enable the universal audio pipe?" "Yes"; then
    INSTALL_UNIVERSAL=true
  else
    INSTALL_UNIVERSAL=false
  fi

  if ask_yes_no "Set up the volume control display?" "Yes"; then
    INSTALL_DISPLAY=true
  else
    INSTALL_DISPLAY=false
  fi

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
  SNAPSERVER_PERFORMANCE_DROP_IN="${SNAPSERVER_SYSTEMD_DROP_IN_DIR}/performance.conf"
  SHAIRPORT_SYSTEMD_DROP_IN_DIR="/etc/systemd/system/shairport-sync.service.d"
  RASPOTIFY_SYSTEMD_DROP_IN_DIR="/etc/systemd/system/raspotify.service.d"
  SYSCTL_AUDIO_CONF="/etc/sysctl.d/99-hss-audio.conf"
  AUDIO_CHUNK_MS="${HSS_AUDIO_CHUNK_MS:-20}"
  AUDIO_SAMPLE_RATE="${HSS_AUDIO_SAMPLE_RATE:-48000}"
  AUDIO_FIFO_SIZE="${HSS_AUDIO_FIFO_SIZE:-262144}"
  ALSA_DEVICE="${HSS_ALSA_DEVICE:-hw:0,0}"
}

confirm_configuration() {
  ui_section "Configuration summary"
  ui_config_item "Hostname" "$NEW_HOSTNAME"
  ui_config_item "Hotspot SSID" "$HOTSPOT_SSID"
  ui_config_item "CPU optimization" "$INSTALL_CPU_OPT"
  ui_config_item "OverlayFS" "$INSTALL_OVERLAYFS"
  ui_config_item "Snapweb" "$INSTALL_SNAPWEB"
  ui_config_item "Raspotify" "$INSTALL_RASPOTIFY"
  ui_config_item "HSS Control" "$INSTALL_CONTROL"
  ui_config_item "Universal pipe" "$INSTALL_UNIVERSAL"
  ui_config_item "Volume display" "$INSTALL_DISPLAY"
  ui_config_item "Audio sample rate" "$AUDIO_SAMPLE_RATE"
  ui_config_item "Audio chunk size" "$AUDIO_CHUNK_MS"
  echo
  ask_yes_no "Apply this configuration and begin the installation?" "Yes"
}

initialize_rollback() {
  ROLLBACK_DIR="$(mktemp -d /tmp/hss-hub-rollback.XXXXXX)"
  ROLLBACK_FILES=()
}

setup_cleanup() {
  local status="${1:-0}"
  local backup
  local target

  if [ -n "${SNAPCONF_BASE:-}" ]; then
    rm -f "$SNAPCONF_BASE" || true
  fi

  if [ "$status" -ne 0 ] && [ -n "${ROLLBACK_DIR:-}" ]; then
    ui_warning "Setup failed; restoring backed-up configuration files."
    for backup in "${ROLLBACK_FILES[@]}"; do
      target="${backup#*:}"
      if [ -f "${backup%%:*}" ]; then
        install -m 0644 "${backup%%:*}" "$target" || true
      else
        rm -f "$target" || true
      fi
    done
  fi

  if [ -n "${ROLLBACK_DIR:-}" ]; then
    rm -rf "$ROLLBACK_DIR" || true
  fi
}

log_step() {
  ui_action "$*"
}

backup_file() {
  local target="$1"
  local backup="$ROLLBACK_DIR$(printf '%s' "$target" | tr '/' '_')"

  [ -n "$ROLLBACK_DIR" ] || return 0
  if [ -f "$target" ]; then
    cp -a "$target" "$backup"
  fi
  ROLLBACK_FILES+=("$backup:$target")
}

append_config_once() {
  local file="$1"
  local line="$2"
  grep -Fxq "$line" "$file" || printf '%s\n' "$line" >> "$file"
}

configure_overlayfs() {
  [ "$INSTALL_OVERLAYFS" = true ] || return 0
  log_step "Enabling read-only OverlayFS protection for the root filesystem..."
  if command -v raspi-config >/dev/null 2>&1; then
    raspi-config nonint enable_overlayfs
    log_step "OverlayFS enabled by raspi-config; reboot is required."
  else
    log_step "raspi-config is unavailable; OverlayFS was not enabled."
    log_step "Install Raspberry Pi OS tools, then run: sudo raspi-config nonint enable_overlayfs"
  fi
}

set_fifo_size() {
  local fifo_path="$1"
  python3 - "$fifo_path" "$AUDIO_FIFO_SIZE" <<'PY'
import fcntl
import os
import sys

fifo_path = sys.argv[1]
pipe_size = int(sys.argv[2])
try:
    fd = os.open(fifo_path, os.O_RDONLY | os.O_NONBLOCK)
    try:
        fcntl.fcntl(fd, fcntl.F_SETPIPE_SZ, pipe_size)
    finally:
        os.close(fd)
except (OSError, ValueError) as error:
    print(f"[HSS] Warning: could not tune FIFO {fifo_path}: {error}", file=sys.stderr)
PY
}

install_raspotify() {
  ui_action "Installing Raspotify from the official APT repository."

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
  ui_action "Installing the latest Snapweb release."

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
  trap - RETURN
}

install_hss_control() {
  if [ "$INSTALL_CONTROL" = true ]; then
    ui_action "Installing HSS Control PWA."
    # @embed_file scripts/update_hss_control.sh /usr/local/bin/update_hss_control.sh
    chmod 755 "$HSS_CONTROL_UPDATER"
    "$HSS_CONTROL_UPDATER"
  fi

  # @embed_file config/hss-control.nginx /etc/nginx/sites-available/hss-control
  ln -sfn "$HSS_CONTROL_NGINX_CONF" /etc/nginx/sites-enabled/hss-control
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemd_reload_enable_now nginx.service
  systemd_reload_service nginx
}

execution_phase() {
  ui_step "Install base dependencies and optional software"
  apt-get update && apt-get upgrade -y

  local base_packages
  base_packages=(snapserver avahi-daemon ssh python3 python3-pip git alsa-utils iw network-manager shairport-sync curl unzip nginx)
  if [ "$INSTALL_DISPLAY" = true ]; then
    base_packages+=(i2c-tools)
  fi

  apt-get install -y "${base_packages[@]}"

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
  systemd_reload
  cat > /etc/tmpfiles.d/snapserver.conf <<'EOF'
d /run/snapserver 0775 _snapserver _snapserver -
EOF
  systemd-tmpfiles --create /etc/tmpfiles.d/snapserver.conf

  ui_step "Configure the system hostname"
  network_set_hostname "$NEW_HOSTNAME"
  systemd_restart avahi-daemon

  ui_step "Apply performance and power options"
  if [ "$INSTALL_CPU_OPT" = true ]; then
    ui_action "Applying energy-saving and performance tweaks."

    # Disable swap.
    dphys-swapfile swapoff 2>/dev/null || true
    dphys-swapfile uninstall 2>/dev/null || true
    systemd_disable_now_optional dphys-swapfile.service
    systemd_mask_optional dphys-swapfile.service

    # Disable background services.
    systemd_disable_now_optional ModemManager.service
    systemd_mask_optional ModemManager.service
    systemd_disable_now_optional triggerhappy.service
    systemd_mask_optional triggerhappy.service
    systemd_disable_now_optional apt-daily.timer apt-daily-upgrade.timer

    # Disable Bluetooth in boot configuration.
    CONFIG_FILE="/boot/firmware/config.txt"
    if [ ! -f "$CONFIG_FILE" ]; then
      CONFIG_FILE="/boot/config.txt"
    fi

    if [ -f "$CONFIG_FILE" ]; then
      backup_file "$CONFIG_FILE"
      grep -q "dtoverlay=disable-bt" "$CONFIG_FILE" || echo "dtoverlay=disable-bt" >> "$CONFIG_FILE"
    fi
    systemd_disable_now_optional bluetooth.service hciuart.service
    systemd_mask_optional bluetooth.service hciuart.service

    # Turn off HDMI and activity LEDs on boot when they are not needed.
    # @embed_file services/hdmi-off.service /etc/systemd/system/hdmi-off.service
    # @embed_file services/activity-led-off.service /etc/systemd/system/activity-led-off.service

    systemd_reload_and_enable hdmi-off.service activity-led-off.service

    # Disable the onboard activity LED in Raspberry Pi firmware configuration.
    if [ -f "$CONFIG_FILE" ]; then
      append_config_once "$CONFIG_FILE" "dtparam=act_led_trigger=none"
      append_config_once "$CONFIG_FILE" "dtparam=act_led_activelow=on"
    fi
  else
    ui_info "Performance and power options were skipped."
  fi

  # Keep the CPU at a stable frequency so audio scheduling does not wait for ramp-up.
  if [ "$INSTALL_CPU_OPT" = true ] && [ -d "/sys/devices/system/cpu/cpu0/cpufreq" ]; then
    # @embed_file services/cpu-governor.service /etc/systemd/system/cpu-governor.service
    systemd_reload_enable_now cpu-governor.service
  fi

  if [ "$INSTALL_CPU_OPT" = true ]; then
    # Reapply Wi-Fi power settings after NetworkManager brings wlan0 up.
    # @embed_file services/wifi-power-save-off.service /etc/systemd/system/wifi-power-save-off.service
    systemd_reload_enable_now wifi-power-save-off.service
  fi

  ui_action "Configuring hardware overlays for the volume control display when requested."
# Configure hardware overlays for ADC if the volume control display is enabled
if [ "$INSTALL_DISPLAY" = true ]; then
  CONFIG_FILE="/boot/firmware/config.txt"
  if [ ! -f "$CONFIG_FILE" ]; then
    CONFIG_FILE="/boot/config.txt"
  fi

  if [ -f "$CONFIG_FILE" ]; then
    grep -q "dtparam=i2c_arm=on" "$CONFIG_FILE" || echo "dtparam=i2c_arm=on" >> "$CONFIG_FILE"
    grep -Eq '^[[:space:]]*dtparam=spi=on[[:space:]]*$' "$CONFIG_FILE" || echo "dtparam=spi=on" >> "$CONFIG_FILE"
    grep -q "dtoverlay=ads1015" "$CONFIG_FILE" || echo "dtoverlay=ads1015" >> "$CONFIG_FILE"
  fi
  modprobe spidev || true
fi

  ui_step "Configure audio sources and Snapserver"
SNAPSERVER_RUNTIME_DIR="/run/snapserver"
MASTER_FIFO="$SNAPSERVER_RUNTIME_DIR/master"
AIRPLAY_FIFO="$SNAPSERVER_RUNTIME_DIR/airplay"
SPOTIFY_FIFO="$SNAPSERVER_RUNTIME_DIR/spotify"
UNIVERSAL_FIFO="$SNAPSERVER_RUNTIME_DIR/universal"

mkdir -p "$SNAPSERVER_RUNTIME_DIR"
chmod 0775 "$SNAPSERVER_RUNTIME_DIR"
mkfifo "$MASTER_FIFO" 2>/dev/null || true
chmod 0660 "$MASTER_FIFO"
set_fifo_size "$MASTER_FIFO"

if [ "$INSTALL_RASPOTIFY" = true ]; then
  mkfifo "$SPOTIFY_FIFO" 2>/dev/null || true
  chmod 0660 "$SPOTIFY_FIFO"
  set_fifo_size "$SPOTIFY_FIFO"
else
  rm -f "$SPOTIFY_FIFO"
fi

if [ "$INSTALL_UNIVERSAL" = true ]; then
  mkfifo "$UNIVERSAL_FIFO" 2>/dev/null || true
  chmod 0660 "$UNIVERSAL_FIFO"
  set_fifo_size "$UNIVERSAL_FIFO"
else
  rm -f "$UNIVERSAL_FIFO"
fi

mkfifo "$AIRPLAY_FIFO" 2>/dev/null || true
chmod 0660 "$AIRPLAY_FIFO"
set_fifo_size "$AIRPLAY_FIFO"

# Tune socket queues without changing application-level socket semantics.
# TCP_NODELAY is enabled by Snapcast itself for client synchronization sockets.
log_step "Tuning TCP queues and audio FIFO buffers (chunk=${AUDIO_CHUNK_MS}ms, fifo=${AUDIO_FIFO_SIZE} bytes)..."
backup_file "$SYSCTL_AUDIO_CONF"
cat > "$SYSCTL_AUDIO_CONF" <<'EOF'
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
net.ipv4.tcp_rmem = 4096 131072 4194304
net.ipv4.tcp_wmem = 4096 131072 4194304
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_fastopen = 3
EOF
sysctl --system >/dev/null

# Configure Shairport-Sync (AirPlay)
backup_file /etc/shairport-sync.conf
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
  backup_file /etc/raspotify/conf
  cat > /etc/raspotify/conf <<EOF
LIBRESPOT_BACKEND="pipe"
LIBRESPOT_DEVICE="/run/snapserver/spotify"
LIBRESPOT_NAME="${HSS_SPOTIFY_NAME}"
LIBRESPOT_BITRATE="320"
LIBRESPOT_SAMPLE_RATE="48000"
LIBRESPOT_FORMAT="S16"
EOF
else
  systemd_disable_now_optional raspotify.service
fi

SNAPCONF="/etc/snapserver.conf"
if [ -f "$SNAPCONF" ]; then
  backup_file "$SNAPCONF"
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
META_SOURCES="ALSA/TCP/Airplay"
if [ "$INSTALL_RASPOTIFY" = true ]; then
  META_SOURCES="$META_SOURCES/Spotify"
fi
if [ "$INSTALL_UNIVERSAL" = true ]; then
  META_SOURCES="$META_SOURCES/Universal"
fi

{
  printf '\n[stream]\n'
  printf 'source = meta:///%s?name=Automatic\n' "$META_SOURCES"
  printf 'sampleformat = %s:16:2\n' "$AUDIO_SAMPLE_RATE"
  printf 'codec = pcm\n'
  printf 'buffer = 150\n'
  printf 'chunk_ms = %s\n' "$AUDIO_CHUNK_MS"
  printf 'source = tcp://0.0.0.0:4953?name=TCP&sampleformat=%s:16:2&chunk_ms=%s\n' "$AUDIO_SAMPLE_RATE" "$AUDIO_CHUNK_MS"
  printf 'source = alsa://%s?name=ALSA&sampleformat=%s:16:2&chunk_ms=%s\n' "$ALSA_DEVICE" "$AUDIO_SAMPLE_RATE" "$AUDIO_CHUNK_MS"
  printf 'source = pipe:///run/snapserver/airplay?name=Airplay&mode=create&sampleformat=%s:16:2&chunk_ms=%s\n' "$AUDIO_SAMPLE_RATE" "$AUDIO_CHUNK_MS"

  if [ "$INSTALL_RASPOTIFY" = true ]; then
    printf 'source = pipe:///run/snapserver/spotify?name=Spotify&mode=create&sampleformat=%s:16:2&chunk_ms=%s\n' "$AUDIO_SAMPLE_RATE" "$AUDIO_CHUNK_MS"
  fi

  if [ "$INSTALL_UNIVERSAL" = true ]; then
    printf 'source = pipe:///run/snapserver/universal?name=Universal&mode=create&sampleformat=%s:16:2&chunk_ms=%s\n' "$AUDIO_SAMPLE_RATE" "$AUDIO_CHUNK_MS"
  fi
} >> "$SNAPCONF_BASE"
mv "$SNAPCONF_BASE" "$SNAPCONF"
SNAPCONF_BASE=""

# Snapserver persists stream state in server.json; rebuild it from the configuration.
rm -f /var/lib/snapserver/server.json

# Apply realtime and high I/O priority to the audio producers as well as Snapserver.
log_step "Installing realtime scheduling and I/O priority for audio services..."
mkdir -p "$SNAPSERVER_SYSTEMD_DROP_IN_DIR" "$SHAIRPORT_SYSTEMD_DROP_IN_DIR" "$RASPOTIFY_SYSTEMD_DROP_IN_DIR"
# @embed_file services/snapserver-performance.conf /etc/systemd/system/snapserver.service.d/performance.conf
# @embed_file services/shairport-performance.conf /etc/systemd/system/shairport-sync.service.d/performance.conf
# @embed_file services/raspotify-performance.conf /etc/systemd/system/raspotify.service.d/performance.conf
systemd_reload

# OverlayFS is intentionally opt-in because it changes the system's write semantics.
configure_overlayfs

ui_step "Configure the Wi-Fi fallback and provisioning portal"
network_configure_hotspot "HSS-Hotspot" "$HOTSPOT_SSID"

# @embed_file scripts/hss_wifi_portal.py /usr/local/bin/hss_wifi_portal.py

chmod +x "$PORTAL_SCRIPT_PATH"

# @embed_file services/hss-wifi-portal.service /etc/systemd/system/hss-wifi-portal.service

systemd_reload_enable_now nginx.service hss-wifi-portal.service

ui_step "Deploy the optional volume control display"
if [ "$INSTALL_DISPLAY" = true ]; then
  apt-get install -y python3-venv python3-dev python3-pip libjpeg-dev zlib1g-dev swig build-essential liblgpio-dev

  if [ ! -d "$DISPLAY_VENV" ]; then
    python3 -m venv "$DISPLAY_VENV"
  fi
  "$DISPLAY_VENV/bin/pip" install --upgrade pip setuptools wheel gpiozero lgpio spidev RPi.GPIO Pillow numpy

  # @embed_file scripts/hss_volume_control.py /opt/hss_volume_control.py
  # @embed_file scripts/hss_boot_animation.py /opt/hss_boot_animation.py

  chmod +x "$VOLUME_CONTROL_PATH" "$BOOT_ANIMATION_PATH"
  chown -R "$DISPLAY_OWNER:$DISPLAY_OWNER" \
    "$VOLUME_CONTROL_PATH" "$BOOT_ANIMATION_PATH" "$DISPLAY_VENV"

  # @embed_file services/hss-boot-animation.service /etc/systemd/system/hss-boot-animation.service
  # @embed_file services/hss-volume-control.service /etc/systemd/system/hss-volume-control.service

  systemd_reload
  systemd_disable_now_optional hss-volume.service
  systemd_enable hss-boot-animation.service hss-volume-control.service
else
  ui_info "Volume control display setup was skipped."
  systemd_disable_now_optional hss-boot-animation.service hss-volume-control.service hss-volume.service
fi

ui_step "Enable core services and finalize the installation"
chmod 0644 /etc/snapserver.conf /etc/default/snapserver
systemd_reload_enable_now shairport-sync.service
systemd_reload_enable_now snapserver.service
systemd_restart snapserver.service
if [ "$INSTALL_RASPOTIFY" = true ]; then
  systemd_enable_now raspotify.service
fi

}

show_summary() {
  ui_summary_start "HSS HUB SETUP COMPLETE"
  ui_summary_item "Hostname" "$NEW_HOSTNAME"
  if [ "$INSTALL_SNAPWEB" = true ]; then
    ui_summary_item "Snapweb" "http://${NEW_HOSTNAME}.local/snapweb/"
  fi
  ui_summary_item "Next step" "Reboot the Raspberry Pi to apply hardware overlays."
  ui_summary_end
}

main() {
  ui_init
  hss_parse_arguments "$@"
  ui_set_total_steps "$HSS_UI_TOTAL_STEPS"
  ui_header "$HSS_SETUP_ROLE"
  hss_require_root
  hss_install_traps
  hss_validate_architecture
  hss_validate_prerequisites
  configuration_phase

  if ! confirm_configuration; then
    ui_warning "Installation cancelled before system changes were made."
    exit 0
  fi

  initialize_rollback
  execution_phase
  show_summary
}

main "$@"
