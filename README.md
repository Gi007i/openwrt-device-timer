# OpenWRT Device Timer

![OpenWRT](https://img.shields.io/badge/OpenWRT-24.10-00B5E2?style=flat-square&logo=openwrt&logoColor=white)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)
![Shell](https://img.shields.io/badge/shell-POSIX%20sh-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)

LuCI app for monitoring and limiting the usage time of network devices. Automatically blocks devices via firewall rules when the configured daily limit is reached.

## System Requirements

- OpenWRT 24.10 or higher

## Features

- **LuCI web interface** for configuration and real-time status display
- Multiple devices with individual daily limits and time windows per weekday
- Traffic-based activity detection via nftables with automatic threshold calibration
- Immediate blocking through MAC-based firewall rules and conntrack flush
- Flatrate mode for temporarily unlimited access
- Automatic midnight reset of all counters
- procd daemon with respawn and signal-based RPC communication

## Installation

### Via LuCI Web Interface

1. In LuCI go to **System → Software**
2. Under **Download and install package**, paste this URL and click **OK**:
   ```
   https://gi007i.github.io/openwrt-device-timer/packages/luci-app-device-timer_1.0.1-r1_all.ipk
   ```
3. Repeat for the German translation:
   ```
   https://gi007i.github.io/openwrt-device-timer/packages/luci-i18n-device-timer-de_1.0.1-1_all.ipk
   ```

This installs the package, the feed signing key and registers the package feed automatically. Future updates are available through **System → Software → Updates**.

### Via SSH

```sh
wget -O /etc/opkg/keys/608ca90e3cad75e0 https://gi007i.github.io/openwrt-device-timer/keys/608ca90e3cad75e0
echo 'src/gz device_timer https://gi007i.github.io/openwrt-device-timer/packages' >> /etc/opkg/customfeeds.conf
opkg update
opkg install luci-app-device-timer luci-i18n-device-timer-de
```

Future updates are available through `opkg upgrade`.

## Configuration

Via **Services → Device Timer** in LuCI or using UCI:

```sh
uci set device_timer.tablet=device
uci set device_timer.tablet.name='Tablet Kid'
uci set device_timer.tablet.mac='aa:bb:cc:dd:ee:ff'
uci add_list device_timer.tablet.schedule='Mon,14:00-18:00,60'
uci add_list device_timer.tablet.schedule='Sat,10:00-20:00,120'
uci commit device_timer
service device_timer reload
```

The schedule format is `Day,Start-End,Limit` — limit in minutes, `0` for unlimited.

## Dependencies

`luci-base`, `rpcd`, `rpcd-mod-ucode`

## API

The device timer exposes a ubus JSON-RPC interface for programmatic access.

**[API Reference](docs/api-reference.md)** — full endpoint documentation with examples.

## Uninstall

```sh
opkg remove luci-app-device-timer luci-i18n-device-timer-de
```

Configuration files are preserved and can be removed manually:

```sh
rm /etc/config/device_timer
```

## License

[MIT](LICENSE)
