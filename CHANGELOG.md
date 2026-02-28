# Changelog

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
- Add validation test script for router deployment (40 tests)

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
