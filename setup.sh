#!/bin/bash
set -euo pipefail

# Setup script to install Go via apt or manual tarball download

install_via_apt() {
    echo "Package manager apt found. Installing Go via apt..."
    sudo apt update
    sudo apt install -y golang
}

install_manually() {
    echo "Package manager apt not found. Installing Go manually..."

    # Detect system architecture
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) GO_ARCH="amd64" ;;
        aarch64|arm64) GO_ARCH="arm64" ;;
        armv7l) GO_ARCH="armv6l" ;;
        *) GO_ARCH="amd64" ;;
    esac

    GO_VERSION="1.23.1"
    TARBALL="go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
    DOWNLOAD_URL="https://go.dev/dl/${TARBALL}"

    echo "Downloading Go ${GO_VERSION} for ${GO_ARCH}..."
    curl -sSL "$DOWNLOAD_URL" -o "/tmp/${TARBALL}"

    echo "Extracting Go to /usr/local/go..."
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "/tmp/${TARBALL}"
    rm -f "/tmp/${TARBALL}"

    # Configure PATH in ~/.bashrc if not already present
    if ! grep -q '/usr/local/go/bin' "$HOME/.bashrc"; then
        echo 'export PATH=$PATH:/usr/local/go/bin' >> "$HOME/.bashrc"
        echo "Added Go binary path to $HOME/.bashrc"
    fi
}

# Check if apt command exists in environment PATH
if command -v apt >/dev/null 2>&1; then
    install_via_apt
else
    install_manually
fi

echo "Go installation process finished successfully."