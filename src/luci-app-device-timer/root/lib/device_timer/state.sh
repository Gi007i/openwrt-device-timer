#!/bin/sh
# state.sh - State management for device_timer daemon
# Requires globals: STATE_FILE, TEMP_DIR, log()

# Batch state I/O: read all device states in one ucode call
# Output format: device_id\tusage\tprevious_usage\tlast_run_time\tactive_window\tflatrate\tcal_status\tcal_start\tcal_duration\tcal_last_sample\tcal_last_counter
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
        let state = json(f.read('all'));
        f.close();
        if (!state || !state.devices) exit(0);
        for (let id in state.devices) {
            let d = state.devices[id];
            let usage = (d.usage != null) ? d.usage : 0;
            let prev = (d.previous_usage != null) ? d.previous_usage : 0;
            let last_run = (d.last_run_time != null) ? d.last_run_time : 0;
            let window = d.active_window ? d.active_window : '';
            let flatrate = (d.flatrate != null) ? d.flatrate : 0;

            let cal = d.calibration || {};
            let cal_status = cal.status || 'idle';
            let cal_start = (cal.start_time != null) ? cal.start_time : 0;
            let cal_duration = (cal.duration != null) ? cal.duration : 1800;
            let cal_last_sample = (cal.last_sample_time != null) ? cal.last_sample_time : 0;
            let cal_last_counter = (cal.last_counter != null) ? cal.last_counter : 0;

            print(id + '\t' + usage + '\t' + prev + '\t' + last_run + '\t' + window + '\t' + flatrate + '\t' +
                  cal_status + '\t' + cal_start + '\t' + cal_duration + '\t' + cal_last_sample + '\t' + cal_last_counter + '\n');
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

# Read cached calibration status for a device (string: idle/running/completed/error)
get_cached_calibration_status() {
    local device_id="$1"
    if [ -z "$ALL_STATES" ]; then
        echo "idle"
        return
    fi
    local value=$(echo "$ALL_STATES" | awk -F'\t' -v id="$device_id" '$1==id {print $7; exit}')
    if [ -z "$value" ]; then
        echo "idle"
    else
        echo "$value"
    fi
}

# Read cached calibration data: start_time|duration|sample_interval|last_sample_time|last_counter
get_cached_calibration_data() {
    local device_id="$1"
    if [ -z "$ALL_STATES" ]; then
        echo "0|1800|10|0|0"
        return
    fi
    echo "$ALL_STATES" | awk -F'\t' -v id="$device_id" \
        '$1==id {print $8"|"$9"|10|"$10"|"$11; exit}'
}

# Queue state update for batch write (appends to updates file)
queue_state_update() {
    local device_id="$1"
    local usage="$2"
    local prev_usage="$3"
    local last_run="$4"
    local active_window="${5:-}"
    local flatrate="${6:-0}"
    echo "${device_id}	${usage}	${prev_usage}	${last_run}	${active_window}	${flatrate}" >> "${STATE_FILE}.updates"
}

# Queue calibration sample for batch write
queue_calibration_sample() {
    local device_id="$1"
    local sample="$2"
    local new_counter="$3"
    local timestamp="$4"
    echo "CAL_SAMPLE	${device_id}	${sample}	${new_counter}	${timestamp}" >> "${STATE_FILE}.updates"
}

# Queue calibration completion
queue_calibration_complete() {
    local device_id="$1"
    local p90="$2"
    local recommended="$3"
    echo "CAL_COMPLETE	${device_id}	${p90}	${recommended}" >> "${STATE_FILE}.updates"
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
            if (content) {
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

                if (parts[0] === 'CAL_SAMPLE' && length(parts) >= 5) {
                    let dev_id = parts[1];
                    let sample = int(parts[2]);
                    let counter = int(parts[3]);
                    let timestamp = int(parts[4]);

                    if (!state.devices[dev_id]) continue;
                    if (!state.devices[dev_id].calibration) {
                        state.devices[dev_id].calibration = { samples: [] };
                    }
                    if (!state.devices[dev_id].calibration.samples) {
                        state.devices[dev_id].calibration.samples = [];
                    }

                    push(state.devices[dev_id].calibration.samples, sample);
                    state.devices[dev_id].calibration.last_counter = counter;
                    state.devices[dev_id].calibration.last_sample_time = timestamp;

                } else if (parts[0] === 'CAL_COMPLETE' && length(parts) >= 4) {
                    let dev_id = parts[1];
                    let p90 = int(parts[2]);
                    let recommended = int(parts[3]);

                    if (!state.devices[dev_id]) continue;
                    if (!state.devices[dev_id].calibration) {
                        state.devices[dev_id].calibration = {};
                    }

                    state.devices[dev_id].calibration.status = 'completed';
                    state.devices[dev_id].calibration.result_p90 = p90;
                    state.devices[dev_id].calibration.result_recommended = recommended;

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
    [ -f "$rpc_file" ] || return 0

    local result
    result=$(ucode -e "
        import { open } from 'fs';

        let state = { version: 2, devices: {} };
        let f = open('$STATE_FILE', 'r');
        if (f) {
            let content = f.read('all');
            f.close();
            if (content) {
                let parsed = json(content);
                if (parsed) state = parsed;
            }
        }
        state.version = 2;
        state.devices = state.devices || {};

        let rpc = open('${rpc_file}', 'r');
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
                    calibration: existing.calibration || null
                };
                count++;

            } else if (cmd === 'RPC_CAL_START' && length(parts) >= 4) {
                let id = parts[1];
                let dur = int(parts[2]);
                let interval = int(parts[3]);
                let existing = state.devices[id] || {};
                state.devices[id] = {
                    usage: (existing.usage != null) ? existing.usage : 0,
                    previous_usage: (existing.previous_usage != null) ? existing.previous_usage : 0,
                    last_run_time: (existing.last_run_time != null) ? existing.last_run_time : time(),
                    active_window: existing.active_window || '',
                    flatrate: (existing.flatrate != null) ? existing.flatrate : 0,
                    calibration: {
                        status: 'running',
                        start_time: time(),
                        duration: dur,
                        sample_interval: interval,
                        samples: [],
                        last_sample_time: 0,
                        last_counter: 0,
                        result_p90: 0,
                        result_recommended: 0,
                        error_message: ''
                    }
                };
                count++;

            } else if (cmd === 'RPC_CAL_CLEAR' && length(parts) >= 2) {
                let id = parts[1];
                let existing = state.devices[id] || {};
                state.devices[id] = {
                    usage: (existing.usage != null) ? existing.usage : 0,
                    previous_usage: (existing.previous_usage != null) ? existing.previous_usage : 0,
                    last_run_time: (existing.last_run_time != null) ? existing.last_run_time : time(),
                    active_window: existing.active_window || '',
                    flatrate: (existing.flatrate != null) ? existing.flatrate : 0,
                    calibration: {
                        status: 'idle',
                        start_time: 0,
                        duration: 0,
                        sample_interval: 10,
                        samples: [],
                        last_sample_time: 0,
                        last_counter: 0,
                        result_p90: 0,
                        result_recommended: 0,
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
            return 1
            ;;
        OK:0)
            rm -f "$rpc_file"
            ;;
        OK:*)
            local count="${result#OK:}"
            if flock "$TEMP_DIR/state.lock" -c "mv '${STATE_FILE}.rpc.tmp' '$STATE_FILE'" 2>/dev/null; then
                rm -f "$rpc_file"
                log "Processed $count RPC updates"
            else
                log "RPC update error: failed to write state file"
                rm -f "${STATE_FILE}.rpc.tmp"
            fi
            ;;
        *)
            log "RPC update error: unexpected output: $result"
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
        let state = json(f.read('all'));
        f.close();
        if (!state || !state.devices || !state.devices['$device_id']) {
            print('0');
            exit(0);
        }
        print(state.devices['$device_id'].flatrate || 0);
    " 2>/dev/null)

    echo "${flatrate:-0}"
}

# Reset device state (used during midnight reset)
reset_device_state() {
    local device_id="$1"
    # Read flatrate directly from file (cache is stale during midnight reset)
    # The cache (ALL_STATES) is from previous poll cycle and doesn't reflect
    # RPC updates processed earlier in this cycle
    local cached_flatrate=$(read_flatrate_from_file "$device_id")
    queue_state_update "$device_id" 0 0 "$(date +%s)" "" "$cached_flatrate"
}
