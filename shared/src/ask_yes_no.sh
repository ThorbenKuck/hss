# Ask a yes/no question with an optional default choice.
ask_yes_no() {
  local prompt_text="$1"
  local default_choice="${2:-Yes}"
  local response
  local prompt_suffix

  [ "${ASSUME_YES:-false}" = true ] && return 0

  case "$default_choice" in
    [yY]*) prompt_suffix='[Y/n]' ;;
    *) prompt_suffix='[y/N]' ;;
  esac

  while true; do
    if ! IFS= read -r -p "${prompt_text} ${prompt_suffix} [default: ${default_choice}]: " response; then
      ui_error "Unable to read an answer; refusing to continue without confirmation."
      return 1
    fi

    case "${response:-$default_choice}" in
      [yY]*)
        return 0
        ;;
      [nN]*)
        return 1
        ;;
      *)
        echo "Please answer explicitly with 'yes' or 'no'."
        ;;
    esac
  done
}