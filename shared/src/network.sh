# Shared network and hostname configuration helpers.

network_set_hostname() {
  local hostname_value="$1"

  ui_action "Setting hostname to ${hostname_value}."
  hostnamectl set-hostname "$hostname_value"

  if grep -q '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t${hostname_value}/" /etc/hosts
  else
    printf '127.0.1.1\t%s\n' "$hostname_value" >> /etc/hosts
  fi
}

network_configure_hotspot() {
  local connection_name="$1"
  local ssid="$2"

  if ! command -v nmcli >/dev/null 2>&1; then
    ui_warning "NetworkManager is unavailable; skipping the ${connection_name} Wi-Fi fallback."
    return 0
  fi

  ui_action "Configuring the ${connection_name} Wi-Fi fallback."
  nmcli connection add type wifi ifname wlan0 mode ap \
    con-name "$connection_name" ssid "$ssid" 2>/dev/null || true
  nmcli connection modify "$connection_name" 802-11-wireless.band bg 2>/dev/null ||
    ui_warning "Could not set the Wi-Fi band for ${connection_name}."
  nmcli connection modify "$connection_name" 802-11-wireless.channel 6 2>/dev/null ||
    ui_warning "Could not set the Wi-Fi channel for ${connection_name}."
  nmcli connection modify "$connection_name" ipv4.method shared 2>/dev/null ||
    ui_warning "Could not enable shared IPv4 mode for ${connection_name}."
  nmcli connection modify "$connection_name" connection.autoconnect yes 2>/dev/null ||
    ui_warning "Could not enable autoconnect for ${connection_name}."
  nmcli connection modify "$connection_name" connection.autoconnect-priority -10 2>/dev/null ||
    ui_warning "Could not set autoconnect priority for ${connection_name}."
}