include $(TOPDIR)/rules.mk

PKG_VERSION:=1.0.1
PKG_RELEASE:=1
PKG_PO_VERSION:=$(PKG_VERSION)-$(PKG_RELEASE)

LUCI_TITLE:=LuCI support for Device Timer
LUCI_DESCRIPTION:=Usage time management for monitoring and limiting device usage
LUCI_DEPENDS:=+luci-base +rpcd +rpcd-mod-ucode
LUCI_PKGARCH:=all

LUCI_MAINTAINER:=Gi007i <gi034@h7.biz>

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE

define Package/luci-app-device-timer/conffiles
/etc/config/device_timer
endef

define Package/luci-app-device-timer/postinst
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	# Set executable permissions for scripts
	chmod +x /etc/init.d/device_timer 2>/dev/null
	chmod +x /usr/sbin/device_timer_daemon.sh 2>/dev/null
	chmod +x /usr/sbin/device_timer_validate 2>/dev/null
	chmod +x /lib/device_timer/*.sh 2>/dev/null

	# LuCI cache and rpcd (luci.mk default is skipped when custom postinst defined)
	rm -rf /tmp/luci-modulecache/ 2>/dev/null
	/etc/init.d/rpcd reload 2>/dev/null

	# Register package feed for updates and metadata
	FEED_LINE="src/gz device_timer https://gi007i.github.io/openwrt-device-timer/packages"
	if ! grep -q "device_timer" /etc/opkg/customfeeds.conf 2>/dev/null; then
		echo "$$FEED_LINE" >> /etc/opkg/customfeeds.conf
		opkg update 2>/dev/null
	fi

	# Note: enable/start and luci-indexcache handled by default_postinst
fi
exit 0
endef

define Package/luci-app-device-timer/prerm
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	# Note: stop/disable handled by default_prerm via init script

	# Remove Block_Device_* firewall rules
	changed=0
	for section in $$(uci -X -q show firewall | grep '=rule' | cut -d. -f2 | cut -d= -f1); do
		name=$$(uci -q get "firewall.$$section.name")
		case "$$name" in
			Block_Device_*)
				uci -q delete "firewall.$$section"
				changed=1
				;;
		esac
	done
	[ "$$changed" = "1" ] && uci commit firewall 2>/dev/null

	# Remove nftables tables
	for table in $$(nft list tables 2>/dev/null | grep 'inet device_timer_' | awk '{print $$3}'); do
		nft delete table inet "$$table" 2>/dev/null || true
	done

	# Clean up temp directory
	rm -rf /tmp/device_timer

	# Remove package feed
	sed -i '/device_timer/d' /etc/opkg/customfeeds.conf 2>/dev/null
fi
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
