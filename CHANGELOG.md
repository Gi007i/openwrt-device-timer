# Changelog

## [1.0.1] - 2026-02-15

### Fixed
- Firewall rules now apply to all zones (`src='*'` instead of `src='lan'`)
- Fix broken prerm script causing "Command failed" during install/remove
- Remove redundant stop/start calls in prerm/postinst (handled by OpenWrt defaults)

### Added
- Auto-register opkg package feed on install for metadata and updates

### Changed
- Use `LUCI_MAINTAINER` and `LUCI_DESCRIPTION` for proper luci.mk integration
- Add conffiles block to preserve config on upgrade
- Fix setup_build_env.sh: shallow base feed clone, pre-compile Lua headers

## [1.0.0] - 2026-02-14

- Initial stable release
