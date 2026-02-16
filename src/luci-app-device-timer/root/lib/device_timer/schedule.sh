#!/bin/sh
# schedule.sh - Schedule logic, time windows, and midnight reset for device_timer daemon
# Requires globals: SYSTEM_TZ, LAST_DATE_FILE, log()
# Requires functions from: state.sh (reset_device_state, write_all_states),
#                          firewall.sh (manage_firewall_rule)

# Get active schedule for today
# Returns: "active|timerange|limit" or "no_schedule" or "outside_window"
# Format: "Mon,14:00-18:00,60" (Day,TimeRange,Limit)
get_active_schedule() {
    local device_id="$1"
    local current_day=$(LC_TIME=C TZ="$SYSTEM_TZ" date +%a)
    local found_today=0
    local active_timerange=""
    local active_limit=""

    check_schedule_entry() {
        local entry="$1"
        # Format: "Mon,14:00-18:00,60"
        local day=$(echo "$entry" | cut -d',' -f1)

        [ "$day" != "$current_day" ] && return

        found_today=1
        local timerange=$(echo "$entry" | cut -d',' -f2)
        local slot_limit=$(echo "$entry" | cut -d',' -f3)

        # Check if currently in this time window
        # Only use first matching window (consistent with web UI)
        if [ -z "$active_timerange" ] && is_in_time_window "$timerange"; then
            active_timerange="$timerange"
            active_limit="$slot_limit"
        fi
    }

    config_load device_timer
    config_list_foreach "$device_id" schedule check_schedule_entry

    if [ "$found_today" -eq 0 ]; then
        echo "no_schedule"
    elif [ -n "$active_timerange" ]; then
        echo "active|$active_timerange|$active_limit"
    else
        echo "outside_window"
    fi
}

is_in_time_window() {
    local timerange="$1"

    # No timerange = blocked
    [ -z "$timerange" ] && return 1

    # Get current time (remove leading zeros to prevent octal interpretation)
    local cur_hour=$(TZ="$SYSTEM_TZ" date +%H)
    local cur_min=$(TZ="$SYSTEM_TZ" date +%M)
    cur_hour=${cur_hour#0}
    cur_min=${cur_min#0}
    local current_minutes=$((cur_hour * 60 + cur_min))

    # Parse time range "HH:MM-HH:MM"
    local time_start=$(echo "$timerange" | cut -d'-' -f1)
    local time_end=$(echo "$timerange" | cut -d'-' -f2)

    # Parse start time (remove leading zeros)
    local start_hour=$(echo "$time_start" | cut -d: -f1)
    local start_min=$(echo "$time_start" | cut -d: -f2)
    start_hour=${start_hour#0}
    start_min=${start_min#0}
    local start_minutes=$((start_hour * 60 + start_min))

    # Parse end time (remove leading zeros)
    local end_hour=$(echo "$time_end" | cut -d: -f1)
    local end_min=$(echo "$time_end" | cut -d: -f2)
    end_hour=${end_hour#0}
    end_min=${end_min#0}
    local end_minutes=$((end_hour * 60 + end_min))

    # Check if current time is within window
    if [ "$start_minutes" -le "$end_minutes" ]; then
        # Normal case: e.g., 14:00-18:00
        [ "$current_minutes" -ge "$start_minutes" ] && [ "$current_minutes" -lt "$end_minutes" ]
    else
        # Overnight case: e.g., 22:00-06:00
        [ "$current_minutes" -ge "$start_minutes" ] || [ "$current_minutes" -lt "$end_minutes" ]
    fi
}

reset_device() {
    local device_id="$1"
    local device_mac
    local FIREWALL_RULE_NAME="Block_Device_$device_id"
    local NFT_TABLE="inet device_timer_$device_id"

    # Reset device state in JSON
    reset_device_state "$device_id"

    # Reset nftables counters to prevent old traffic from being counted
    nft reset counters table $NFT_TABLE 2>/dev/null

    # Also unblock device on reset (new day)
    device_mac=$(uci get device_timer.$device_id.mac 2>/dev/null | tr 'A-F' 'a-f')
    # Validate MAC format before using
    if [ -n "$device_mac" ] && echo "$device_mac" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
        manage_firewall_rule "$device_id" "$device_mac" "$FIREWALL_RULE_NAME" "unblock"
    fi

    log "[$device_id] Counters reset and firewall unblocked"
}

reset_device_cb() {
    local cfg="$1"
    reset_device "$cfg"
}

check_midnight_reset() {
    local current_date=$(TZ="$SYSTEM_TZ" date +%Y-%m-%d)
    local last_date=""

    if [ -f "$LAST_DATE_FILE" ]; then
        last_date=$(cat "$LAST_DATE_FILE")
    fi

    if [ "$current_date" != "$last_date" ]; then
        log "Date changed from $last_date to $current_date, resetting all devices"

        config_load device_timer
        config_foreach reset_device_cb device

        # Write queued reset states immediately
        write_all_states

        echo "$current_date" > "$LAST_DATE_FILE"
    fi
}
