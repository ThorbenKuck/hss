# Shared command-line parsing, logging, and signal handling.

HSS_LOG_FILE="${HSS_LOG_FILE:-/var/log/hss-setup.log}"
HSS_CLEANUP_DONE=false
HSS_FAILURE_REPORTED=false

hss_parse_arguments() {
  ASSUME_YES=false

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -y|--yes)
        ASSUME_YES=true
        ;;
      --)
        shift
        break
        ;;
      *)
        ui_error "Unknown option: $1"
        return 2
        ;;
    esac
    shift
  done
}

hss_write_log() {
  local level="$1"
  local message="$2"
  local log_file="${HSS_LOG_FILE:-/var/log/hss-setup.log}"
  local fallback_file
  local timestamp

  timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')
  if ! printf '%s [%s] [%s] %s\n' \
    "$timestamp" "${HSS_SETUP_ROLE:-setup}" "$level" "$message" >> "$log_file" 2>/dev/null; then
    fallback_file="${TMPDIR:-/tmp}/hss-setup-${EUID:-0}.log"
    printf '%s [%s] [%s] %s\n' \
      "$timestamp" "${HSS_SETUP_ROLE:-setup}" "$level" "$message" >> "$fallback_file" 2>/dev/null || true
  fi
}

hss_error_trap() {
  local status="$1"
  local failed_command="$2"
  local source_file="$3"
  local line_number="$4"

  if [ "$status" -ne 0 ]; then
    HSS_FAILURE_REPORTED=true
    ui_error "Command failed at ${source_file}:${line_number}: ${failed_command}"
    hss_write_log "ERROR" "Command failed at ${source_file}:${line_number}: ${failed_command}"
  fi
  return "$status"
}

setup_cleanup() {
  :
}

hss_exit_trap() {
  local status="$1"

  if [ "${HSS_CLEANUP_DONE:-false}" != true ]; then
    HSS_CLEANUP_DONE=true
    setup_cleanup "$status" || hss_write_log "ERROR" "Cleanup failed with status $?"
  fi

  if [ "$status" -ne 0 ] && [ "${HSS_FAILURE_REPORTED:-false}" != true ]; then
    ui_error "Setup stopped with exit status ${status}."
    hss_write_log "ERROR" "Setup stopped with exit status ${status}."
  fi

  exit "$status"
}

hss_signal_trap() {
  local signal_name="$1"

  ui_warning "Received ${signal_name}; stopping setup safely."
  hss_write_log "WARN" "Received ${signal_name}; setup interrupted."
  exit 130
}

hss_install_traps() {
  trap 'hss_error_trap "$?" "$BASH_COMMAND" "${BASH_SOURCE[0]}" "$LINENO"' ERR
  trap 'hss_exit_trap "$?"' EXIT
  trap 'hss_signal_trap INT' INT
  trap 'hss_signal_trap TERM' TERM
  trap 'hss_signal_trap HUP' HUP
}