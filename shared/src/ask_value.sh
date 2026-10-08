# Prompt for a value with a default option.
ask_value() {
  local prompt_text="$1"
  local default_value="$2"
  local response

  if [ "${ASSUME_YES:-false}" = true ]; then
    echo "$default_value"
    return
  fi

  if ! IFS= read -r -p "${prompt_text} [default: ${default_value}]: " response; then
    echo "$default_value"
    return
  fi

  if [ -z "$response" ]; then
    echo "$default_value"
  else
    echo "$response"
  fi
}