# Changelog

## [1.4.1] - 2026-03-10

### Fixed
- Fix package feed URL missing `/packages.adb` suffix (apk could not find package index)
- Fix permission denied errors during post-install by setting executable file modes in package

## [1.4.0] - 2026-03-10

### Changed
- Migrate to OpenWRT 25.12 with APK package manager (replaces opkg/IPK)
- Build with OpenWRT SDK 25.12.0 (GCC 14.3.0)
- Use ECDSA P-256 feed signing (replaces Ed25519/usign)

## [1.3.2] - 2026-03-03

### Changed
- Add download mirrors

## [1.3.1] - 2026-03-03

### Fixed
- Block disabled devices by default instead of allowing unrestricted access (default-deny)
- Prevent midnight reset from unblocking disabled devices
- Write explicit UCI value on enabled flag toggle instead of deleting the option

## [1.3.0] - 2026-03-03

### Fixed
- Fix blocked devices retaining internet access through established TCP connections
- Fix conntrack flush unavailable for devices without active schedule (no_schedule, outside_window)
- Fix stale conntrack entries persisting after device IP change (DHCP renewal)
- Fix conntrack flush queue not drained when no firewall reload occurred
- Fix calibration threshold apply bypassing standard save & apply workflow
- Fix calibration success notification hidden behind edit modal

### Changed
- Use nft chain priority -10 instead of 0 to ensure traffic counting before firewall4 evaluation
- Create nft monitoring tables for all enabled devices regardless of schedule state

## [1.2.1] - 2026-02-28

### Fixed
- Fix orphaned firewall rules not deleted when removing a device with multiple devices configured
- Trigger immediate cleanup on config change instead of waiting up to 10 minutes

## [1.2.0] - 2026-02-27

### Added
- Two-phase calibration: separate idle and usage measurement with geometric mean threshold
- Pause API to temporarily block device internet access (overrides flatrate)

### Fixed
- Reset usage on schedule window change to prevent stale usage blocking new windows
- Clean up partial nftables table on rule creation failure
- Log warning on state file write failure instead of silent continue
- Guard against unreasonable traffic counter deltas
- Prevent arithmetic error on empty cached state values
- Fix redundant state file reads per device in status API
- Fix variable shadowing in calibration parameter validation
- Add device existence check to calibration status API
- Guard against null content in PID and date file reads
- Persist calibration duration selection across page reloads
- Prevent poll updates from overwriting calibration state after user action
- Add error handling on all calibration RPC calls
- Unblock devices immediately at midnight reset
- Prevent date inconsistency in schedule evaluation at day change
- Use batch commit pattern in orphaned resource cleanup
- Prevent potential rpcd crash from function calls in uci.foreach

### Documentation
- Update api-reference with calibration and pause endpoints

## [1.1.0] - 2026-02-25

### Added
- Automated release pipeline for GitLab and GitHub
- Direct IPK download URLs in installation instructions

### Changed
- Replace hardcoded platform URLs with `__PAGES_URL__` placeholder for CI/CD substitution
- Package feed URL and signing key URL are now set automatically during build
- Pages redirect uses CI/CD variables instead of hardcoded repository URL

## [1.0.3] - 2026-02-24

### Fixed
- Config reload no longer causes state loss (signal-based instead of restart)
- RPC commands no longer lost under concurrent access
- Daemon recovers from corrupt state.json
- nft counter reset in midnight reset function
- IP format validation before nft commands
- Command injection in config validator log output
- prerm firewall rule cleanup matching too broadly
- Default state version mismatch

### Changed
- Batch firewall UCI commits per cycle instead of per device
- Remove redundant config reload in schedule evaluation

### Documentation
- Fix api-reference terminology and add missing field descriptions

## [1.0.2] - 2026-02-23

### Fixed
- Fix nftables counter reset using `nft reset rules` instead of `nft reset counters` (anonymous counters were never reset, causing cumulative traffic values and incorrect usage detection)

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
