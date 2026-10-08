# Shared terminal presentation helpers.

HSS_COLOR_RESET=$'\033[0m'
HSS_COLOR_BLUE=$'\033[1;34m'
HSS_COLOR_CYAN=$'\033[1;36m'
HSS_COLOR_GREEN=$'\033[1;32m'
HSS_COLOR_RED=$'\033[1;31m'
HSS_COLOR_YELLOW=$'\033[1;33m'
HSS_UI_STEP=0
HSS_UI_TOTAL_STEPS=0

ui_init() {
  if [ ! -t 1 ] || [ -n "${NO_COLOR:-}" ]; then
    HSS_COLOR_RESET=""
    HSS_COLOR_BLUE=""
    HSS_COLOR_CYAN=""
    HSS_COLOR_GREEN=""
    HSS_COLOR_RED=""
    HSS_COLOR_YELLOW=""
  fi
}

ui_set_total_steps() {
  HSS_UI_TOTAL_STEPS="$1"
}

ui_header() {
  local role="$1"

  printf '\n%b============================================================%b\n' "$HSS_COLOR_BLUE" "$HSS_COLOR_RESET"
  printf '%bHSS %s SETUP%b\n' "$HSS_COLOR_CYAN" "$role" "$HSS_COLOR_RESET"
  printf '%b============================================================%b\n\n' "$HSS_COLOR_BLUE" "$HSS_COLOR_RESET"
}

ui_section() {
  printf '\n%b%s%b\n' "$HSS_COLOR_CYAN" "$1" "$HSS_COLOR_RESET"
}

ui_step() {
  HSS_UI_STEP=$((HSS_UI_STEP + 1))
  printf '%b[%02d/%02d]%b %s\n' \
    "$HSS_COLOR_BLUE" "$HSS_UI_STEP" "$HSS_UI_TOTAL_STEPS" "$HSS_COLOR_RESET" "$1"
}

ui_action() {
  printf '  %b->%b %s\n' "$HSS_COLOR_BLUE" "$HSS_COLOR_RESET" "$1"
}

ui_info() {
  printf '  %bINFO%b: %s\n' "$HSS_COLOR_CYAN" "$HSS_COLOR_RESET" "$1"
}

ui_success() {
  printf '  %bOK%b: %s\n' "$HSS_COLOR_GREEN" "$HSS_COLOR_RESET" "$1"
}

ui_warning() {
  printf '  %bWARN%b: %s\n' "$HSS_COLOR_YELLOW" "$HSS_COLOR_RESET" "$1" >&2
}

ui_error() {
  printf '  %bERROR%b: %s\n' "$HSS_COLOR_RED" "$HSS_COLOR_RESET" "$1" >&2
}

ui_config_item() {
  printf '  %-30s %s\n' "$1:" "$2"
}

ui_summary_start() {
  printf '\n%b============================================================%b\n' "$HSS_COLOR_GREEN" "$HSS_COLOR_RESET"
  printf '%b%s%b\n' "$HSS_COLOR_GREEN" "$1" "$HSS_COLOR_RESET"
  printf '%b============================================================%b\n' "$HSS_COLOR_GREEN" "$HSS_COLOR_RESET"
}

ui_summary_item() {
  printf '  %b%-12s%b %s\n' "$HSS_COLOR_GREEN" "$1:" "$HSS_COLOR_RESET" "$2"
}

ui_summary_end() {
  printf '%b============================================================%b\n\n' "$HSS_COLOR_GREEN" "$HSS_COLOR_RESET"
}