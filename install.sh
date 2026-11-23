#!/bin/sh
# install.sh - Add the signed package feed and install luci-app-device-timer

set -eu

FEED_URL="https://Gi007i.github.io/openwrt-device-timer"
KEY_FILE="/etc/apk/keys/device-timer.pem"
REPO_FILE="/etc/apk/repositories.d/device-timer.list"

die() {
	echo "Error: $1" >&2
	exit 1
}

main() {
	[ "$(id -u)" -eq 0 ] || die "must be run as root"
	command -v apk >/dev/null 2>&1 || die "apk not found, OpenWrt 25.12 or newer required"

	tmp_key="$(mktemp)"
	trap 'rm -f "$tmp_key"' EXIT

	echo "Adding signing key"
	wget -q -O "$tmp_key" "$FEED_URL/keys/device-timer.pem"
	chmod 644 "$tmp_key"
	mv "$tmp_key" "$KEY_FILE"

	echo "Adding package feed"
	echo "$FEED_URL/packages/packages.adb" > "$REPO_FILE"

	echo "Installing packages"
	apk update
	apk add luci-app-device-timer luci-i18n-device-timer-de

	echo "Done. Open LuCI: Services -> Device Timer"
}

main "$@"
