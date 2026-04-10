#!/bin/sh
# device_timer_daemon.sh - procd-managed daemon for device monitoring

umask 0077
PATH="/usr/sbin:/usr/bin:/sbin:/bin"

TEMP_DIR="/tmp/device_timer"
PID_FILE="/var/run/device_timer.pid"
LAST_DATE_FILE="$TEMP_DIR/last_date"
STATE_FILE="$TEMP_DIR/state.json"
POLL_INTERVAL=60
FIREWALL_NEEDS_RELOAD=0
FIREWALL_NEEDS_COMMIT=0
CLEANUP_COUNTER=0
CLEANUP_INTERVAL=10
LAST_GLOBAL_ENABLED=""
FLOW_OFFLOAD_WARNED=""

log() {
	logger -t device_timer "$1"
}

. /lib/functions.sh
. /lib/device_timer/state.sh
. /lib/device_timer/firewall.sh
. /lib/device_timer/schedule.sh
. /lib/device_timer/calibration.sh

load_config() {
	local threshold=$(uci get device_timer.settings.default_threshold 2>/dev/null || echo "6M")
	GLOBAL_ENABLED=$(uci get device_timer.settings.enabled 2>/dev/null || echo "1")
	POLL_INTERVAL=$(uci get device_timer.settings.poll_interval 2>/dev/null || echo "60")
	SYSTEM_TZ=$(uci get system.@system[0].timezone 2>/dev/null || echo "UTC")

	local threshold_value=$(echo "$threshold" | sed 's/[KkMm]$//')
	local threshold_unit=$(echo "$threshold" | grep -o '[KkMm]$')

	if ! echo "$threshold_value" | grep -qE '^[0-9]+$'; then
		threshold_value=6
		threshold_unit="M"
	fi

	case "$threshold_unit" in
		K|k) TRAFFIC_THRESHOLD=$((threshold_value * 1024)) ;;
		M|m) TRAFFIC_THRESHOLD=$((threshold_value * 1024 * 1024)) ;;
		*)   TRAFFIC_THRESHOLD=$((threshold_value * 1024 * 1024)) ;;
	esac

	if [ "$TRAFFIC_THRESHOLD" -le 0 ]; then
		TRAFFIC_THRESHOLD=$((6 * 1024 * 1024))
	fi

	if ! echo "$POLL_INTERVAL" | grep -qE '^[0-9]+$'; then
		POLL_INTERVAL=60
	elif [ "$POLL_INTERVAL" -lt 10 ]; then
		POLL_INTERVAL=10
	elif [ "$POLL_INTERVAL" -gt 300 ]; then
		POLL_INTERVAL=300
	fi

	# Prevent command injection via TZ
	if ! echo "$SYSTEM_TZ" | grep -qE "^[A-Za-z0-9+:/.,' -]+$"; then
		SYSTEM_TZ="UTC"
	fi

	# Warn once if flow offloading is active (reduces nftables counter accuracy)
	if [ -z "$FLOW_OFFLOAD_WARNED" ]; then
		local flow_offload=$(uci -q get firewall.@defaults[0].flow_offloading)
		if [ "$flow_offload" = "1" ]; then
			log "Warning: Flow offloading active, traffic counters may be inaccurate"
		fi
		FLOW_OFFLOAD_WARNED=1
	fi
}

resolve_device_ip() {
	local mac="$1"
	local ip=""
	# ARP table (fast, no subprocess)
	ip=$(awk -v mac="$mac" 'tolower($4)==tolower(mac) {print $1; exit}' /proc/net/arp 2>/dev/null)
	# Fallback: DHCP leases
	if [ -z "$ip" ]; then
		local leasefile=$(uci -q get dhcp.@dnsmasq[0].leasefile)
		# Fallback: read from generated dnsmasq config
		if [ -z "$leasefile" ] || [ ! -f "$leasefile" ]; then
			leasefile=$(grep -sh 'dhcp-leasefile=' /var/etc/dnsmasq.conf.* 2>/dev/null | head -1 | cut -d= -f2)
		fi
		if [ -n "$leasefile" ] && [ -f "$leasefile" ]; then
			ip=$(awk -v mac="$mac" 'tolower($2)==tolower(mac) {print $3; exit}' "$leasefile" 2>/dev/null)
		fi
	fi
	echo "$ip"
}

monitor_device() {
	local device_id="$1"

	if ! echo "$device_id" | grep -qE '^[a-zA-Z0-9_]+$'; then
		log "Error: Invalid device_id format: $device_id"
		return
	fi

	local device_name device_mac device_enabled
	local active_schedule schedule_status active_timerange time_limit

	device_name=$(uci get device_timer.$device_id.name 2>/dev/null)
	device_mac=$(uci get device_timer.$device_id.mac 2>/dev/null | tr 'A-F' 'a-f')
	device_enabled=$(uci get device_timer.$device_id.enabled 2>/dev/null || echo "1")

	local current_time=$(date +%s)
	local current_day=$(LC_TIME=C TZ="$SYSTEM_TZ" date +%a)

	local FIREWALL_RULE_NAME="Block_Device_$device_id"
	local NFT_TABLE="inet device_timer_$device_id"

	local threshold="$TRAFFIC_THRESHOLD"
	local dev_threshold=$(uci get device_timer.$device_id.traffic_threshold 2>/dev/null)
	if [ -n "$dev_threshold" ]; then
		local dev_value=$(echo "$dev_threshold" | sed 's/[KkMm]$//')
		local dev_unit=$(echo "$dev_threshold" | grep -o '[KkMm]$')
		if echo "$dev_value" | grep -qE '^[0-9]+$'; then
			case "$dev_unit" in
				K|k) threshold=$((dev_value * 1024)) ;;
				M|m) threshold=$((dev_value * 1024 * 1024)) ;;
				*)   threshold=$((dev_value * 1024 * 1024)) ;;
			esac
			[ "$threshold" -le 0 ] && threshold="$TRAFFIC_THRESHOLD"
		fi
	fi

	# Validate MAC format (required for security and firewall operations)
	if [ -z "$device_mac" ]; then
		log "[$device_id] Error: MAC address missing"
		return
	fi
	if ! echo "$device_mac" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
		log "[$device_id] Error: Invalid MAC address format"
		return
	fi

	# If device monitoring is disabled, block device (default deny) and clean up
	if [ "$device_enabled" != "1" ]; then
		manage_firewall_rule "$device_id" "$device_mac" "$FIREWALL_RULE_NAME" "block"
		nft delete table $NFT_TABLE 2>/dev/null || true
		rm -f "$TEMP_DIR/${device_id}_nft_ip"
		return
	fi

	local device_ip=$(resolve_device_ip "$device_mac")

	# Validate IP format before using in nft commands (defense-in-depth)
	if [ -n "$device_ip" ] && ! echo "$device_ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
		log "[$device_id] Warning: Invalid IP format from ARP/DHCP, ignoring"
		device_ip=""
	fi

	# Stored IP as fallback (when ARP/DHCP empty but table exists)
	local stored_nft_ip=""
	[ -f "$TEMP_DIR/${device_id}_nft_ip" ] && stored_nft_ip=$(cat "$TEMP_DIR/${device_id}_nft_ip")
	if [ -n "$stored_nft_ip" ] && ! echo "$stored_nft_ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
		stored_nft_ip=""
	fi

	local nft_ip="${device_ip:-$stored_nft_ip}"

	# IP changed? -> Recreate nft table and flush old conntrack entries
	if [ -n "$device_ip" ] && [ -n "$stored_nft_ip" ] && [ "$stored_nft_ip" != "$device_ip" ]; then
		log "[$device_id] IP changed: $stored_nft_ip -> $device_ip, recreating nft table"
		CONNTRACK_FLUSH_IPS="$CONNTRACK_FLUSH_IPS $stored_nft_ip"
		nft flush table $NFT_TABLE 2>/dev/null
		nft delete table $NFT_TABLE 2>/dev/null || true
		nft_ip="$device_ip"
	fi

	# Create nft table for all enabled devices (needed for conntrack flush on block)
	if ! nft list table $NFT_TABLE > /dev/null 2>&1; then
		if [ -n "$nft_ip" ]; then
			log "[$device_id] Creating nft table (ip=$nft_ip)"
			if ! nft add table $NFT_TABLE; then
				log "[$device_id] Error: Failed to create nft table, blocking device"
				manage_firewall_rule "$device_id" "$device_mac" "$FIREWALL_RULE_NAME" "block"
				return
			fi
			if ! nft add chain $NFT_TABLE forward '{ type filter hook forward priority -10; }' || \
				! nft add rule $NFT_TABLE forward ip saddr $nft_ip counter || \
				! nft add rule $NFT_TABLE forward ip daddr $nft_ip counter; then
				log "[$device_id] Error: Failed to create nft rules, blocking device"
				nft delete table $NFT_TABLE 2>/dev/null || true
				manage_firewall_rule "$device_id" "$device_mac" "$FIREWALL_RULE_NAME" "block"
				return
			fi
			echo "$nft_ip" > "$TEMP_DIR/${device_id}_nft_ip"
		else
			log "[$device_id] Cannot resolve IP, skipping traffic monitoring"
		fi
	fi

	# Get active schedule (returns "active|timerange|limit", "no_schedule", or "outside_window")
	active_schedule=$(get_active_schedule "$device_id" "$current_day")
	schedule_status=$(echo "$active_schedule" | cut -d'|' -f1)

	case "$schedule_status" in
		no_schedule)
			manage_firewall_rule "$device_id" "$device_mac" "$FIREWALL_RULE_NAME" "block"
			# Reset usage: no active schedule, clean slate for when schedule is added
			local cached_flatrate=$(get_cached_flatrate "$device_id")
			cached_flatrate=${cached_flatrate:-0}
			local cached_paused=$(get_cached_paused "$device_id")
			cached_paused=${cached_paused:-0}
			queue_state_update "$device_id" 0 0 "$current_time" "" "$cached_flatrate" "$cached_paused"
			nft reset rules table $NFT_TABLE 2>/dev/null
			return
			;;
		outside_window)
			manage_firewall_rule "$device_id" "$device_mac" "$FIREWALL_RULE_NAME" "block"
			# Reset usage: each window gets its own quota
			local cached_flatrate=$(get_cached_flatrate "$device_id")
			cached_flatrate=${cached_flatrate:-0}
			local cached_paused=$(get_cached_paused "$device_id")
			cached_paused=${cached_paused:-0}
			queue_state_update "$device_id" 0 0 "$current_time" "" "$cached_flatrate" "$cached_paused"
			nft reset rules table $NFT_TABLE 2>/dev/null
			return
			;;
		active)
			active_timerange=$(echo "$active_schedule" | cut -d'|' -f2)
			time_limit=$(echo "$active_schedule" | cut -d'|' -f3)
			;;
	esac

	if [ -z "$time_limit" ] || ! echo "$time_limit" | grep -qE '^[0-9]+$'; then
		log "[$device_id] Error: Invalid time_limit in schedule, blocking device"
		manage_firewall_rule "$device_id" "$device_mac" "$FIREWALL_RULE_NAME" "block"
		return
	fi

	local window_id="${current_day},${active_timerange}"
	local stored_window=$(get_cached_window "$device_id")

	if [ -n "$nft_ip" ]; then
		process_calibration "$device_id" "$nft_ip" "$current_time"
	fi

	local nft_output=$(nft list table $NFT_TABLE 2>/dev/null)
	local saddr_usage=0
	local daddr_usage=0
	if [ -n "$nft_ip" ] && [ -n "$nft_output" ]; then
		saddr_usage=$(echo "$nft_output" | grep "ip saddr $nft_ip counter" | grep -o 'bytes [0-9]*' | awk '{sum += $2} END {print sum+0}')
		daddr_usage=$(echo "$nft_output" | grep "ip daddr $nft_ip counter" | grep -o 'bytes [0-9]*' | awk '{sum += $2} END {print sum+0}')
	fi

	saddr_usage=${saddr_usage:-0}
	daddr_usage=${daddr_usage:-0}

	if ! echo "$saddr_usage" | grep -qE '^[0-9]+$'; then
		saddr_usage=0
	fi

	if ! echo "$daddr_usage" | grep -qE '^[0-9]+$'; then
		daddr_usage=0
	fi

	local total_usage=$((saddr_usage + daddr_usage))

	local previous_usage=$(get_cached_state "$device_id" 3 0)
	local last_run_time=$(get_cached_state "$device_id" 4 0)
	local daily_usage=$(get_cached_state "$device_id" 2 0)

	# Reset usage on window change, preserve flatrate/paused flags
	local cached_flatrate=$(get_cached_flatrate "$device_id")
	cached_flatrate=${cached_flatrate:-0}
	local cached_paused=$(get_cached_paused "$device_id")
	cached_paused=${cached_paused:-0}
	if [ "$stored_window" != "$window_id" ]; then
		log "[$device_id] Window changed from ${stored_window:-none} to $window_id, resetting usage"
		daily_usage=0
		previous_usage=0
		last_run_time=$current_time
	fi

	if [ "$last_run_time" -eq 0 ]; then
		last_run_time=$current_time
	fi

	local usage_diff=$((total_usage - previous_usage))
	if [ "$usage_diff" -lt 0 ]; then
		usage_diff=$total_usage
	fi
	# Guard against counter overflow (unreasonably large delta, >2GB per interval)
	if [ "$usage_diff" -gt 2000000000 ]; then
		log "[$device_id] Warning: Unreasonable traffic delta ($usage_diff bytes), skipping"
		usage_diff=0
	fi

	local time_diff=$((current_time - last_run_time))

	# Handle clock jumps backwards (e.g., NTP corrections)
	if [ "$time_diff" -lt 0 ]; then
		log "[$device_id] Warning: Clock jumped backwards, skipping usage update"
		time_diff=0
	fi

	# Cap time_diff to 2*POLL_INTERVAL (state issue after outside_window period)
	local max_time_diff=$((POLL_INTERVAL * 2))
	if [ "$time_diff" -gt "$max_time_diff" ]; then
		log "[$device_id] Warning: time_diff too large ($(($time_diff/60)) min), capping to poll interval"
		time_diff=$POLL_INTERVAL
	fi

	# Flatrate only prevents blocking, not counting (keeps usage display consistent)
	local should_count_time=0
	if [ "$time_limit" -eq 0 ]; then
		should_count_time=1
	elif [ "$((daily_usage / 60))" -lt "$time_limit" ]; then
		# Under limit: count time (daily_usage is in seconds, time_limit in minutes)
		should_count_time=1
	fi
	if [ "$should_count_time" -eq 1 ]; then
		if [ "$usage_diff" -ge "$threshold" ]; then
			daily_usage=$((daily_usage + time_diff))
			log "[$device_id] Usage: $((daily_usage / 60)) min (total ${daily_usage}s)"
		fi
	fi

	# previous_usage=0 because nft counters are reset after each poll
	queue_state_update "$device_id" "$daily_usage" "0" "$current_time" "$window_id" "$cached_flatrate" "$cached_paused"

	# Priority: pause (block) > flatrate/limit=0 (unblock) > over limit (block)
	if [ "$cached_paused" -eq 1 ]; then
		manage_firewall_rule "$device_id" "$device_mac" "$FIREWALL_RULE_NAME" "block"
	elif [ "$cached_flatrate" -eq 1 ] || [ "$time_limit" -eq 0 ]; then
		manage_firewall_rule "$device_id" "$device_mac" "$FIREWALL_RULE_NAME" "unblock"
	elif [ "$((daily_usage / 60))" -ge "$time_limit" ]; then
		manage_firewall_rule "$device_id" "$device_mac" "$FIREWALL_RULE_NAME" "block"
	else
		manage_firewall_rule "$device_id" "$device_mac" "$FIREWALL_RULE_NAME" "unblock"
	fi

	nft reset rules table $NFT_TABLE 2>/dev/null
}

monitor_device_cb() {
	local cfg="$1"
	monitor_device "$cfg"
}

main() {
	trap cleanup TERM INT
	# USR1 from procd reload trigger: wake from sleep and run cleanup next cycle
	trap 'CLEANUP_COUNTER=$CLEANUP_INTERVAL' USR1

	mkdir -p -m 0700 "$TEMP_DIR"
	chmod 0700 "$TEMP_DIR"
	echo $$ > "${PID_FILE}.tmp" && mv "${PID_FILE}.tmp" "$PID_FILE"

	log "Daemon started (PID: $$)"

	rm -f "${STATE_FILE}.daemon.tmp" "${STATE_FILE}.cleanup.tmp" "${STATE_FILE}.updates"

	cleanup_orphaned_resources
	commit_firewall_changes

	if [ "$FIREWALL_NEEDS_RELOAD" -eq 1 ]; then
		if ! /etc/init.d/firewall reload; then
			log "Warning: Firewall reload failed on startup"
		fi
		FIREWALL_NEEDS_RELOAD=0
	fi

	while true; do
		load_config
		process_rpc_updates

		if [ "$GLOBAL_ENABLED" != "1" ]; then
			if [ "$LAST_GLOBAL_ENABLED" != "0" ]; then
				if disable_all_monitoring; then
					LAST_GLOBAL_ENABLED=0
				fi
			fi
			sleep "$POLL_INTERVAL" &
			wait $!
			continue
		fi
		LAST_GLOBAL_ENABLED=1

		check_midnight_reset

		CLEANUP_COUNTER=$((CLEANUP_COUNTER + 1))
		if [ "$CLEANUP_COUNTER" -ge "$CLEANUP_INTERVAL" ]; then
			cleanup_orphaned_resources
			CLEANUP_COUNTER=0
		fi

		read_all_states
		rm -f "${STATE_FILE}.updates"

		config_load device_timer
		config_foreach monitor_device_cb device

		if ! write_all_states; then
			log "Warning: Failed to write state file"
		fi

		commit_firewall_changes

		# Single firewall reload after all devices processed
		if [ "$FIREWALL_NEEDS_RELOAD" -eq 1 ]; then
			if ! /etc/init.d/firewall reload; then
				log "Warning: Firewall reload failed"
			fi
			FIREWALL_NEEDS_RELOAD=0
			# Kill established connections for newly blocked devices
			flush_conntrack_ips
		elif [ -n "$CONNTRACK_FLUSH_IPS" ]; then
			# Flush remaining entries (e.g., from IP changes without firewall rule changes)
			flush_conntrack_ips
		fi

		sleep "$POLL_INTERVAL" &
		wait $!
	done
}

main
