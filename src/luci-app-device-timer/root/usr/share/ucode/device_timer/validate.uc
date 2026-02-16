// Shared schedule validation module for device_timer
// Load via: const v = call(loadfile('/usr/share/ucode/device_timer/validate.uc'));
// Use via:  v.validateScheduleList(schedules)

'use strict';

// Parse time string "HH:MM" to minutes since midnight
function parseTimeToMinutes(timeStr) {
    if (!timeStr) return null;
    const parts = split(timeStr, ':');
    if (length(parts) !== 2) return null;
    const hours = int(parts[0]);
    const mins = int(parts[1]);
    if (hours < 0 || hours > 23 || mins < 0 || mins > 59) return null;
    return hours * 60 + mins;
}

// Check if two time ranges overlap (handles overnight windows)
function timeRangesOverlap(start1, end1, start2, end2) {
    let ranges1 = [];
    let ranges2 = [];

    if (start1 <= end1) {
        push(ranges1, [start1, end1]);
    } else {
        push(ranges1, [start1, 1440]);
        push(ranges1, [0, end1]);
    }

    if (start2 <= end2) {
        push(ranges2, [start2, end2]);
    } else {
        push(ranges2, [start2, 1440]);
        push(ranges2, [0, end2]);
    }

    for (let i = 0; i < length(ranges1); i++) {
        for (let j = 0; j < length(ranges2); j++) {
            let r1 = ranges1[i];
            let r2 = ranges2[j];
            if (r1[0] < r2[1] && r2[0] < r1[1]) {
                return true;
            }
        }
    }
    return false;
}

// Validate schedule list for overlaps and format errors
// Returns: { valid: true } or { valid: false, error: string }
function validateScheduleList(schedules) {
    if (!schedules || !length(schedules)) {
        return { valid: true };
    }

    // Group schedules by day
    let byDay = {};
    const validDays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    for (let i = 0; i < length(schedules); i++) {
        let entry = schedules[i];
        let parts = split(entry, ',');
        if (length(parts) !== 3) {
            return { valid: false, error: 'Invalid format: ' + entry };
        }

        let day = parts[0];
        let timerange = parts[1];
        let limit = parts[2];

        // Validate day
        let dayValid = false;
        for (let d = 0; d < length(validDays); d++) {
            if (validDays[d] === day) {
                dayValid = true;
                break;
            }
        }
        if (!dayValid) {
            return { valid: false, error: 'Invalid day: ' + day };
        }

        // Parse time range
        let timeParts = split(timerange, '-');
        if (length(timeParts) !== 2) {
            return { valid: false, error: 'Invalid time range: ' + timerange };
        }

        let startMin = parseTimeToMinutes(timeParts[0]);
        let endMin = parseTimeToMinutes(timeParts[1]);
        if (startMin === null || endMin === null) {
            return { valid: false, error: 'Invalid time format: ' + timerange };
        }

        // Reject zero-duration windows (start == end)
        if (startMin === endMin) {
            return { valid: false, error: 'Zero-duration window not allowed: ' + timerange };
        }

        // Validate limit (0 = unlimited, 1+ = limit in minutes)
        if (!match(limit, /^(0|[1-9][0-9]*)$/)) {
            return { valid: false, error: 'Invalid limit: ' + limit };
        }

        // Add to day group
        if (!byDay[day]) {
            byDay[day] = [];
        }
        push(byDay[day], { start: startMin, end: endMin, entry: entry });
    }

    // Check for overlaps within each day
    let days = keys(byDay);
    for (let d = 0; d < length(days); d++) {
        let day = days[d];
        let slots = byDay[day];
        for (let i = 0; i < length(slots); i++) {
            for (let j = i + 1; j < length(slots); j++) {
                if (timeRangesOverlap(slots[i].start, slots[i].end, slots[j].start, slots[j].end)) {
                    return {
                        valid: false,
                        error: 'Overlapping schedules on ' + day + ': ' + slots[i].entry + ' and ' + slots[j].entry
                    };
                }
            }
        }
    }

    return { valid: true };
}

return {
    parseTimeToMinutes: parseTimeToMinutes,
    timeRangesOverlap: timeRangesOverlap,
    validateScheduleList: validateScheduleList
};
