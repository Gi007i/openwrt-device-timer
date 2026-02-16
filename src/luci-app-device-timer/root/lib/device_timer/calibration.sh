#!/bin/sh
# calibration.sh - Calibration logic (P90, samples, state machine) for device_timer daemon
# Requires globals: TEMP_DIR, log()
# Requires functions from: state.sh (get_cached_calibration_status, get_cached_calibration_data,
#                          queue_calibration_sample, queue_calibration_complete, fail_calibration)

# Calculate P90 from space-separated samples using calibration module
calculate_p90() {
    local samples="$1"

    if [ -z "$samples" ]; then
        echo "0"
        return
    fi

    ucode -e "
        const cal = call(loadfile('/usr/share/ucode/device_timer/calibration.uc'));
        const sampleArr = split('$samples', ' ');
        const result = cal.calculateP90(sampleArr);
        print(result);
    " 2>/dev/null || echo "0"
}

# Read calibration samples from state file
read_calibration_samples() {
    local device_id="$1"

    if [ ! -f "$STATE_FILE" ]; then
        return
    fi

    ucode -e "
        import { open } from 'fs';
        let f = open('$STATE_FILE', 'r');
        if (!f) exit(0);
        let state = json(f.read('all'));
        f.close();
        if (!state || !state.devices || !state.devices['$device_id']) exit(0);
        let cal = state.devices['$device_id'].calibration;
        if (!cal || !cal.samples || length(cal.samples) === 0) exit(0);

        for (let i = 0; i < length(cal.samples); i++) {
            print(cal.samples[i]);
            if (i < length(cal.samples) - 1) print(' ');
        }
    " 2>/dev/null
}

# Complete calibration and calculate P90
complete_calibration() {
    local device_id="$1"

    local samples=$(read_calibration_samples "$device_id")

    if [ -z "$samples" ]; then
        fail_calibration "$device_id" "No samples collected"
        return 1
    fi

    local p90=$(calculate_p90 "$samples")

    if [ -z "$p90" ] || ! echo "$p90" | grep -qE '^[0-9]+$'; then
        fail_calibration "$device_id" "Failed to calculate P90"
        return 1
    fi

    # Recommended threshold = P90 * 1.5 (50% buffer)
    local recommended=$(awk "BEGIN { print int($p90 * 1.5) }" 2>/dev/null)
    recommended=${recommended:-0}

    queue_calibration_complete "$device_id" "$p90" "$recommended"
    log "[$device_id] Calibration completed: P90=$p90, recommended=$recommended"
}

# Collect a calibration sample
collect_calibration_sample() {
    local device_id="$1"
    local device_ip="$2"
    local current_time="$3"
    local prev_counter="$4"

    local NFT_TABLE="inet device_timer_$device_id"

    local nft_output=$(nft list table $NFT_TABLE 2>/dev/null)
    if [ -z "$nft_output" ]; then
        fail_calibration "$device_id" "nftables table not found"
        return 1
    fi

    local saddr_usage=$(echo "$nft_output" | grep "ip saddr $device_ip counter" | grep -o 'bytes [0-9]*' | awk '{sum += $2} END {print sum+0}')
    local daddr_usage=$(echo "$nft_output" | grep "ip daddr $device_ip counter" | grep -o 'bytes [0-9]*' | awk '{sum += $2} END {print sum+0}')

    saddr_usage=${saddr_usage:-0}
    daddr_usage=${daddr_usage:-0}

    local total_usage=$((saddr_usage + daddr_usage))
    local traffic_delta=$((total_usage - prev_counter))

    # Handle counter reset
    if [ "$traffic_delta" -lt 0 ]; then
        traffic_delta=$total_usage
    fi

    # Save last_counter=0 because nft counters are reset after each poll
    queue_calibration_sample "$device_id" "$traffic_delta" "0" "$current_time"
    log "[$device_id] Calibration sample: $traffic_delta bytes"
}

# Process calibration for a device (called after IP resolution)
process_calibration() {
    local device_id="$1"
    local device_ip="$2"
    local current_time="$3"

    local cal_status=$(get_cached_calibration_status "$device_id")
    [ "$cal_status" != "running" ] && return 0

    local cal_data=$(get_cached_calibration_data "$device_id")
    local start_time=$(echo "$cal_data" | cut -d'|' -f1)
    local duration=$(echo "$cal_data" | cut -d'|' -f2)
    local sample_interval=$(echo "$cal_data" | cut -d'|' -f3)
    local last_sample_time=$(echo "$cal_data" | cut -d'|' -f4)
    local last_counter=$(echo "$cal_data" | cut -d'|' -f5)

    local elapsed=$((current_time - start_time))

    # Calibration complete?
    if [ "$elapsed" -ge "$duration" ]; then
        complete_calibration "$device_id"
        return 0
    fi

    # Sample interval elapsed?
    local sample_elapsed=$((current_time - last_sample_time))
    if [ "$sample_elapsed" -ge "$sample_interval" ]; then
        collect_calibration_sample "$device_id" "$device_ip" "$current_time" "$last_counter"
    fi
}
