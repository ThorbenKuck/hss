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

STATE_FILE="/var/local/setup_progress"
CONFIG_FILE_ENV="/var/local/setup_config.env"
STARTUP_WAV_PATH="/var/local/startup.wav"
REPO_DIR="/var/tmp/WM8960-Audio-HAT"
SCRIPT_PATH=$(realpath "$0")
RESUME_SERVICE="/etc/systemd/system/snapclient-resume.service"

# Helper function to ask yes/no questions requiring an explicit answer
ask_yes_no() {
  local prompt_text="$1"
  local default_choice="${2:-Yes}"

  if [ "$ASSUME_YES" = true ]; then
    return 0
  fi

  while true; do
    read -rp "${prompt_text} (type 'yes' to enable, 'no' to skip) [default: ${default_choice}]: " response
    if [ -z "$response" ]; then
      response="$default_choice"
    fi

    case "$response" in
      [yY]|[yY][eE][sS])
        return 0
        ;;
      [nN][oO])
        return 1
        ;;
      *)
        echo "Please answer explicitly with 'yes' or 'no'."
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

  read -rp "${prompt_text} [default: ${default_value}]: " response
  if [ -z "$response" ]; then
    echo "$default_value"
  else
    echo "$response"
  fi
}

set_stage() {
  echo "$1" > "$STATE_FILE"
}

get_stage() {
  if [ -f "$STATE_FILE" ]; then
    cat "$STATE_FILE"
  else
    echo "START"
  fi
}

enable_systemd_resume() {
  echo "Deploying systemd resume service..."
  # @embed_file services/snapclient-resume.service "$RESUME_SERVICE"
  systemctl daemon-reload
  systemctl enable snapclient-resume.service
}

disable_systemd_resume() {
  systemctl disable snapclient-resume.service 2>/dev/null || true
  rm -f "$RESUME_SERVICE" "$STATE_FILE" "$CONFIG_FILE_ENV"
  systemctl daemon-reload
}

PRINTLN_COUNTER=1
println() {
  printf "[%d] %s\n" "$PRINTLN_COUNTER" "$*"
  ((PRINTLN_COUNTER++))
}

ensure_repo_cloned() {
  if [ ! -d "$REPO_DIR" ]; then
    println "Cloning WM8960 Audio HAT repository..."
    git clone https://github.com/waveshare/WM8960-Audio-HAT "$REPO_DIR"
  fi
}

installDependencies() {
  apt update && apt upgrade -y
  apt install -y snapclient alsa-utils libasound2 iw python3-lgpio git bc
}

installWM8960Driver() {
  ensure_repo_cloned
  pushd "$REPO_DIR" > /dev/null
  ./install.sh
  popd > /dev/null
}

detectWM8960Card() {
  sleep 2
  AUDIO_CARD_NAME=$(aplay -l | awk -F': ' '/wm8960/ {print $2}' | awk '{print $1}' | head -n1)

  if [ -z "$AUDIO_CARD_NAME" ]; then
    echo "ERROR: WM8960 HAT not found. Is it plugged in properly?" >&2
    exit 1
  fi
  echo "→ Found WM8960 with ALSA name: $AUDIO_CARD_NAME"
}

disableOnboardAudio() {
  echo " # Disabling onboard audio interface"
  local CONFIG_FILE="/boot/firmware/config.txt"
  if [ ! -f "$CONFIG_FILE" ]; then
    CONFIG_FILE="/boot/config.txt"
  fi

  if [ -f "$CONFIG_FILE" ]; then
    sed -i 's/^dtparam=audio=on/#dtparam=audio=on/' "$CONFIG_FILE"
    grep -q "dtparam=audio=off" "$CONFIG_FILE" || echo "dtparam=audio=off" >> "$CONFIG_FILE"
  fi

  printf '%s\n' 'blacklist snd_bcm2835' > /etc/modprobe.d/raspi-blacklist.conf
}

disableSwap() {
  echo " # Disabling swap memory to reduce SD card wear"
  dphys-swapfile swapoff 2>/dev/null || true
  dphys-swapfile uninstall 2>/dev/null || true
  systemctl disable dphys-swapfile.service 2>/dev/null || true
  systemctl mask dphys-swapfile.service 2>/dev/null || true
  swapoff -a || true
}

disableHDMI() {
  echo " # Disabling HDMI output to save power"
  # @embed_file services/hdmi-off.service /etc/systemd/system/hdmi-off.service

  systemctl daemon-reload
  systemctl enable hdmi-off.service
  systemctl start hdmi-off.service || true
}

performanceBoost() {
  echo " # Disabling Wi-Fi power save for low latency"
  # @embed_file services/wifi-powersave-off.service /etc/systemd/system/wifi-powersave-off.service
  systemctl daemon-reload
  systemctl enable wifi-powersave-off.service
  iw wlan0 set power_save off 2>/dev/null || true

  echo " # Setting CPU governor to performance mode"
  if [ -d "/sys/devices/system/cpu/cpu0/cpufreq" ]; then
    # @embed_file services/cpu-performance.service /etc/systemd/system/cpu-performance.service

    systemctl daemon-reload
    systemctl enable cpu-performance.service
    systemctl start cpu-performance.service
  else
    echo " # No cpufreq interface found; skipping CPU governor tweak."
  fi
}

appendAsoundConfStereo() {
  echo "Writing asound.conf to route default ALSA device to WM8960 (Stereo)"
  cat > /etc/asound.conf <<EOF
pcm.!default {
  type plug
  slave.pcm "hw:$AUDIO_CARD_NAME,0"
}

ctl.!default {
  type hw
  card "$AUDIO_CARD_NAME"
}
EOF
  SNAPCLIENT_SOUNDCARD="default"
}

appendAsoundConfMono() {
  echo "Writing asound.conf to set output as mono (Downmix)"
  cat > /etc/asound.conf <<EOF
pcm.mono {
  type route
  slave.pcm "hw:$AUDIO_CARD_NAME,0"
  slave.channels 2

  ttable.0.0 0.5
  ttable.1.0 0.5
  ttable.0.1 0.5
  ttable.1.1 0.5
}

pcm.!default {
  type plug
  slave.pcm mono
}

ctl.!default {
  type hw
  card "$AUDIO_CARD_NAME"
}
EOF
  SNAPCLIENT_SOUNDCARD="mono"
}

initializeWM8960Mixer() {
  echo " # Configuring output channels and disabling ALC dynamic compression"
  sleep 1
  amixer -c "$AUDIO_CARD_NAME" sset 'Left Output Mixer PCM' on || true
  amixer -c "$AUDIO_CARD_NAME" sset 'Right Output Mixer PCM' on || true
  amixer -c "$AUDIO_CARD_NAME" sset 'Playback' 100% || true

  amixer -c "$AUDIO_CARD_NAME" sset 'ALC Target' 0 2>/dev/null || true
  amixer -c "$AUDIO_CARD_NAME" sset 'ALC Function' 0 2>/dev/null || true

  amixer -c "$AUDIO_CARD_NAME" sset 'Speaker' "$TARGET_VOLUME" || true
  alsactl store "$AUDIO_CARD_NAME" 2>/dev/null || true
  systemctl enable alsa-restore.service 2>/dev/null || true
  systemctl enable alsa-state.service 2>/dev/null || true
}

setupSnapcastClient() {
  local RUN_USER="root"
  if [ -n "${SUDO_USER-}" ]; then
    echo "Snapclient will run in audio group"
    usermod -aG audio "$SUDO_USER" || true
    RUN_USER="$SUDO_USER"
  fi

  # @embed_file services/snapclient.service /etc/systemd/system/snapclient.service
  sed -i \
    -e "s|__RUN_USER__|$RUN_USER|g" \
    -e "s|__AUDIO_CARD_NAME__|$AUDIO_CARD_NAME|g" \
    -e "s|__SNAPSERVER_HOST__|$SNAPSERVER_HOST|g" \
    -e "s|__SNAPSERVER_PORT__|$SNAPSERVER_PORT|g" \
    -e "s|__SNAPCLIENT_SOUNDCARD__|$SNAPCLIENT_SOUNDCARD|g" \
    -e "s|__BUFFER_MS__|$BUFFER_MS|g" \
    -e "s|__TARGET_VOLUME__|$TARGET_VOLUME|g" \
    /etc/systemd/system/snapclient.service

  systemctl daemon-reload
  systemctl enable snapclient.service
  systemctl restart snapclient.service
}

setupStartupSound() {
  local sound_url="${RELEASE_BASE_URL:-https://github.com/ThorbenKuck/hss/releases/latest/download}/startup.wav"

  echo "Fetching startup sound artifact..."
  mkdir -p "$(dirname "$STARTUP_WAV_PATH")"

  if command -v curl >/dev/null 2>&1; then
    curl -sSL -o "$STARTUP_WAV_PATH" "$sound_url"
  else
    wget -q -O "$STARTUP_WAV_PATH" "$sound_url"
  fi
  # @embed_file services/startup-sound.service /etc/systemd/system/startup-sound.service

  systemctl daemon-reload
  systemctl enable startup-sound.service
}

createVolumeEnforcementService() {
  # @embed_file services/alsa-volume-fix.service /etc/systemd/system/alsa-volume-fix.service
  sed -i \
    -e "s|__AUDIO_CARD_NAME__|$AUDIO_CARD_NAME|g" \
    -e "s|__TARGET_VOLUME__|$TARGET_VOLUME|g" \
    /etc/systemd/system/alsa-volume-fix.service
  systemctl enable alsa-volume-fix.service
}

applyRealTimeLimits() {
  grep -q "@audio" /etc/security/limits.conf || cat >> /etc/security/limits.conf <<EOF
@audio   -   rtprio     95
@audio   -   memlock    unlimited
EOF
}

startStage() {
  echo "=== Snapclient Speaker Interactive Setup ==="
  echo

  RANDOM_SUFFIX=$(tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 6) || true
  DEFAULT_SPEAKER_NAME="hss-speaker-${RANDOM_SUFFIX}"
  SPEAKER_NAME=$(ask_value "Enter the speaker hostname" "$DEFAULT_SPEAKER_NAME")
  SNAPSERVER_HOST=$(ask_value "Enter the Snapserver hostname or IP address" "hss.local")
  SNAPSERVER_PORT=$(ask_value "Enter the Snapserver port" "1704")
  TARGET_VOLUME=$(ask_value "Enter the default volume" "95%")
  BUFFER_MS=$(ask_value "Enter the buffer size in milliseconds" "300")

  echo
  OPT_DISABLE_ONBOARD=$(ask_yes_no "Disable onboard audio and use only the WM8960 card?" "Yes" && echo "true" || echo "false")
  OPT_DISABLE_SWAP=$(ask_yes_no "Disable swap memory to protect the SD card?" "Yes" && echo "true" || echo "false")
  OPT_DISABLE_HDMI=$(ask_yes_no "Disable HDMI output to save power?" "Yes" && echo "true" || echo "false")
  OPT_PERFORMANCE=$(ask_yes_no "Enable performance optimizations (disable Wi-Fi power saving and use the performance CPU governor)?" "Yes" && echo "true" || echo "false")
  OPT_MONO_OUTPUT=$(ask_yes_no "Configure audio output as a mono downmix?" "Yes" && echo "true" || echo "false")
  OPT_STARTUP_SOUND=$(ask_yes_no "Play a startup sound when the system boots?" "Yes" && echo "true" || echo "false")
  OPT_ENFORCE_VOLUME=$(ask_yes_no "Enable a service that enforces a startup volume of $TARGET_VOLUME?" "Yes" && echo "true" || echo "false")

  echo
  echo "=== Configuration saved. Starting driver installation... ==="
  echo

  cat > "$CONFIG_FILE_ENV" <<EOF
SPEAKER_NAME="$SPEAKER_NAME"
SNAPSERVER_HOST="$SNAPSERVER_HOST"
SNAPSERVER_PORT="$SNAPSERVER_PORT"
TARGET_VOLUME="$TARGET_VOLUME"
BUFFER_MS="$BUFFER_MS"
OPT_DISABLE_ONBOARD="$OPT_DISABLE_ONBOARD"
OPT_DISABLE_SWAP="$OPT_DISABLE_SWAP"
OPT_DISABLE_HDMI="$OPT_DISABLE_HDMI"
OPT_PERFORMANCE="$OPT_PERFORMANCE"
OPT_MONO_OUTPUT="$OPT_MONO_OUTPUT"
OPT_STARTUP_SOUND="$OPT_STARTUP_SOUND"
OPT_ENFORCE_VOLUME="$OPT_ENFORCE_VOLUME"
EOF

  println "Setting hostname to $SPEAKER_NAME"
  hostnamectl set-hostname "$SPEAKER_NAME"

  println "Setting up dependencies"
  installDependencies

  println "Installing WM8960 Driver"
  installWM8960Driver

  set_stage "AUDIO_SETUP"
  enable_systemd_resume

  echo "=== Initial driver installation complete ==="
  echo "Rebooting now. The setup will automatically continue after boot..."
  reboot
}

audioSetupStage() {
  if [ -f "$CONFIG_FILE_ENV" ]; then
    source "$CONFIG_FILE_ENV"
  else
    SPEAKER_NAME="hss-speaker"
    SNAPSERVER_HOST="hss.local"
    SNAPSERVER_PORT="1704"
    TARGET_VOLUME="95%"
    BUFFER_MS="300"
    OPT_DISABLE_ONBOARD="true"
    OPT_DISABLE_SWAP="true"
    OPT_DISABLE_HDMI="true"
    OPT_PERFORMANCE="true"
    OPT_MONO_OUTPUT="true"
    OPT_STARTUP_SOUND="true"
    OPT_ENFORCE_VOLUME="true"
  fi

  echo "# Continuing Speaker setup with stored configuration..."
  println "Checking for WM8960 sound card"
  detectWM8960Card

  if [ "${OPT_DISABLE_ONBOARD:-true}" = "true" ]; then
    println "Disabling onboard audio"
    disableOnboardAudio
  fi

  if [ "${OPT_DISABLE_SWAP:-true}" = "true" ]; then
    println "Disabling swap memory"
    disableSwap
  fi

  if [ "${OPT_DISABLE_HDMI:-true}" = "true" ]; then
    println "Disabling HDMI output"
    disableHDMI
  fi

  if [ "${OPT_PERFORMANCE:-true}" = "true" ]; then
    println "Boosting Pi performance for snapcast"
    performanceBoost
  fi

  if [ "${OPT_MONO_OUTPUT:-true}" = "true" ]; then
    println "Updating asound.conf with mono configurations"
    appendAsoundConfMono
  else
    println "Updating asound.conf with stereo default routing"
    appendAsoundConfStereo
  fi

  println "Initializing WM8960 Mixers"
  initializeWM8960Mixer

  if [ "${OPT_STARTUP_SOUND:-true}" = "true" ]; then
    println "Setting up startup sound service"
    setupStartupSound
  fi

  println "Setup Snapclient"
  setupSnapcastClient

  if [ "${OPT_ENFORCE_VOLUME:-true}" = "true" ]; then
    println "Creating volume enforcement service"
    createVolumeEnforcementService
  fi

  println "Applying real-time limits"
  applyRealTimeLimits

  disable_systemd_resume

  echo
  echo "=== SPEAKER SETUP COMPLETE ==="
}

STAGE=$(get_stage)
case "$STAGE" in
  "START")
    startStage
    ;;
  "AUDIO_SETUP")
    audioSetupStage
    ;;
  *)
    println "Unknown status! Resetting state to START."
    set_stage "START"
    startStage
    ;;
esac
