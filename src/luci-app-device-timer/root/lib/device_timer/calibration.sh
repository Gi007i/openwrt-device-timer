#!/bin/sh
# calibration.sh - Two-phase calibration logic for device_timer daemon
# Phase 1: Idle measurement, Phase 2: Usage measurement, Result: geometric mean threshold
# Requires globals: TEMP_DIR, log()
# Requires functions from: state.sh (get_cached_calibration_status, get_cached_calibration_data,
#                          queue_calibration_sample_p1, queue_calibration_sample_p2,
#                          queue_calibration_phase1_done, queue_calibration_complete, fail_calibration)

# Read calibration samples from state file (phase1 or phase2)
read_calibration_samples() {
    local device_id="$1"
    local phase="$2"

    if [ ! -f "$STATE_FILE" ]; then
        return
    fi

    local field="${phase}_samples"

    ucode -e "
        import { open } from 'fs';
        let f = open('$STATE_FILE', 'r');
        if (!f) exit(0);
        let state = json(f.read('all'));
        f.close();
        if (!state || !state.devices || !state.devices['$device_id']) exit(0);
        let cal = state.devices['$device_id'].calibration;
        if (!cal || !cal['$field'] || length(cal['$field']) === 0) exit(0);

        for (let i = 0; i < length(cal['$field']); i++) {
            print(cal['$field'][i]);
            if (i < length(cal['$field']) - 1) print(' ');
        }
    " 2>/dev/null
}

# Complete calibration using two-phase analysis (geometric mean)
complete_calibration() {
    local device_id="$1"

    local idle_samples=$(read_calibration_samples "$device_id" "phase1")
    local usage_samples=$(read_calibration_samples "$device_id" "phase2")

    if [ -z "$idle_samples" ]; then
        fail_calibration "$device_id" "No idle samples collected"
        return 1
    fi

    if [ -z "$usage_samples" ]; then
        fail_calibration "$device_id" "No usage samples collected"
        return 1
    fi

    # Run analyzeCalibration via ucode
    local result
    result=$(ucode -e "
        const cal = call(loadfile('/usr/share/ucode/device_timer/calibration.uc'));
        const idleArr = split('$idle_samples', ' ');
        const usageArr = split('$usage_samples', ' ');
        const r = cal.analyzeCalibration(idleArr, usageArr);
        if (r.error) {
            print('ERROR:' + r.error);
        } else {
            let overlap = (r.idle_p95 >= r.stream_p5) ? 1 : 0;
            print(r.idle_p95 + '|' + r.idle_median + '|' + r.stream_p5 + '|' + r.stream_median + '|' + r.stream_outliers + '|' + r.recommended + '|' + overlap);
        }
    " 2>/dev/null)

    case "$result" in
        ERROR:*)
            fail_calibration "$device_id" "${result#ERROR:}"
            return 1
            ;;
        "")
            fail_calibration "$device_id" "Failed to analyze calibration data"
            return 1
            ;;
    esac

    local idle_p95=$(echo "$result" | cut -d'|' -f1)
    local idle_median=$(echo "$result" | cut -d'|' -f2)
    local stream_p5=$(echo "$result" | cut -d'|' -f3)
    local stream_median=$(echo "$result" | cut -d'|' -f4)
    local stream_outliers=$(echo "$result" | cut -d'|' -f5)
    local recommended=$(echo "$result" | cut -d'|' -f6)
    local overlap=$(echo "$result" | cut -d'|' -f7)

    queue_calibration_complete "$device_id" "$idle_p95" "$idle_median" "$stream_p5" "$stream_median" "$stream_outliers" "$recommended" "$overlap"
    log "[$device_id] Calibration completed: idle_p95=$idle_p95, stream_p5=$stream_p5, recommended=$recommended"
}

# Collect a calibration sample (works for both phases)
# nft counters are reset each poll cycle, so total_usage = traffic since last poll
collect_calibration_sample() {
    local device_id="$1"
    local device_ip="$2"
    local current_time="$3"
    local phase="$4"

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

    if [ "$phase" = "phase1" ]; then
        queue_calibration_sample_p1 "$device_id" "$total_usage" "$current_time"
    else
        queue_calibration_sample_p2 "$device_id" "$total_usage" "$current_time"
    fi
    log "[$device_id] Calibration $phase sample: $total_usage bytes"
}

# Process calibration for a device (called after IP resolution)
process_calibration() {
    local device_id="$1"
    local device_ip="$2"
    local current_time="$3"

    local cal_status=$(get_cached_calibration_status "$device_id")

    # Only process active calibration phases (+ timeout check for phase1_done)
    case "$cal_status" in
        phase1_running) ;;
        phase2_running) ;;
        phase1_done)
            # Timeout: auto-reset if user doesn't start phase 2 within 1 hour
            local timeout_data=$(get_cached_calibration_data "$device_id")
            local timeout_start=$(echo "$timeout_data" | cut -d'|' -f1)
            local timeout_idle_dur=$(echo "$timeout_data" | cut -d'|' -f2)
            local phase1_end=$((timeout_start + timeout_idle_dur))
            local idle_time=$((current_time - phase1_end))
            if [ "$idle_time" -gt 3600 ]; then
                fail_calibration "$device_id" "Timeout waiting for phase 2"
                log "[$device_id] Calibration phase1_done timeout (${idle_time}s)"
            fi
            return 0
            ;;
        *) return 0 ;;
    esac

    local cal_data=$(get_cached_calibration_data "$device_id")
    local start_time=$(echo "$cal_data" | cut -d'|' -f1)
    local idle_duration=$(echo "$cal_data" | cut -d'|' -f2)
    local p2_start=$(echo "$cal_data" | cut -d'|' -f4)
    local usage_duration=$(echo "$cal_data" | cut -d'|' -f5)

    if [ "$cal_status" = "phase1_running" ]; then
        local elapsed=$((current_time - start_time))

        # Phase 1 complete?
        if [ "$elapsed" -ge "$idle_duration" ]; then
            queue_calibration_phase1_done "$device_id"
            log "[$device_id] Phase 1 (idle) completed after ${elapsed}s"
            return 0
        fi

        # Collect idle sample (every poll interval)
        collect_calibration_sample "$device_id" "$device_ip" "$current_time" "phase1"

    elif [ "$cal_status" = "phase2_running" ]; then
        usage_duration=${usage_duration:-0}

        local elapsed=$((current_time - p2_start))

        # Phase 2 complete?
        if [ "$elapsed" -ge "$usage_duration" ]; then
            complete_calibration "$device_id"
            return 0
        fi

        # Collect usage sample (every poll interval)
        collect_calibration_sample "$device_id" "$device_ip" "$current_time" "phase2"
    fi
}
