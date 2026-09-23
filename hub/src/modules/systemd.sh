reload_and_enable() {
  systemctl daemon-reload
  systemctl enable "$1"
}