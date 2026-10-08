# Shared systemd service registration helpers.

systemd_reload() {
  systemctl daemon-reload
}

systemd_enable() {
  systemctl enable "$@"
}

systemd_enable_now() {
  systemctl enable --now "$@"
}

systemd_start() {
  systemctl start "$@"
}

systemd_restart() {
  systemctl restart "$@"
}

systemd_reload_service() {
  systemctl reload "$@"
}

systemd_mask_optional() {
  systemctl mask "$@" 2>/dev/null || true
}

systemd_reload_and_enable() {
  systemd_reload
  systemd_enable "$@"
}

systemd_reload_enable_now() {
  systemd_reload
  systemd_enable_now "$@"
}

systemd_disable_now_optional() {
  systemctl disable --now "$@" 2>/dev/null || true
}