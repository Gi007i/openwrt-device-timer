#!/bin/sh
# firewall.sh - Firewall rules, cleanup, and conntrack flush for device_timer daemon
# Requires globals: FIREWALL_NEEDS_RELOAD, CONNTRACK_FLUSH_IPS, TEMP_DIR, STATE_FILE, log()

# Conntrack flush queue (space-separated IPs)
CONNTRACK_FLUSH_IPS=""

# Flush conntrack entries for blocked devices to kill established connections
# Must be called AFTER firewall reload (new connections blocked first, then existing killed)
flush_conntrack_ips() {
    local ip
    for ip in $CONNTRACK_FLUSH_IPS; do
        echo "$ip" > /proc/net/nf_conntrack 2>/dev/null
        log "Flushed conntrack entries for $ip"
    done
    CONNTRACK_FLUSH_IPS=""
}

find_firewall_rule_section() {
    local rule_name="$1"
    local section name
    # Use uci show directly (returns real cfg IDs, not @rule[index])
    for section in $(uci -X -q show firewall | grep '=rule$' | cut -d. -f2 | cut -d= -f1); do
        name=$(uci -q get "firewall.$section.name")
        if [ "$name" = "$rule_name" ]; then
            echo "$section"
            return 0
        fi
    done
    return 1
}

manage_firewall_rule() {
    local device_id="$1"
    local device_mac="$2"
    local rule_name="$3"
    local action="$4"

    # MAC is required for reliable blocking
    if [ -z "$device_mac" ]; then
        log "[$device_id] Cannot manage firewall rule: MAC address not available"
        return
    fi

    # Firewall requires uppercase MAC
    local firewall_mac=$(echo "$device_mac" | tr 'a-f' 'A-F')

    local rule_section=$(find_firewall_rule_section "$rule_name")

    # Always ensure rule exists (created disabled)
    if [ -z "$rule_section" ]; then
        log "[$device_id] Creating firewall rule (disabled)"
        local section_id=$(uci add firewall rule)
        if [ -z "$section_id" ]; then
            log "[$device_id] Error: Failed to create firewall rule"
            return
        fi

        uci set firewall.$section_id.name="$rule_name"
        uci set firewall.$section_id.src='*'
        uci set firewall.$section_id.dest='*'
        uci set firewall.$section_id.src_mac="$firewall_mac"
        uci set firewall.$section_id.target='REJECT'
        uci set firewall.$section_id.enabled='0'

        if ! uci commit firewall; then
            log "[$device_id] Error: Failed to commit firewall changes"
            return
        fi

        FIREWALL_NEEDS_RELOAD=1
        rule_section="$section_id"
    else
        # Verify MAC is still correct (may change if device re-configured)
        local current_mac=$(uci -q get "firewall.$rule_section.src_mac")
        if [ "$current_mac" != "$firewall_mac" ]; then
            log "[$device_id] Updating firewall rule MAC: $current_mac -> $firewall_mac"
            uci set "firewall.$rule_section.src_mac=$firewall_mac"
            if ! uci commit firewall; then
                log "[$device_id] Error: Failed to commit firewall MAC update"
            else
                FIREWALL_NEEDS_RELOAD=1
            fi
        fi
    fi

    # Now enable or disable based on action
    if [ "$action" = "block" ]; then
        local current_enabled=$(uci -q get firewall.$rule_section.enabled)
        if [ "$current_enabled" = "0" ]; then
            log "[$device_id] Activating firewall rule"
            uci delete firewall.$rule_section.enabled
            if ! uci commit firewall; then
                log "[$device_id] Error: Failed to commit firewall changes"
                return
            fi
            FIREWALL_NEEDS_RELOAD=1
            # Queue conntrack flush for this device
            local stored_ip=""
            [ -f "$TEMP_DIR/${device_id}_nft_ip" ] && stored_ip=$(cat "$TEMP_DIR/${device_id}_nft_ip")
            if [ -n "$stored_ip" ]; then
                CONNTRACK_FLUSH_IPS="$CONNTRACK_FLUSH_IPS $stored_ip"
            fi
        fi
    else
        local current_enabled=$(uci -q get firewall.$rule_section.enabled)
        if [ "$current_enabled" != "0" ]; then
            log "[$device_id] Deactivating firewall rule"
            uci set firewall.$rule_section.enabled='0'
            if ! uci commit firewall; then
                log "[$device_id] Error: Failed to commit firewall changes"
                return
            fi
            FIREWALL_NEEDS_RELOAD=1
        fi
    fi
}

cleanup_device_table() {
    local cfg="$1"
    nft delete table inet device_timer_$cfg 2>/dev/null || true
    rm -f "$TEMP_DIR/${cfg}_nft_ip"
}

unblock_device_cb() {
    local cfg="$1"
    local mac=$(uci get device_timer.$cfg.mac 2>/dev/null | tr 'A-F' 'a-f')
    [ -z "$mac" ] && return
    manage_firewall_rule "$cfg" "$mac" "Block_Device_$cfg" "unblock"
}

disable_all_monitoring() {
    log "Global monitoring disabled, releasing all devices"
    config_load device_timer
    config_foreach unblock_device_cb device
    if [ "$FIREWALL_NEEDS_RELOAD" -eq 1 ]; then
        if ! /etc/init.d/firewall reload; then
            log "Error: Firewall reload failed during disable, skipping nft cleanup"
            return 1
        fi
        FIREWALL_NEEDS_RELOAD=0
    fi
    config_foreach cleanup_device_table device
}

cleanup() {
    log "Shutting down daemon"

    config_load device_timer
    config_foreach cleanup_device_table device

    rm -f "${STATE_FILE}.rpc.tmp"
    # PID file managed by procd, don't remove it here
    exit 0
}

# Cleanup orphaned firewall rules and nftables tables
# Called periodically to remove resources for deleted devices
cleanup_orphaned_resources() {
    local section name device_id needs_reload=0

    # Cleanup orphaned firewall rules (Block_Device_*)
    for section in $(uci -X -q show firewall | grep '=rule$' | cut -d. -f2 | cut -d= -f1); do
        name=$(uci -q get "firewall.$section.name")
        case "$name" in
            Block_Device_*)
                device_id="${name#Block_Device_}"
                # Check if device still exists in config
                if ! uci -q get "device_timer.$device_id" >/dev/null 2>&1; then
                    log "Removing orphaned firewall rule: $name"
                    uci delete "firewall.$section"
                    needs_reload=1
                fi
                ;;
        esac
    done

    if [ "$needs_reload" -eq 1 ]; then
        if ! uci commit firewall; then
            log "Warning: Failed to commit firewall cleanup changes"
        else
            FIREWALL_NEEDS_RELOAD=1
        fi
    fi

    # Cleanup orphaned nftables tables (device_timer_*)
    for table in $(nft list tables 2>/dev/null | grep 'inet device_timer_' | awk '{print $3}'); do
        device_id="${table#device_timer_}"
        # Check if device still exists in config
        if ! uci -q get "device_timer.$device_id" >/dev/null 2>&1; then
            log "Removing orphaned nftables table: $table"
            nft delete table inet "$table" 2>/dev/null || true
            rm -f "$TEMP_DIR/${device_id}_nft_ip"
        fi
    done

    # Cleanup orphaned state.json entries
    if [ -f "$STATE_FILE" ]; then
        # Get list of valid device IDs (use -X to get real section names, not @device[0])
        local valid_ids=$(uci -X show device_timer | grep '=device$' | cut -d. -f2 | cut -d= -f1 | tr '\n' ' ')

        ucode -e "
            import { open } from 'fs';
            let f = open('$STATE_FILE', 'r');
            if (!f) exit(0);
            let state = json(f.read('all'));
            f.close();
            if (!state || !state.devices) exit(0);

            let validIds = split(trim('$valid_ids'), ' ');
            let validSet = {};
            for (let i = 0; i < length(validIds); i++) {
                if (validIds[i]) validSet[validIds[i]] = true;
            }

            let changed = false;
            let toDelete = [];

            for (let id in state.devices) {
                if (!validSet[id]) {
                    push(toDelete, id);
                }
            }

            for (let i = 0; i < length(toDelete); i++) {
                print('Removing orphaned state entry: ' + toDelete[i] + '\n');
                delete state.devices[toDelete[i]];
                changed = true;
            }

            if (changed) {
                f = open('${STATE_FILE}.cleanup.tmp', 'w');
                if (f) {
                    let content = sprintf('%J', state);
                    let written = f.write(content);
                    f.close();
                    if (written !== length(content)) {
                        print('ERROR: Partial write in cleanup\n');
                        exit(1);
                    }
                }
            }
        " 2>/dev/null

        # Check if ucode failed
        if [ $? -ne 0 ]; then
            rm -f "${STATE_FILE}.cleanup.tmp"
            return
        fi

        # Atomic write with flock
        [ -f "${STATE_FILE}.cleanup.tmp" ] && flock "$TEMP_DIR/state.lock" -c "mv '${STATE_FILE}.cleanup.tmp' '$STATE_FILE'"
    fi
}
