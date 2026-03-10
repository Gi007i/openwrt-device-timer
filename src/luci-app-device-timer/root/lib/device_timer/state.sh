#!/bin/sh
# state.sh - State management for device_timer daemon
# Requires globals: STATE_FILE, TEMP_DIR, log()

# Batch state I/O: read all device states in one ucode call
# Output format: device_id\tusage\tprevious_usage\tlast_run_time\tactive_window\tflatrate\tpaused\tcal_status\tcal_start\tcal_idle_dur\tcal_last_sample\tcal_p2_start\tcal_usage_dur
# Stored in ALL_STATES global variable
read_all_states() {
    ALL_STATES=""
    if [ ! -f "$STATE_FILE" ]; then
        return
    fi

    ALL_STATES=$(ucode -e "
        import { open } from 'fs';
        let f = open('$STATE_FILE', 'r');
        if (!f) exit(0);
        let content = f.read('all');
        f.close();
        if (!content || substr(trim(content), 0, 1) !== '{') exit(0);
        let state = json(content);
        if (!state || !state.devices) exit(0);
        for (let id in state.devices) {
            let d = state.devices[id];
            let usage = (d.usage != null) ? d.usage : 0;
            let prev = (d.previous_usage != null) ? d.previous_usage : 0;
            let last_run = (d.last_run_time != null) ? d.last_run_time : 0;
            let window = d.active_window ? d.active_window : '';
            let flatrate = (d.flatrate != null) ? d.flatrate : 0;
            let paused = (d.paused != null) ? d.paused : 0;

            let cal = d.calibration || {};
            let cal_status = cal.status || 'idle';
            let cal_start = (cal.start_time != null) ? cal.start_time : 0;
            let cal_idle_dur = (cal.idle_duration != null) ? cal.idle_duration : 0;
            let cal_last_sample = (cal.last_sample_time != null) ? cal.last_sample_time : 0;
            let cal_p2_start = (cal.phase2_start_time != null) ? cal.phase2_start_time : 0;
            let cal_usage_dur = (cal.usage_duration != null) ? cal.usage_duration : 0;

            print(id + '\t' + usage + '\t' + prev + '\t' + last_run + '\t' + window + '\t' + flatrate + '\t' + paused + '\t' +
                  cal_status + '\t' + cal_start + '\t' + cal_idle_dur + '\t' + cal_last_sample + '\t' + cal_p2_start + '\t' + cal_usage_dur + '\n');
        }
    " 2>/dev/null)
}

# Read cached state field for a device
# Args: device_id field_number(2=usage,3=prev,4=last_run) default
get_cached_state() {
    local device_id="$1" field_num="$2" default="${3:-0}"
    if [ -z "$ALL_STATES" ]; then
        echo "$default"
        return
    fi
    local value=$(echo "$ALL_STATES" | awk -F'\t' -v id="$device_id" -v f="$field_num" \
        '$1==id {print $f; found=1; exit} END {if(!found) print "'"$default"'"}')
    if [ -z "$value" ] || ! echo "$value" | grep -qE '^[0-9]+$'; then
        echo "$default"
    else
        echo "$value"
    fi
}

# Read cached active_window for a device (string field)
get_cached_window() {
    local device_id="$1"
    if [ -z "$ALL_STATES" ]; then
        echo ""
        return
    fi
    echo "$ALL_STATES" | awk -F'\t' -v id="$device_id" '$1==id {print $5; exit}'
}

# Read cached flatrate for a device (0 or 1)
get_cached_flatrate() {
    local device_id="$1"
    if [ -z "$ALL_STATES" ]; then
        echo "0"
        return
    fi
    local value=$(echo "$ALL_STATES" | awk -F'\t' -v id="$device_id" '$1==id {print $6; exit}')
    if [ "$value" = "1" ]; then
        echo "1"
    else
        echo "0"
    fi
}

# Read cached paused for a device (0 or 1)
get_cached_paused() {
    local device_id="$1"
    if [ -z "$ALL_STATES" ]; then
        echo "0"
        return
    fi
    local value=$(echo "$ALL_STATES" | awk -F'\t' -v id="$device_id" '$1==id {print $7; exit}')
    if [ "$value" = "1" ]; then
        echo "1"
    else
        echo "0"
    fi
}

# Read cached calibration status for a device
get_cached_calibration_status() {
    local device_id="$1"
    if [ -z "$ALL_STATES" ]; then
        echo "idle"
        return
    fi
    local value=$(echo "$ALL_STATES" | awk -F'\t' -v id="$device_id" '$1==id {print $8; exit}')
    if [ -z "$value" ]; then
        echo "idle"
    else
        echo "$value"
    fi
}

# Read cached calibration data: start_time|idle_duration|last_sample_time|phase2_start_time|usage_duration
get_cached_calibration_data() {
    local device_id="$1"
    if [ -z "$ALL_STATES" ]; then
        echo "0|0|0|0|0"
        return
    fi
    echo "$ALL_STATES" | awk -F'\t' -v id="$device_id" \
        '$1==id {print $9"|"$10"|"$11"|"$12"|"$13; found=1; exit} END {if(!found) print "0|0|0|0|0"}'
}

# Queue state update for batch write (appends to updates file)
queue_state_update() {
    local device_id="$1"
    local usage="$2"
    local prev_usage="$3"
    local last_run="$4"
    local active_window="${5:-}"
    local flatrate="${6:-0}"
    local paused="${7:-0}"
    echo "${device_id}	${usage}	${prev_usage}	${last_run}	${active_window}	${flatrate}	${paused}" >> "${STATE_FILE}.updates"
}

# Queue calibration sample for phase 1 (idle)
queue_calibration_sample_p1() {
    local device_id="$1"
    local sample="$2"
    local timestamp="$3"
    echo "CAL_SAMPLE_P1	${device_id}	${sample}	${timestamp}" >> "${STATE_FILE}.updates"
}

# Queue calibration sample for phase 2 (usage)
queue_calibration_sample_p2() {
    local device_id="$1"
    local sample="$2"
    local timestamp="$3"
    echo "CAL_SAMPLE_P2	${device_id}	${sample}	${timestamp}" >> "${STATE_FILE}.updates"
}

# Queue phase 1 completion
queue_calibration_phase1_done() {
    local device_id="$1"
    echo "CAL_PHASE1_DONE	${device_id}" >> "${STATE_FILE}.updates"
}

# Queue calibration completion with two-phase results
queue_calibration_complete() {
    local device_id="$1"
    local idle_p95="$2"
    local idle_median="$3"
    local stream_p5="$4"
    local stream_median="$5"
    local stream_outliers="$6"
    local recommended="$7"
    local overlap="$8"
    echo "CAL_COMPLETE	${device_id}	${idle_p95}	${idle_median}	${stream_p5}	${stream_median}	${stream_outliers}	${recommended}	${overlap}" >> "${STATE_FILE}.updates"
}

# Mark calibration as failed
fail_calibration() {
    local device_id="$1"
    local error_msg="$2"
    echo "CAL_ERROR	${device_id}	${error_msg}" >> "${STATE_FILE}.updates"
    log "[$device_id] Calibration failed: $error_msg"
}

# Batch write all queued state updates in one ucode call
write_all_states() {
    if [ ! -f "${STATE_FILE}.updates" ]; then
        return
    fi

    ucode -e "
        import { open } from 'fs';
        let state = { version: 2, devices: {} };
        let f = open('$STATE_FILE', 'r');
        if (f) {
            let content = f.read('all');
            f.close();
            if (content && substr(trim(content), 0, 1) === '{') {
                let parsed = json(content);
                if (parsed) state = parsed;
            }
        }
        state.version = 2;
        state.devices = state.devices || {};

        f = open('${STATE_FILE}.updates', 'r');
        if (f) {
            let line;
            while ((line = f.read('line')) !== null) {
                line = trim(line);
                if (!line) continue;
                let parts = split(line, '\t');

                if (parts[0] === 'CAL_SAMPLE_P1' && length(parts) >= 4) {
                    let dev_id = parts[1];
                    let sample = int(parts[2]);
                    let timestamp = int(parts[3]);

                    if (!state.devices[dev_id]) continue;
                    if (!state.devices[dev_id].calibration) {
                        state.devices[dev_id].calibration = { phase1_samples: [] };
                    }
                    if (!state.devices[dev_id].calibration.phase1_samples) {
                        state.devices[dev_id].calibration.phase1_samples = [];
                    }

                    push(state.devices[dev_id].calibration.phase1_samples, sample);
                    state.devices[dev_id].calibration.last_sample_time = timestamp;

                } else if (parts[0] === 'CAL_SAMPLE_P2' && length(parts) >= 4) {
                    let dev_id = parts[1];
                    let sample = int(parts[2]);
                    let timestamp = int(parts[3]);

                    if (!state.devices[dev_id]) continue;
                    if (!state.devices[dev_id].calibration) {
                        state.devices[dev_id].calibration = { phase2_samples: [] };
                    }
                    if (!state.devices[dev_id].calibration.phase2_samples) {
                        state.devices[dev_id].calibration.phase2_samples = [];
                    }

                    push(state.devices[dev_id].calibration.phase2_samples, sample);
                    state.devices[dev_id].calibration.last_sample_time = timestamp;

                } else if (parts[0] === 'CAL_PHASE1_DONE' && length(parts) >= 2) {
                    let dev_id = parts[1];
                    if (!state.devices[dev_id]) continue;
                    if (!state.devices[dev_id].calibration) {
                        state.devices[dev_id].calibration = {};
                    }
                    state.devices[dev_id].calibration.status = 'phase1_done';

                } else if (parts[0] === 'CAL_COMPLETE' && length(parts) >= 9) {
                    let dev_id = parts[1];

                    if (!state.devices[dev_id]) continue;
                    if (!state.devices[dev_id].calibration) {
                        state.devices[dev_id].calibration = {};
                    }

                    state.devices[dev_id].calibration.status = 'completed';
                    state.devices[dev_id].calibration.result_idle_p95 = int(parts[2]);
                    state.devices[dev_id].calibration.result_idle_median = int(parts[3]);
                    state.devices[dev_id].calibration.result_stream_p5 = int(parts[4]);
                    state.devices[dev_id].calibration.result_stream_median = int(parts[5]);
                    state.devices[dev_id].calibration.result_stream_outliers = int(parts[6]);
                    state.devices[dev_id].calibration.result_recommended = int(parts[7]);
                    state.devices[dev_id].calibration.result_overlap = int(parts[8]);

                } else if (parts[0] === 'CAL_ERROR' && length(parts) >= 3) {
                    let dev_id = parts[1];
                    let error_msg = parts[2];

                    if (!state.devices[dev_id]) continue;
                    if (!state.devices[dev_id].calibration) {
                        state.devices[dev_id].calibration = {};
                    }

                    state.devices[dev_id].calibration.status = 'error';
                    state.devices[dev_id].calibration.error_message = error_msg;

                } else if (length(parts) >= 4) {
                    let dev_id = parts[0];
                    let existing = state.devices[dev_id] || {};
                    let existing_cal = existing.calibration || {};

                    state.devices[dev_id] = {
                        usage: int(parts[1]),
                        previous_usage: int(parts[2]),
                        last_run_time: int(parts[3]),
                        active_window: (length(parts) >= 5) ? parts[4] : '',
                        flatrate: (length(parts) >= 6) ? int(parts[5]) : 0,
                        paused: (length(parts) >= 7) ? int(parts[6]) : 0,
                        calibration: existing_cal
                    };
                }
            }
            f.close();
        }

        f = open('${STATE_FILE}.daemon.tmp', 'w');
        if (f) {
            let content = sprintf('%J', state);
            let written = f.write(content);
            f.close();
            if (written !== length(content)) {
                print('ERROR: Partial write detected\n');
                exit(1);
            }
        }
    " 2>/dev/null

    # Check if ucode failed
    if [ $? -ne 0 ]; then
        rm -f "${STATE_FILE}.daemon.tmp"
        return 1
    fi

    # Atomic write with flock
    if ! flock "$TEMP_DIR/state.lock" -c "mv '${STATE_FILE}.daemon.tmp' '$STATE_FILE'" 2>/dev/null; then
        log "Error: Failed to write state file"
        rm -f "${STATE_FILE}.daemon.tmp"
        return 1
    fi
    rm -f "${STATE_FILE}.updates"
}

# Process RPC updates queued by rpcd (single-writer pattern)
# rpcd writes commands to state.json.rpc, daemon processes them here
process_rpc_updates() {
    local rpc_file="${STATE_FILE}.rpc"
    local processing_file="${rpc_file}.processing"
    [ -f "$rpc_file" ] || return 0

    # Atomically rename to prevent TOCTOU race with rpcd appending new commands
    # Uses same lock as rpcd's queueRpcUpdate to serialize access
    if ! flock "$TEMP_DIR/state.lock" -c "mv '$rpc_file' '$processing_file'" 2>/dev/null; then
        return 0
    fi

    local result
    result=$(ucode -e "
        import { open } from 'fs';

        let state = { version: 2, devices: {} };
        let f = open('$STATE_FILE', 'r');
        if (f) {
            let content = f.read('all');
            f.close();
            if (content && substr(trim(content), 0, 1) === '{') {
                let parsed = json(content);
                if (parsed) state = parsed;
            }
        }
        state.version = 2;
        state.devices = state.devices || {};

        let rpc = open('${processing_file}', 'r');
        if (!rpc) {
            print('ERROR: Cannot open rpc file');
            exit(1);
        }

        let count = 0;
        let line;
        while ((line = rpc.read('line')) !== null) {
            line = trim(line);
            if (!line) continue;

            let parts = split(line, '\t');
            let cmd = parts[0];

            if (cmd === 'RPC_RESET' && length(parts) >= 2) {
                let id = parts[1];
                let existing = state.devices[id] || {};
                state.devices[id] = {
                    usage: 0,
                    previous_usage: 0,
                    last_run_time: time(),
                    active_window: existing.active_window || '',
                    flatrate: (existing.flatrate != null) ? existing.flatrate : 0,
                    paused: (existing.paused != null) ? existing.paused : 0,
                    calibration: existing.calibration || null
                };
                count++;

            } else if (cmd === 'RPC_FLATRATE' && length(parts) >= 3) {
                let id = parts[1];
                let val = int(parts[2]);
                let existing = state.devices[id] || {};
                state.devices[id] = {
                    usage: (existing.usage != null) ? existing.usage : 0,
                    previous_usage: (existing.previous_usage != null) ? existing.previous_usage : 0,
                    last_run_time: (existing.last_run_time != null) ? existing.last_run_time : time(),
                    active_window: existing.active_window || '',
                    flatrate: val,
                    paused: (existing.paused != null) ? existing.paused : 0,
                    calibration: existing.calibration || null
                };
                count++;

            } else if (cmd === 'RPC_PAUSE' && length(parts) >= 3) {
                let id = parts[1];
                let val = int(parts[2]);
                let existing = state.devices[id] || {};
                state.devices[id] = {
                    usage: (existing.usage != null) ? existing.usage : 0,
                    previous_usage: (existing.previous_usage != null) ? existing.previous_usage : 0,
                    last_run_time: (existing.last_run_time != null) ? existing.last_run_time : time(),
                    active_window: existing.active_window || '',
                    flatrate: (existing.flatrate != null) ? existing.flatrate : 0,
                    paused: val,
                    calibration: existing.calibration || null
                };
                count++;

            } else if (cmd === 'RPC_CAL_START' && length(parts) >= 3) {
                let id = parts[1];
                let dur = int(parts[2]);
                let idle_dur = int(dur / 2);
                let usage_dur = dur - idle_dur;
                let existing = state.devices[id] || {};
                state.devices[id] = {
                    usage: (existing.usage != null) ? existing.usage : 0,
                    previous_usage: (existing.previous_usage != null) ? existing.previous_usage : 0,
                    last_run_time: (existing.last_run_time != null) ? existing.last_run_time : time(),
                    active_window: existing.active_window || '',
                    flatrate: (existing.flatrate != null) ? existing.flatrate : 0,
                    paused: (existing.paused != null) ? existing.paused : 0,
                    calibration: {
                        status: 'phase1_running',
                        total_duration: dur,
                        idle_duration: idle_dur,
                        usage_duration: usage_dur,
                        start_time: time(),
                        phase2_start_time: 0,
                        phase1_samples: [],
                        phase2_samples: [],
                        last_sample_time: 0,
                        result_idle_p95: 0,
                        result_idle_median: 0,
                        result_stream_p5: 0,
                        result_stream_median: 0,
                        result_stream_outliers: 0,
                        result_recommended: 0,
                        result_overlap: 0,
                        error_message: ''
                    }
                };
                count++;

            } else if (cmd === 'RPC_CAL_START_P2' && length(parts) >= 2) {
                let id = parts[1];
                let existing = state.devices[id] || {};
                let cal = existing.calibration || {};

                if (cal.status === 'phase1_done') {
                    cal.status = 'phase2_running';
                    cal.phase2_start_time = time();
                    cal.last_sample_time = 0;

                    state.devices[id] = {
                        usage: (existing.usage != null) ? existing.usage : 0,
                        previous_usage: (existing.previous_usage != null) ? existing.previous_usage : 0,
                        last_run_time: (existing.last_run_time != null) ? existing.last_run_time : time(),
                        active_window: existing.active_window || '',
                        flatrate: (existing.flatrate != null) ? existing.flatrate : 0,
                        paused: (existing.paused != null) ? existing.paused : 0,
                        calibration: cal
                    };
                    count++;
                }

            } else if (cmd === 'RPC_CAL_CLEAR' && length(parts) >= 2) {
                let id = parts[1];
                let existing = state.devices[id] || {};
                state.devices[id] = {
                    usage: (existing.usage != null) ? existing.usage : 0,
                    previous_usage: (existing.previous_usage != null) ? existing.previous_usage : 0,
                    last_run_time: (existing.last_run_time != null) ? existing.last_run_time : time(),
                    active_window: existing.active_window || '',
                    flatrate: (existing.flatrate != null) ? existing.flatrate : 0,
                    paused: (existing.paused != null) ? existing.paused : 0,
                    calibration: {
                        status: 'idle',
                        total_duration: 0,
                        idle_duration: 0,
                        usage_duration: 0,
                        start_time: 0,
                        phase2_start_time: 0,
                        phase1_samples: [],
                        phase2_samples: [],
                        last_sample_time: 0,
                        result_idle_p95: 0,
                        result_idle_median: 0,
                        result_stream_p5: 0,
                        result_stream_median: 0,
                        result_stream_outliers: 0,
                        result_recommended: 0,
                        result_overlap: 0,
                        error_message: ''
                    }
                };
                count++;
            }
        }
        rpc.close();

        if (count > 0) {
            f = open('${STATE_FILE}.rpc.tmp', 'w');
            if (f) {
                let content = sprintf('%J', state);
                let written = f.write(content);
                f.close();
                if (written !== length(content)) {
                    print('ERROR: Partial write');
                    exit(1);
                }
            } else {
                print('ERROR: Cannot write tmp file');
                exit(1);
            }
        }

        print('OK:' + count);
    " 2>/dev/null)

    case "$result" in
        ERROR:*)
            log "RPC update error: $result"
            rm -f "$processing_file"
            return 1
            ;;
        OK:0)
            rm -f "$processing_file"
            ;;
        OK:*)
            local count="${result#OK:}"
            if flock "$TEMP_DIR/state.lock" -c "mv '${STATE_FILE}.rpc.tmp' '$STATE_FILE'" 2>/dev/null; then
                rm -f "$processing_file"
                log "Processed $count RPC updates"
            else
                log "RPC update error: failed to write state file"
                rm -f "${STATE_FILE}.rpc.tmp"
                rm -f "$processing_file"
            fi
            ;;
        *)
            log "RPC update error: unexpected output: $result"
            rm -f "$processing_file"
            ;;
    esac
}

# Read flatrate directly from state file (bypasses cache)
# Used during midnight reset when cache may be stale
read_flatrate_from_file() {
    local device_id="$1"
    if [ ! -f "$STATE_FILE" ]; then
        echo "0"
        return
    fi

    local flatrate=$(ucode -e "
        import { open } from 'fs';
        let f = open('$STATE_FILE', 'r');
        if (!f) exit(0);
        let content = f.read('all');
        f.close();
        if (!content || substr(trim(content), 0, 1) !== '{') { print('0'); exit(0); }
        let state = json(content);
        if (!state || !state.devices || !state.devices['$device_id']) {
            print('0');
            exit(0);
        }
        print(state.devices['$device_id'].flatrate || 0);
    " 2>/dev/null)

    echo "${flatrate:-0}"
}

# Read paused directly from state file (bypasses cache)
# Used during midnight reset when cache may be stale
read_paused_from_file() {
    local device_id="$1"
    if [ ! -f "$STATE_FILE" ]; then
        echo "0"
        return
    fi

    local paused=$(ucode -e "
        import { open } from 'fs';
        let f = open('$STATE_FILE', 'r');
        if (!f) exit(0);
        let content = f.read('all');
        f.close();
        if (!content || substr(trim(content), 0, 1) !== '{') { print('0'); exit(0); }
        let state = json(content);
        if (!state || !state.devices || !state.devices['$device_id']) {
            print('0');
            exit(0);
        }
        print(state.devices['$device_id'].paused || 0);
    " 2>/dev/null)

    echo "${paused:-0}"
}

# Reset device state (used during midnight reset)
reset_device_state() {
    local device_id="$1"
    # Read flatrate and paused directly from file (cache is stale during midnight reset)
    # The cache (ALL_STATES) is from previous poll cycle and doesn't reflect
    # RPC updates processed earlier in this cycle
    local cached_flatrate=$(read_flatrate_from_file "$device_id")
    local cached_paused=$(read_paused_from_file "$device_id")
    queue_state_update "$device_id" 0 0 "$(date +%s)" "" "$cached_flatrate" "$cached_paused"
}
