#!/bin/bash
set -euo pipefail

REPOSITORY="${HSS_REPOSITORY:-ThorbenKuck/hss}"
INSTALL_ROOT="${HSS_CONTROL_ROOT:-/var/www/hss-control}"
DOWNLOAD_URL="https://github.com/${REPOSITORY}/releases/latest/download/hss-control.tar.gz"

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
archive="$work_dir/hss-control.tar.gz"

echo "Fetching hss-control artifact from ${DOWNLOAD_URL}..."
curl --fail --silent --show-error --location "$DOWNLOAD_URL" -o "$archive"

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