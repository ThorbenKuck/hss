#!/bin/bash
set -euo pipefail

REPOSITORY="${HSS_REPOSITORY:-thorben/hss}"
INSTALL_ROOT="${HSS_CONTROL_ROOT:-/var/www/hss-control}"
API_URL="https://api.github.com/repos/${REPOSITORY}/releases/latest"
ARCHIVE_URL=$(curl --fail --silent --show-error --location "$API_URL" |
  sed -n 's/.*"browser_download_url":[[:space:]]*"\([^"]*hss-control\.tar\.gz\)".*/\1/p' | head -n 1)

if [ -z "$ARCHIVE_URL" ]; then
  echo "No hss-control.tar.gz asset found in the latest ${REPOSITORY} release." >&2
  exit 1
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
archive="$work_dir/hss-control.tar.gz"
curl --fail --silent --show-error --location "$ARCHIVE_URL" -o "$archive"
mkdir "$work_dir/content"
tar -xzf "$archive" -C "$work_dir/content"
test -f "$work_dir/content/index.html"

staging="$work_dir/staging"
mkdir "$staging"
cp -a "$work_dir/content/." "$staging/"
mkdir -p "$(dirname "$INSTALL_ROOT")"
if [ -d "$INSTALL_ROOT" ]; then
  rm -rf "${INSTALL_ROOT}.previous"
  mv "$INSTALL_ROOT" "${INSTALL_ROOT}.previous"
fi
mv "$staging" "$INSTALL_ROOT"
rm -rf "${INSTALL_ROOT}.previous"
chown -R root:root "$INSTALL_ROOT"
find "$INSTALL_ROOT" -type d -exec chmod 755 {} +
find "$INSTALL_ROOT" -type f -exec chmod 644 {} +
echo "Installed HSS Control in ${INSTALL_ROOT}."