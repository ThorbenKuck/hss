# Ask a yes/no question with an optional default choice.
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