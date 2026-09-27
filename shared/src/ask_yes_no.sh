# Ask a yes/no question with an optional default choice.
ask_yes_no() {
  local prompt_text="$1"
  local default_choice="${2:-Yes}"

  [ "${ASSUME_YES:-false}" = true ] && return 0

  while true; do
    read -rp "${prompt_text} [y/N] [default: ${default_choice}]: " response
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