# Changelog

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
