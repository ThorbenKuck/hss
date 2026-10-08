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
HSS_SETUP_ROLE="Speaker"
HSS_UI_TOTAL_STEPS=8
STATE_FILE="/var/local/setup_progress"
CONFIG_FILE_ENV="/var/local/setup_config.env"
STARTUP_WAV_PATH="/var/local/startup.wav"
REPO_DIR="/var/tmp/WM8960-Audio-HAT"
RESUME_SCRIPT="/var/local/setup.sh"
RESUME_HOOK="/etc/profile.d/resume_setup.sh"
SETUP_STAGE="START"
HSS_REBOOT_REQUESTED=false

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

enable_resume_hook() {
  local script_path="${BASH_SOURCE[0]}"
  ui_action "Deploying the setup resume login hook."

  # Ensure directories exist
  mkdir -p "$(dirname "$RESUME_SCRIPT")" "$(dirname "$RESUME_HOOK")"

  # Copy setup script and set executable permissions
  cp "$script_path" "$RESUME_SCRIPT"
  chmod 755 "$RESUME_SCRIPT"

  # Grant passwordless sudo access for this specific setup script
  local sudoers_file="/etc/sudoers.d/setup-resume"
  echo "ALL ALL=(ALL) NOPASSWD: /bin/bash /var/local/setup.sh *" > "$sudoers_file"
  chmod 0440 "$sudoers_file"

  # Create the login hook script executing via sudo
  cat > "$RESUME_HOOK" <<'EOF'
if [ -f /var/local/setup_progress ]; then
  sudo /bin/bash /var/local/setup.sh -y
fi
EOF
}

disable_resume_hook() {
  rm -f "$RESUME_HOOK" "$RESUME_SCRIPT" "$STATE_FILE" "$CONFIG_FILE_ENV"
}

println() {
  ui_action "$*"
}

ensure_repo_cloned() {
  if [ ! -d "$REPO_DIR" ]; then
    println "Cloning WM8960 Audio HAT repository..."
    git clone https://github.com/waveshare/WM8960-Audio-HAT "$REPO_DIR"
  fi
}

installDependencies() {
  apt-get update && apt-get upgrade -y
  apt-get install -y snapclient alsa-utils libasound2 iw python3-lgpio git bc curl wget
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
    ui_error "WM8960 HAT not found. Is it plugged in properly?"
    exit 1
  fi
  ui_success "Found WM8960 with ALSA name: $AUDIO_CARD_NAME."
}

disableOnboardAudio() {
  ui_action "Disabling the onboard audio interface."
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
  ui_action "Disabling swap memory to reduce SD card wear."
  dphys-swapfile swapoff 2>/dev/null || true
  dphys-swapfile uninstall 2>/dev/null || true
  systemd_disable_now_optional dphys-swapfile.service
  systemd_mask_optional dphys-swapfile.service
  swapoff -a || true
}

disableHDMI() {
  ui_action "Disabling HDMI output to save power."
  # @embed_file services/hdmi-off.service /etc/systemd/system/hdmi-off.service

  systemd_reload_and_enable hdmi-off.service
  systemd_start hdmi-off.service || true
}

performanceBoost() {
  ui_action "Disabling Wi-Fi power saving for low latency."
  # @embed_file services/wifi-powersave-off.service /etc/systemd/system/wifi-powersave-off.service
  systemd_reload_and_enable wifi-powersave-off.service
  iw wlan0 set power_save off 2>/dev/null || true

  ui_action "Setting the CPU governor to performance mode."
  if [ -d "/sys/devices/system/cpu/cpu0/cpufreq" ]; then
    # @embed_file services/cpu-performance.service /etc/systemd/system/cpu-performance.service

    systemd_reload_and_enable cpu-performance.service
    systemd_start cpu-performance.service
  else
    ui_info "No cpufreq interface found; skipping the CPU governor change."
  fi
}

appendAsoundConfStereo() {
  ui_action "Writing stereo ALSA routing for the WM8960 card."
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
  ui_action "Writing mono downmix ALSA routing for the WM8960 card."
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
  ui_action "Configuring output channels and disabling ALC dynamic compression."
  sleep 1
  amixer -c "$AUDIO_CARD_NAME" sset 'Left Output Mixer PCM' on || true
  amixer -c "$AUDIO_CARD_NAME" sset 'Right Output Mixer PCM' on || true
  amixer -c "$AUDIO_CARD_NAME" sset 'Playback' 100% || true

  amixer -c "$AUDIO_CARD_NAME" sset 'ALC Target' 0 2>/dev/null || true
  amixer -c "$AUDIO_CARD_NAME" sset 'ALC Function' 0 2>/dev/null || true

  amixer -c "$AUDIO_CARD_NAME" sset 'Speaker' "$TARGET_VOLUME" || true
  alsactl store "$AUDIO_CARD_NAME" 2>/dev/null || true
  systemd_enable alsa-restore.service 2>/dev/null || true
  systemd_enable alsa-state.service 2>/dev/null || true
}

setupSnapcastClient() {
  local RUN_USER="root"
  if [ -n "${SETUP_RUN_USER:-}" ]; then
    ui_info "Snapclient will run as ${SETUP_RUN_USER} in the audio group."
    usermod -aG audio "$SETUP_RUN_USER" || true
    RUN_USER="$SETUP_RUN_USER"
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

  systemd_reload_enable_now snapclient.service
  systemd_restart snapclient.service
}

setupStartupSound() {
  local sound_url="${RELEASE_BASE_URL_VALUE}/startup.wav"

  ui_action "Fetching the startup sound artifact."
  mkdir -p "$(dirname "$STARTUP_WAV_PATH")"

  if command -v curl >/dev/null 2>&1; then
    curl -sSL -o "$STARTUP_WAV_PATH" "$sound_url"
  else
    wget -q -O "$STARTUP_WAV_PATH" "$sound_url"
  fi
  # @embed_file services/startup-sound.service /etc/systemd/system/startup-sound.service
  sed -i "s|__STARTUP_WAV_PATH__|$STARTUP_WAV_PATH|g" /etc/systemd/system/startup-sound.service

  systemd_reload_and_enable startup-sound.service
}

createVolumeEnforcementService() {
  # @embed_file services/alsa-volume-fix.service /etc/systemd/system/alsa-volume-fix.service
  sed -i \
    -e "s|__AUDIO_CARD_NAME__|$AUDIO_CARD_NAME|g" \
    -e "s|__TARGET_VOLUME__|$TARGET_VOLUME|g" \
    /etc/systemd/system/alsa-volume-fix.service
  systemd_reload_and_enable alsa-volume-fix.service
}

applyRealTimeLimits() {
  grep -q "@audio" /etc/security/limits.conf || cat >> /etc/security/limits.conf <<EOF
@audio   -   rtprio     95
@audio   -   memlock    unlimited
EOF
}

startStage() {
  RANDOM_SUFFIX=$(tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 6) || true
  DEFAULT_SPEAKER_NAME="hss-speaker-${RANDOM_SUFFIX}"
  SPEAKER_NAME=$(ask_value "Enter the speaker hostname" "$DEFAULT_SPEAKER_NAME")
  SNAPSERVER_HOST=$(ask_value "Enter the Snapserver hostname or IP address" "hss.local")
  SNAPSERVER_PORT=$(ask_value "Enter the Snapserver port" "1704")
  TARGET_VOLUME=$(ask_value "Enter the default volume" "95%")
  BUFFER_MS=$(ask_value "Enter the buffer size in milliseconds" "300")

  OPT_DISABLE_ONBOARD=$(ask_yes_no "Disable onboard audio and use only the WM8960 card?" "Yes" && echo "true" || echo "false")
  OPT_DISABLE_SWAP=$(ask_yes_no "Disable swap memory to protect the SD card?" "Yes" && echo "true" || echo "false")
  OPT_DISABLE_HDMI=$(ask_yes_no "Disable HDMI output to save power?" "Yes" && echo "true" || echo "false")
  OPT_PERFORMANCE=$(ask_yes_no "Enable performance optimizations (disable Wi-Fi power saving and use the performance CPU governor)?" "Yes" && echo "true" || echo "false")
  OPT_MONO_OUTPUT=$(ask_yes_no "Configure audio output as a mono downmix?" "No" && echo "true" || echo "false")
  OPT_STARTUP_SOUND=$(ask_yes_no "Play a startup sound when the system boots?" "Yes" && echo "true" || echo "false")
  OPT_ENFORCE_VOLUME=$(ask_yes_no "Enable a service that enforces a startup volume of $TARGET_VOLUME?" "Yes" && echo "true" || echo "false")

  SETUP_RUN_USER="${SUDO_USER:-}"
  RELEASE_BASE_URL_VALUE="${RELEASE_BASE_URL:-https://github.com/ThorbenKuck/hss/releases/latest/download}"
}

load_configuration() {
  if [ -f "$CONFIG_FILE_ENV" ]; then
    # The configuration file is created with mode 0600 by save_configuration.
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

  SETUP_RUN_USER="${SETUP_RUN_USER:-${SUDO_USER:-}}"
  RELEASE_BASE_URL_VALUE="${RELEASE_BASE_URL_VALUE:-${RELEASE_BASE_URL:-https://github.com/ThorbenKuck/hss/releases/latest/download}}"
}

configuration_phase() {
  SETUP_STAGE="$(get_stage)"

  case "$SETUP_STAGE" in
    START)
      ui_section "Initial configuration"
      startStage
      ;;
    AUDIO_SETUP)
      ui_section "Resuming confirmed configuration"
      load_configuration
      ;;
    *)
      ui_warning "Unknown setup state '${SETUP_STAGE}'; starting a fresh configuration."
      SETUP_STAGE="START"
      ui_section "Initial configuration"
      startStage
      ;;
  esac
}

confirm_configuration() {
  [ "$SETUP_STAGE" = "START" ] || return 0

  ui_section "Configuration summary"
  ui_config_item "Hostname" "$SPEAKER_NAME"
  ui_config_item "Snapserver" "$SNAPSERVER_HOST:$SNAPSERVER_PORT"
  ui_config_item "Default volume" "$TARGET_VOLUME"
  ui_config_item "Buffer" "${BUFFER_MS} ms"
  ui_config_item "Disable onboard audio" "$OPT_DISABLE_ONBOARD"
  ui_config_item "Disable swap" "$OPT_DISABLE_SWAP"
  ui_config_item "Disable HDMI" "$OPT_DISABLE_HDMI"
  ui_config_item "Performance mode" "$OPT_PERFORMANCE"
  ui_config_item "Mono output" "$OPT_MONO_OUTPUT"
  ui_config_item "Startup sound" "$OPT_STARTUP_SOUND"
  ui_config_item "Volume enforcement" "$OPT_ENFORCE_VOLUME"
  echo
  ask_yes_no "Apply this configuration and begin the installation?" "Yes"
}

save_configuration() {
  umask 077
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
SETUP_RUN_USER="$SETUP_RUN_USER"
RELEASE_BASE_URL_VALUE="$RELEASE_BASE_URL_VALUE"
EOF
}

execution_phase() {
  if [ "$SETUP_STAGE" = "START" ]; then
    ui_step "Save configuration and set the system hostname"
    save_configuration
    network_set_hostname "$SPEAKER_NAME"

    ui_step "Install base dependencies"
    installDependencies

    ui_step "Install the WM8960 audio driver"
    installWM8960Driver

    set_stage "AUDIO_SETUP"
    enable_resume_hook
    HSS_REBOOT_REQUESTED=true
    reboot
    return 0
  fi

  HSS_UI_STEP=3
  audioSetupStage
}

audioSetupStage() {
  ui_step "Detect and configure the WM8960 audio card"
  println "Checking for the WM8960 sound card."
  detectWM8960Card

  ui_step "Apply optional power and performance settings"
  if [ "${OPT_DISABLE_ONBOARD:-true}" = "true" ]; then
    disableOnboardAudio
  fi

  if [ "${OPT_DISABLE_SWAP:-true}" = "true" ]; then
    disableSwap
  fi

  if [ "${OPT_DISABLE_HDMI:-true}" = "true" ]; then
    disableHDMI
  fi

  if [ "${OPT_PERFORMANCE:-true}" = "true" ]; then
    performanceBoost
  fi

  ui_step "Configure ALSA routing and the WM8960 mixer"
  if [ "${OPT_MONO_OUTPUT:-true}" = "true" ]; then
    appendAsoundConfMono
  else
    appendAsoundConfStereo
  fi

  initializeWM8960Mixer

  ui_step "Configure Snapclient and optional audio services"
  if [ "${OPT_STARTUP_SOUND:-true}" = "true" ]; then
    setupStartupSound
  fi

  setupSnapcastClient

  if [ "${OPT_ENFORCE_VOLUME:-true}" = "true" ]; then
    createVolumeEnforcementService
  fi

  ui_step "Apply real-time limits and finalize the installation"
  applyRealTimeLimits

  disable_resume_hook
  SETUP_STAGE="COMPLETE"
}

show_summary() {
  if [ "$HSS_REBOOT_REQUESTED" = true ]; then
    ui_summary_start "HSS SPEAKER INITIAL SETUP COMPLETE"
    ui_summary_item "Status" "Driver installation finished"
    ui_summary_item "Next step" "Reboot to continue audio configuration automatically."
  else
    ui_summary_start "HSS SPEAKER SETUP COMPLETE"
    ui_summary_item "Hostname" "$SPEAKER_NAME"
    ui_summary_item "Snapserver" "$SNAPSERVER_HOST:$SNAPSERVER_PORT"
    ui_summary_item "Audio card" "${AUDIO_CARD_NAME:-WM8960}"
  fi
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

  execution_phase
  show_summary
}

main "$@"
