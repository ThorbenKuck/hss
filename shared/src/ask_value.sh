# Prompt for a value with a default option.
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