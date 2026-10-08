# Shared platform and command validation helpers.

hss_require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    ui_error "Run this setup script with sudo or as root."
    return 1
  fi
  ui_success "Running with root privileges."
}

hss_validate_architecture() {
  local architecture
  architecture=$(uname -m)

  case "$architecture" in
    armv6l|armv7l|aarch64|arm64)
      HSS_ARCHITECTURE="$architecture"
      ui_success "Supported system architecture detected: ${architecture}."
      ;;
    *)
      ui_error "Unsupported system architecture: ${architecture}."
      ui_info "Supported architectures are armv6l, armv7l, aarch64, and arm64."
      return 1
      ;;
  esac
}

hss_check_commands() {
  local missing_commands=()
  local command_name

  for command_name in "$@"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      missing_commands+=("$command_name")
    fi
  done

  if [ "${#missing_commands[@]}" -gt 0 ]; then
    ui_error "Required system commands are missing: ${missing_commands[*]}"
    return 1
  fi

  ui_success "Required system commands are available."
}

hss_validate_prerequisites() {
  hss_check_commands apt-get systemctl hostnamectl awk sed grep mktemp install date uname
}