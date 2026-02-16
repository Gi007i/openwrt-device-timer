#!/bin/sh
# device_timer_daemon.sh - procd-managed daemon for device monitoring

# Global variables (shared across all sourced modules)
TEMP_DIR="/tmp/device_timer"
PID_FILE="/var/run/device_timer.pid"
LAST_DATE_FILE="$TEMP_DIR/last_date"
STATE_FILE="$TEMP_DIR/state.json"
POLL_INTERVAL=60
FIREWALL_NEEDS_RELOAD=0
CLEANUP_COUNTER=0
CLEANUP_INTERVAL=10
LAST_GLOBAL_ENABLED=""

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

    # Parse combined threshold (e.g., "6M", "500K")
    local threshold_value=$(echo "$threshold" | sed 's/[KkMm]$//')
    local threshold_unit=$(echo "$threshold" | grep -o '[KkMm]$')

    # Validate threshold_value (must be numeric)
    if ! echo "$threshold_value" | grep -qE '^[0-9]+$'; then
        threshold_value=6
        threshold_unit="M"
    fi

    # Convert to bytes based on unit (1024-based)
    case "$threshold_unit" in
        K|k) TRAFFIC_THRESHOLD=$((threshold_value * 1024)) ;;
        M|m) TRAFFIC_THRESHOLD=$((threshold_value * 1024 * 1024)) ;;
        *)   TRAFFIC_THRESHOLD=$((threshold_value * 1024 * 1024)) ;;
    esac

    # Threshold must be > 0 (fallback to 6M)
    if [ "$TRAFFIC_THRESHOLD" -le 0 ]; then
        TRAFFIC_THRESHOLD=$((6 * 1024 * 1024))
    fi

    # Validate poll_interval (10-300 seconds)
    if ! echo "$POLL_INTERVAL" | grep -qE '^[0-9]+$'; then
        POLL_INTERVAL=60
    elif [ "$POLL_INTERVAL" -lt 10 ]; then
        POLL_INTERVAL=10
    elif [ "$POLL_INTERVAL" -gt 300 ]; then
        POLL_INTERVAL=300
    fi

    # Validate timezone (alphanumeric, +, -, :, /, ., ', space only)
    # Prevents command injection via TZ variable
    # Note: hyphen must be at end of character class for BusyBox grep
    if ! echo "$SYSTEM_TZ" | grep -qE "^[A-Za-z0-9+:/.,' -]+$"; then
        SYSTEM_TZ="UTC"
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
    local device_name device_mac device_enabled
    local active_schedule schedule_status active_timerange time_limit

    device_name=$(uci get device_timer.$device_id.name 2>/dev/null)
    device_mac=$(uci get device_timer.$device_id.mac 2>/dev/null | tr 'A-F' 'a-f')
    device_enabled=$(uci get device_timer.$device_id.enabled 2>/dev/null || echo "1")

    local current_time=$(date +%s)

    local FIREWALL_RULE_NAME="Block_Device_$device_id"
    local NFT_TABLE="inet device_timer_$device_id"

    # Get device-specific threshold or use global
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
            # Per-device threshold must be > 0 (fallback to global)
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

    # If device monitoring is disabled, ensure it's unblocked
    if [ "$device_enabled" != "1" ]; then
        manage_firewall_rule "$device_id" "$device_mac" "$FIREWALL_RULE_NAME" "unblock"
        return
    fi

    # Get active schedule (returns "active|timerange|limit", "no_schedule", or "outside_window")
    active_schedule=$(get_active_schedule "$device_id")
    schedule_status=$(echo "$active_schedule" | cut -d'|' -f1)

    case "$schedule_status" in
        no_schedule)
            manage_firewall_rule "$device_id" "$device_mac" "$FIREWALL_RULE_NAME" "block"
            # Update state to prevent time accumulation when schedule is added later
            local current_time=$(date +%s)
            local cached_flatrate=$(get_cached_flatrate "$device_id")
            local daily_usage=$(get_cached_state "$device_id" 2 0)
            queue_state_update "$device_id" "$daily_usage" 0 "$current_time" "" "$cached_flatrate"
            # Reset counters to prevent accumulation
            nft reset counters table $NFT_TABLE 2>/dev/null
            return
            ;;
        outside_window)
            manage_firewall_rule "$device_id" "$device_mac" "$FIREWALL_RULE_NAME" "block"
            # Update state to prevent large time_diff when window opens
            # This prevents counting the entire outside_window period as usage
            local current_time=$(date +%s)
            local cached_flatrate=$(get_cached_flatrate "$device_id")
            local daily_usage=$(get_cached_state "$device_id" 2 0)
            queue_state_update "$device_id" "$daily_usage" 0 "$current_time" "" "$cached_flatrate"
            # Reset counters to prevent accumulation
            nft reset counters table $NFT_TABLE 2>/dev/null
            return
            ;;
        active)
            active_timerange=$(echo "$active_schedule" | cut -d'|' -f2)
            time_limit=$(echo "$active_schedule" | cut -d'|' -f3)
            ;;
    esac

    # Validate time_limit from schedule
    if [ -z "$time_limit" ] || ! echo "$time_limit" | grep -qE '^[0-9]+$'; then
        log "[$device_id] Error: Invalid time_limit in schedule, blocking device"
        manage_firewall_rule "$device_id" "$device_mac" "$FIREWALL_RULE_NAME" "block"
        return
    fi

    # Build window identifier for tracking (Day,TimeRange)
    local current_day=$(LC_TIME=C TZ="$SYSTEM_TZ" date +%a)
    local window_id="${current_day},${active_timerange}"
    local stored_window=$(get_cached_window "$device_id")

    # Resolve device IP from MAC (for nftables traffic counting)
    local device_ip=$(resolve_device_ip "$device_mac")

    # Stored IP as fallback (when ARP/DHCP empty but table exists)
    local stored_nft_ip=""
    [ -f "$TEMP_DIR/${device_id}_nft_ip" ] && stored_nft_ip=$(cat "$TEMP_DIR/${device_id}_nft_ip")

    # Effective IP: current preferred, fallback to stored
    local nft_ip="${device_ip:-$stored_nft_ip}"

    # Process calibration (only with IP available)
    if [ -n "$nft_ip" ]; then
        process_calibration "$device_id" "$nft_ip" "$current_time"
    fi

    # IP changed? -> Recreate nft table
    if [ -n "$device_ip" ] && [ -n "$stored_nft_ip" ] && [ "$stored_nft_ip" != "$device_ip" ]; then
        log "[$device_id] IP changed: $stored_nft_ip -> $device_ip, recreating nft table"
        nft delete table $NFT_TABLE 2>/dev/null || true
        nft_ip="$device_ip"
    fi

    # Create nft table if not exists (use IP for reliable traffic counting)
    if ! nft list table $NFT_TABLE > /dev/null 2>&1; then
        if [ -n "$nft_ip" ]; then
            log "[$device_id] Creating nft table (ip=$nft_ip)"
            if ! nft add table $NFT_TABLE; then
                log "[$device_id] Error: Failed to create nft table, blocking device"
                manage_firewall_rule "$device_id" "$device_mac" "$FIREWALL_RULE_NAME" "block"
                return
            fi
            if ! nft add chain $NFT_TABLE forward '{ type filter hook forward priority 0; }' || \
               ! nft add rule $NFT_TABLE forward ip saddr $nft_ip counter || \
               ! nft add rule $NFT_TABLE forward ip daddr $nft_ip counter; then
                log "[$device_id] Error: Failed to create nft rules, blocking device"
                manage_firewall_rule "$device_id" "$device_mac" "$FIREWALL_RULE_NAME" "block"
                return
            fi
            echo "$nft_ip" > "$TEMP_DIR/${device_id}_nft_ip"
        else
            log "[$device_id] Cannot resolve IP, skipping traffic monitoring"
        fi
    fi

    # Read counters (with IP-based matching)
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

    # Read previous state from cached batch read
    local previous_usage=$(get_cached_state "$device_id" 3 0)
    local last_run_time=$(get_cached_state "$device_id" 4 0)
    local daily_usage=$(get_cached_state "$device_id" 2 0)

    # Reset usage on window change (each window gets its own quota)
    # Read flatrate before reset to preserve it
    local cached_flatrate=$(get_cached_flatrate "$device_id")
    if [ "$stored_window" != "$window_id" ]; then
        log "[$device_id] Window changed from ${stored_window:-none} to $window_id, resetting usage"
        daily_usage=0
        previous_usage=0
        last_run_time=$current_time
    fi

    # Initialize last_run_time if not set
    if [ "$last_run_time" -eq 0 ]; then
        last_run_time=$current_time
    fi

    local usage_diff=$((total_usage - previous_usage))
    if [ "$usage_diff" -lt 0 ]; then
        usage_diff=$total_usage
    fi

    local time_diff=$((current_time - last_run_time))

    # Handle clock jumps backwards (e.g., NTP corrections)
    if [ "$time_diff" -lt 0 ]; then
        log "[$device_id] Warning: Clock jumped backwards, skipping usage update"
        time_diff=0
    fi

    # Sanity check: time_diff should not exceed reasonable bounds
    # If larger than 2*POLL_INTERVAL, likely a state issue (e.g., after outside_window period)
    local max_time_diff=$((POLL_INTERVAL * 2))
    if [ "$time_diff" -gt "$max_time_diff" ]; then
        log "[$device_id] Warning: time_diff too large ($(($time_diff/60)) min), capping to poll interval"
        time_diff=$POLL_INTERVAL
    fi

    # Only count time if under limit (or unlimited)
    # Flatrate only prevents blocking, not counting - keeps usage display consistent
    local should_count_time=0
    if [ "$time_limit" -eq 0 ]; then
        # Unlimited: always count
        should_count_time=1
    elif [ "$((daily_usage / 60))" -lt "$time_limit" ]; then
        # Under limit: count time (daily_usage is in seconds, time_limit in minutes)
        should_count_time=1
    fi
    # At or over limit: should_count_time stays 0, no time counted (even with flatrate)

    if [ "$should_count_time" -eq 1 ]; then
        if [ "$usage_diff" -ge "$threshold" ]; then
            daily_usage=$((daily_usage + time_diff))
            log "[$device_id] Usage: $((daily_usage / 60)) min (total ${daily_usage}s)"
        fi
    fi

    # Queue state update for batch write
    # previous_usage=0 because nft counters are reset after each poll (line below)
    queue_state_update "$device_id" "$daily_usage" "0" "$current_time" "$window_id" "$cached_flatrate"

    # Flatrate: limit=0 means unlimited access (never block)
    # Flatrate flag also grants unlimited access (overrides limit check)
    if [ "$cached_flatrate" -eq 1 ] || [ "$time_limit" -eq 0 ]; then
        manage_firewall_rule "$device_id" "$device_mac" "$FIREWALL_RULE_NAME" "unblock"
    elif [ "$((daily_usage / 60))" -ge "$time_limit" ]; then
        manage_firewall_rule "$device_id" "$device_mac" "$FIREWALL_RULE_NAME" "block"
    else
        manage_firewall_rule "$device_id" "$device_mac" "$FIREWALL_RULE_NAME" "unblock"
    fi

    nft reset counters table $NFT_TABLE 2>/dev/null
}

monitor_device_cb() {
    local cfg="$1"
    monitor_device "$cfg"
}

main() {
    trap cleanup TERM INT
    trap 'true' USR1

    mkdir -p "$TEMP_DIR"
    echo $$ > "$PID_FILE"

    log "Daemon started (PID: $$)"

    # Cleanup orphaned resources on startup
    cleanup_orphaned_resources

    # Flush startup firewall changes if needed
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

        # Periodic cleanup of orphaned resources (every CLEANUP_INTERVAL cycles)
        CLEANUP_COUNTER=$((CLEANUP_COUNTER + 1))
        if [ "$CLEANUP_COUNTER" -ge "$CLEANUP_INTERVAL" ]; then
            cleanup_orphaned_resources
            CLEANUP_COUNTER=0
        fi

        read_all_states
        rm -f "${STATE_FILE}.updates"

        config_load device_timer
        config_foreach monitor_device_cb device

        write_all_states

        # Single firewall reload after all devices processed
        if [ "$FIREWALL_NEEDS_RELOAD" -eq 1 ]; then
            if ! /etc/init.d/firewall reload; then
                log "Warning: Firewall reload failed"
            fi
            FIREWALL_NEEDS_RELOAD=0
            # Kill established connections for newly blocked devices
            flush_conntrack_ips
        fi

        sleep "$POLL_INTERVAL" &
        wait $!
    done
}

main
