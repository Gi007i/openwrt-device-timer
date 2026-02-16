'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require poll';
'require dom';
'require ui';
'require network';

var callDeviceTimerDevices = rpc.declare({
	object: 'luci.device-timer',
	method: 'devices'
});

var callDeviceTimerStatus = rpc.declare({
	object: 'luci.device-timer',
	method: 'status'
});

var callStartCalibration = rpc.declare({
	object: 'luci.device-timer',
	method: 'startcalibration',
	params: ['id', 'duration', 'sample_interval']
});

var callGetCalibration = rpc.declare({
	object: 'luci.device-timer',
	method: 'getcalibration',
	params: ['id']
});

var callApplyCalibration = rpc.declare({
	object: 'luci.device-timer',
	method: 'applycalibration',
	params: ['id']
});

var callCancelCalibration = rpc.declare({
	object: 'luci.device-timer',
	method: 'cancelcalibration',
	params: ['id']
});

// Module-level store for device data (accessible from option methods)
var deviceDataStore = {};

// Format bytes to human-readable string
function formatBytes(bytes) {
	if (bytes < 1024 * 1024) {
		// Minimum 1K, round up
		var kb = Math.ceil(bytes / 1024);
		if (kb < 1) kb = 1;
		return kb + ' K';
	} else {
		return Math.round(bytes / (1024 * 1024)) + ' M';
	}
}

// Parse time string "HH:MM" to minutes since midnight
function parseTimeToMinutes(timeStr) {
	if (!timeStr) return null;
	var parts = timeStr.split(':');
	if (parts.length !== 2) return null;
	var hours = parseInt(parts[0], 10);
	var mins = parseInt(parts[1], 10);
	if (isNaN(hours) || isNaN(mins)) return null;
	if (hours < 0 || hours > 23 || mins < 0 || mins > 59) return null;
	return hours * 60 + mins;
}

// Check if two time ranges overlap (handles overnight windows)
function timeRangesOverlap(start1, end1, start2, end2) {
	var ranges1 = [];
	var ranges2 = [];

	if (start1 <= end1) {
		ranges1.push([start1, end1]);
	} else {
		ranges1.push([start1, 1440]);
		ranges1.push([0, end1]);
	}

	if (start2 <= end2) {
		ranges2.push([start2, end2]);
	} else {
		ranges2.push([start2, 1440]);
		ranges2.push([0, end2]);
	}

	for (var i = 0; i < ranges1.length; i++) {
		for (var j = 0; j < ranges2.length; j++) {
			var r1 = ranges1[i];
			var r2 = ranges2[j];
			if (r1[0] < r2[1] && r2[0] < r1[1]) {
				return true;
			}
		}
	}
	return false;
}

// Validate schedule list for overlaps (exported for testing)
function validateScheduleOverlaps(schedules) {
	if (!schedules || !schedules.length) {
		return { valid: true };
	}

	var byDay = {};
	var formatPattern = /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun),([01]?[0-9]|2[0-3]):[0-5][0-9]-([01]?[0-9]|2[0-3]):[0-5][0-9],(0|[1-9]\d*)$/;

	for (var idx = 0; idx < schedules.length; idx++) {
		var entry = schedules[idx];
		if (!entry) continue;

		if (!formatPattern.test(entry)) {
			return { valid: false, error: _('Invalid format: %s').format(entry) };
		}

		var parts = entry.split(',');
		var day = parts[0];
		var timerange = parts[1];
		var timeParts = timerange.split('-');
		var startMin = parseTimeToMinutes(timeParts[0]);
		var endMin = parseTimeToMinutes(timeParts[1]);

		if (!byDay[day]) {
			byDay[day] = [];
		}
		byDay[day].push({ start: startMin, end: endMin, entry: entry });
	}

	var days = Object.keys(byDay);
	for (var d = 0; d < days.length; d++) {
		var day = days[d];
		var slots = byDay[day];
		for (var i = 0; i < slots.length; i++) {
			for (var j = i + 1; j < slots.length; j++) {
				if (timeRangesOverlap(slots[i].start, slots[i].end, slots[j].start, slots[j].end)) {
					return {
						valid: false,
						error: _('Overlapping schedules on %s: %s and %s').format(day, slots[i].entry, slots[j].entry)
					};
				}
			}
		}
	}

	return { valid: true };
}

// Export for testing (accessible via browser console)
window.deviceTimerValidation = {
	parseTimeToMinutes: parseTimeToMinutes,
	timeRangesOverlap: timeRangesOverlap,
	validateScheduleOverlaps: validateScheduleOverlaps
};

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('device_timer'),
			callDeviceTimerDevices(),
			callDeviceTimerStatus(),
			network.getHostHints()
		]).then(function(data) {
			var devices = data[1] && data[1].devices ? data[1].devices : [];
			var calPromises = devices.map(function(d) {
				return callGetCalibration(d.id).then(function(cal) {
					return { id: d.id, cal: cal };
				}).catch(function() {
					return { id: d.id, cal: null };
				});
			});
			return Promise.all(calPromises).then(function(calibrations) {
				data.push(calibrations);
				return data;
			});
		});
	},

	renderStatusHeader: function(daemonStatus) {
		var running = daemonStatus && daemonStatus.running;
		var statusBadge = running
			? E('span', { 'class': 'label success' }, _('Running'))
			: E('span', { 'class': 'label danger' }, _('Stopped'));

		var enabled = uci.get('device_timer', 'settings', 'enabled');
		var monitoringBadge = (enabled === '1')
			? E('span', { 'class': 'label success' }, _('Enabled'))
			: E('span', { 'class': 'label danger' }, _('Disabled'));

		var rows = [
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, _('Daemon Status')),
				E('td', { 'class': 'td left', 'id': 'daemon_status' }, statusBadge)
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, _('Monitoring')),
				E('td', { 'class': 'td left' }, monitoringBadge)
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, _('Poll Interval')),
				E('td', { 'class': 'td left', 'id': 'poll_interval' },
					String((daemonStatus && daemonStatus.poll_interval) || 60) + ' ' + _('seconds'))
			])
		];

		if (daemonStatus && daemonStatus.last_reset_date) {
			rows.push(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, _('Last Reset')),
				E('td', { 'class': 'td left', 'id': 'last_reset' }, daemonStatus.last_reset_date)
			]));
		}

		return E('table', { 'class': 'table' }, rows);
	},

	updateStatusHeader: function(daemonStatus) {
		var statusEl = document.getElementById('daemon_status');
		var intervalEl = document.getElementById('poll_interval');

		if (statusEl) {
			var running = daemonStatus && daemonStatus.running;
			var badge = running
				? E('span', { 'class': 'label success' }, _('Running'))
				: E('span', { 'class': 'label danger' }, _('Stopped'));
			dom.content(statusEl, badge);
		}

		if (intervalEl) {
			dom.content(intervalEl, String((daemonStatus && daemonStatus.poll_interval) || 60) + ' ' + _('seconds'));
		}
	},

	updateDeviceTable: function(devices) {
		var statusLabels = {
			'active': _('Active'),
			'blocked': _('Blocked'),
			'unlimited': _('Unlimited'),
			'outside_window': _('Outside Window'),
			'no_schedule': _('No Schedule'),
			'disabled': _('Disabled'),
			'unknown': '-'
		};

		devices.forEach(function(device) {
			var row = document.querySelector('tr[data-sid="' + device.id + '"]');
			if (!row) return;

			// Update Usage column
			var usageCell = row.querySelector('td[data-name="_usage"]');
			if (usageCell) {
				var usageText = !device.has_schedule_today ? '-' :
					String(device.usage_minutes || 0) + ' min';
				dom.content(usageCell, usageText);
			}

			// Update Remaining column
			var remainingCell = row.querySelector('td[data-name="_remaining"]');
			if (remainingCell) {
				var remainingText = '-';
				if (device.has_schedule_today && device.in_time_window) {
					if (device.status === 'unlimited') {
						remainingText = _('Unlimited');
					} else {
						var remaining = (device.todays_limit || 0) - (device.usage_minutes || 0);
						if (remaining < 0) remaining = 0;
						remainingText = String(remaining) + ' min';
					}
				}
				dom.content(remainingCell, remainingText);
			}

			// Update Status column
			var statusCell = row.querySelector('td[data-name="_status"]');
			if (statusCell) {
				var status = device.status || 'unknown';
				dom.content(statusCell, statusLabels[status] || status);
			}

			// Update IP column (can change dynamically)
			var ipCell = row.querySelector('td[data-name="_ip"]');
			if (ipCell) {
				dom.content(ipCell, device.ip || '-');
			}
		});
	},

	render: function(data) {
		var devices = data[1] && data[1].devices ? data[1].devices : [];
		var daemonStatus = data[2] || {};
		var hosts = data[3];
		var calibrations = data[4] || [];
		var self = this;

		// Merge calibration data into devices
		var calMap = {};
		calibrations.forEach(function(item) {
			if (item && item.cal) calMap[item.id] = item.cal;
		});

		// Populate module-level store for option method access
		devices.forEach(function(d) {
			if (calMap[d.id]) d.calibration = calMap[d.id];
			deviceDataStore[d.id] = d;
		});

		var m, s, o;

		m = new form.Map('device_timer', _('Device Timer'),
			_('Monitor and manage device usage times.'));

		// Status Header Section
		s = m.section(form.NamedSection, 'status_header', 'status_header');
		s.render = L.bind(function() {
			return E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Service Status')),
				E('div', { 'class': 'cbi-section-node' }, this.renderStatusHeader(daemonStatus))
			]);
		}, this);

		// Device Section
		s = m.section(form.GridSection, 'device', _('Monitored Devices'));
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;
		s.nodescriptions = true;

		s.modaltitle = function(section_id) {
			var name = uci.get('device_timer', section_id, 'name');
			return name ? _('Edit Device') + ': ' + name : _('Add Device');
		};

		s.tab('general', _('General'));
		s.tab('schedule', _('Schedule'));
		s.tab('advanced', _('Advanced'));
		s.tab('calibration', _('Calibration'));

		// Table columns (visible in grid)
		o = s.taboption('general', form.Flag, 'enabled', _('Enabled'));
		o.editable = true;
		o.default = '1';

		o = s.taboption('general', form.Value, 'name', _('Name'));
		o.rmempty = false;

		o = s.taboption('general', form.Value, '_device_id', _('Device ID'),
			_('Unique device identifier.'));
		o.modalonly = true;
		o.readonly = true;
		o.cfgvalue = function(section_id) {
			return section_id || '-';
		};
		o.write = function() {};

		// MAC column (from config, displayed in table)
		o = s.option(form.DummyValue, '_mac', _('MAC'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			var device = deviceDataStore[section_id] || {};
			return device.mac || '-';
		};

		// IP column (auto-resolved from MAC, displayed in table)
		o = s.option(form.DummyValue, '_ip', _('IP'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			var device = deviceDataStore[section_id] || {};
			return device.ip || '-';
		};

		// Dynamic status columns (read-only, from RPC data)
		o = s.option(form.DummyValue, '_usage', _('Usage'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			var device = deviceDataStore[section_id] || {};
			if (!device.has_schedule_today) return '-';
			return String(device.usage_minutes || 0) + ' min';
		};

		o = s.option(form.DummyValue, '_remaining', _('Remaining'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			var device = deviceDataStore[section_id] || {};
			if (!device.has_schedule_today || !device.in_time_window) return '-';
			if (device.status === 'unlimited') return _('Unlimited');
			var remaining = (device.todays_limit || 0) - (device.usage_minutes || 0);
			if (remaining < 0) remaining = 0;
			return String(remaining) + ' min';
		};

		o = s.option(form.DummyValue, '_status', _('Status'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			var device = deviceDataStore[section_id] || {};
			var status = device.status || 'unknown';
			var labels = {
				'active': _('Active'),
				'blocked': _('Blocked'),
				'unlimited': _('Unlimited'),
				'outside_window': _('Outside Window'),
				'no_schedule': _('No Schedule'),
				'disabled': _('Disabled'),
				'unknown': '-'
			};
			return labels[status] || status;
		};

		// Modal-only fields
		o = s.taboption('general', form.Value, 'mac', _('MAC Address'),
			_('Required for reliable device blocking.'));
		o.datatype = 'macaddr';
		o.rmempty = false;
		o.modalonly = true;
		if (hosts) {
			var macHints = hosts.getMACHints();
			if (macHints && macHints.length) {
				macHints.forEach(function(hint) {
					var mac = hint[0];
					var label = hint[1] ? '%s (%s)'.format(mac, hint[1]) : mac;
					o.value(mac, label);
				});
			}
		}

		o = s.taboption('schedule', form.DynamicList, 'schedule', _('Schedule'),
			_('Internet access schedule per day.') + '<br><br>' +
			'<b>' + _('Format:') + '</b> Day,HH:MM-HH:MM,Limit (min)<br>' +
			'<b>' + _('Days:') + '</b> Mon, Tue, Wed, Thu, Fri, Sat, Sun<br>' +
			'<b>' + _('Example:') + '</b> Mon,14:00-18:00,60<br><br>' +
			_('Non-overlapping time windows per day.'));
		o.rmempty = true;
		o.modalonly = true;
		o.placeholder = 'Mon,14:00-18:00,60';
		o.validate = function(section_id, value) {
			if (!value) return true;
			// Format: "Day,HH:MM-HH:MM,Limit" where Limit is in minutes (0 = unlimited)
			var pattern = /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun),([01]?[0-9]|2[0-3]):[0-5][0-9]-([01]?[0-9]|2[0-3]):[0-5][0-9],(0|[1-9]\d*)$/;
			if (!pattern.test(value))
				return _('Invalid format. Use: Day,HH:MM-HH:MM,Limit in min (e.g., Mon,14:00-18:00,60 or Mon,06:00-22:00,0 for unlimited)');

			// Get all current schedule values and check for overlaps
			var allValues = this.formvalue(section_id);
			if (allValues && allValues.length > 1) {
				var result = validateScheduleOverlaps(allValues);
				if (!result.valid) {
					return result.error;
				}
			}
			return true;
		};

		o = s.taboption('advanced', form.Value, 'traffic_threshold', _('Traffic Threshold'),
			_('Override global threshold, e.g., 6M or 500K.'));
		o.placeholder = _('Use global default');
		o.rmempty = true;
		o.modalonly = true;
		o.validate = function(section_id, value) {
			if (!value) return true;
			if (!/^\d+[KkMm]$/.test(value))
				return _('Invalid format, use e.g., 6M or 500K');
			return true;
		};

		// Calibration Tab - Status as individual form fields
		// Fix badge alignment: force baseline alignment on DummyValue rows
		// so badge text sits on same baseline as label text.
		if (!document.getElementById('calibration-badge-fix')) {
			document.head.appendChild(E('style', { 'id': 'calibration-badge-fix' },
				'[data-tab="calibration"] .cbi-value[data-widget="CBI.DummyValue"] { align-items: baseline !important }'));
		}

		o = s.taboption('calibration', form.DummyValue, '_calibration_status', _('Status'));
		o.modalonly = true;
		o.renderWidget = function(section_id) {
			var device = deviceDataStore[section_id] || {};
			var cal = device.calibration || { status: 'idle' };

			if (cal.status === 'running')
				return E('span', { 'class': 'label notice' }, _('Running'));
			if (cal.status === 'completed')
				return E('span', { 'class': 'label success' }, _('Completed'));
			if (cal.status === 'error')
				return E('span', {}, [
					E('span', { 'class': 'label danger' }, _('Error')),
					E('span', { 'style': 'margin-left:0.5em' }, cal.error_message || _('Unknown error'))
				]);
			return E('span', { 'class': 'label' }, _('Idle'));
		};
		o.formvalue = function(section_id) {
			var device = deviceDataStore[section_id] || {};
			var cal = device.calibration || { status: 'idle' };
			return cal.status || 'idle';
		};

		o = s.taboption('calibration', form.DummyValue, '_calibration_progress', _('Progress'));
		o.modalonly = true;
		o.depends('_calibration_status', 'running');
		o.renderWidget = function(section_id) {
			var device = deviceDataStore[section_id] || {};
			var cal = device.calibration || {};
			return E('div', {}, [
				E('div', {}, _('Elapsed: %d / %d seconds (%d samples)')
					.format(cal.elapsed || 0, cal.duration || 0, cal.sample_count || 0)),
				E('div', { 'class': 'cbi-progressbar' }, [
					E('div', { 'style': 'width:' + (cal.progress_percent || 0) + '%' })
				])
			]);
		};

		o = s.taboption('calibration', form.DummyValue, '_calibration_p90', _('P90'));
		o.modalonly = true;
		o.depends('_calibration_status', 'completed');
		o.renderWidget = function(section_id) {
			var device = deviceDataStore[section_id] || {};
			var cal = device.calibration || {};
			return E('span', {}, formatBytes(cal.result_p90 || 0));
		};

		o = s.taboption('calibration', form.DummyValue, '_calibration_recommended', _('Recommended Threshold'));
		o.modalonly = true;
		o.depends('_calibration_status', 'completed');
		o.renderWidget = function(section_id) {
			var device = deviceDataStore[section_id] || {};
			var cal = device.calibration || {};
			return E('span', {}, formatBytes(cal.result_recommended || 0));
		};

		o = s.taboption('calibration', form.ListValue, '_calibration_duration', _('Measurement Duration'),
			_('Measures idle background traffic to determine the optimal usage detection threshold.') + ' ' +
			_('Ensure the device is connected but not actively used during calibration.'));
		o.modalonly = true;
		o.value('300', _('5 minutes'));
		o.value('900', _('15 minutes'));
		o.value('1800', _('30 minutes (recommended)'));
		o.value('3600', _('60 minutes'));
		o.default = '1800';

		o = s.taboption('calibration', form.Button, '_calibration_action', _('Actions'));
		o.modalonly = true;
		o.inputtitle = function(section_id) {
			var device = deviceDataStore[section_id] || {};
			var cal = device.calibration || { status: 'idle' };
			return (cal.status === 'running') ? _('Cancel Calibration') : _('Start Calibration');
		};
		o.onclick = function(ev, section_id) {
			var device = deviceDataStore[section_id] || {};
			var cal = device.calibration || { status: 'idle' };

			if (cal.status === 'running') {
				return callCancelCalibration(section_id).then(function(result) {
					if (result.success) {
						ui.addNotification(null, E('p', _('Calibration cancelled')), 'info');
						window.location.reload();
					} else {
						ui.addNotification(null, E('p', result.error || _('Failed')), 'error');
					}
				});
			} else {
				var durationEl = document.querySelector('[data-name="_calibration_duration"] select');
				var duration = durationEl ? parseInt(durationEl.value, 10) : 1800;

				return callStartCalibration(section_id, duration, 10).then(function(result) {
					if (result.success) {
						ui.addNotification(null, E('p', _('Calibration started')), 'success');
						window.location.reload();
					} else {
						ui.addNotification(null, E('p', result.error || _('Failed')), 'error');
					}
				});
			}
		};

		o = s.taboption('calibration', form.Button, '_calibration_apply', _('Apply'));
		o.modalonly = true;
		o.inputtitle = _('Apply Recommended Threshold');
		o.depends('_calibration_status', 'completed');
		o.onclick = function(ev, section_id) {
			return ui.showModal(_('Apply Calibration'), [
				E('p', {}, _('This will update the traffic threshold for this device. Continue?')),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
					E('button', { 'class': 'btn cbi-button-action', 'click': function() {
						return callApplyCalibration(section_id).then(function(result) {
							ui.hideModal();
							if (result.success) {
								ui.addNotification(null, E('p', _('Threshold applied: %s').format(result.threshold)), 'success');
								window.location.reload();
							} else {
								ui.addNotification(null, E('p', result.error || _('Failed')), 'error');
							}
						});
					}}, _('Apply'))
				])
			]);
		};

		// Polling for live updates
		poll.add(L.bind(function() {
			var deviceIds = Object.keys(deviceDataStore);

			var calibrationPromises = deviceIds.map(function(id) {
				return callGetCalibration(id).then(function(cal) {
					return { id: id, cal: cal };
				}).catch(function() {
					return { id: id, cal: null };
				});
			});

			return Promise.all([
				callDeviceTimerDevices(),
				callDeviceTimerStatus(),
				Promise.all(calibrationPromises)
			]).then(L.bind(function(results) {
				var newDevices = results[0] && results[0].devices ? results[0].devices : [];
				var newStatus = results[1] || {};
				var calibrations = results[2] || [];

				calibrations.forEach(function(item) {
					if (deviceDataStore[item.id] && item.cal) {
						deviceDataStore[item.id].calibration = item.cal;
					}
				});

				newDevices.forEach(function(d) {
					if (deviceDataStore[d.id] && deviceDataStore[d.id].calibration) {
						d.calibration = deviceDataStore[d.id].calibration;
					}
					deviceDataStore[d.id] = d;
				});

				this.updateStatusHeader(newStatus);
				this.updateDeviceTable(newDevices);
			}, this)).catch(function() {
				// Polling error - stale UI until next poll succeeds
			});
		}, this), 30);

		return m.render();
	}
});
