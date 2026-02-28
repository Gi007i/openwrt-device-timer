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
	params: ['id', 'duration']
});

var callStartCalibrationPhase2 = rpc.declare({
	object: 'luci.device-timer',
	method: 'startcalibrationphase2',
	params: ['id']
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
var activeCalibrationSectionId = null;
var calibrationActionTime = {};

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

// Build a calibration status badge element
function renderCalibrationBadge(cal) {
	if (cal.status === 'phase1_running')
		return E('span', { 'class': 'label notice' }, _('Phase 1: Idle Measurement'));
	if (cal.status === 'phase1_done')
		return E('span', { 'class': 'label success' }, _('Phase 1 Complete'));
	if (cal.status === 'phase2_running')
		return E('span', { 'class': 'label notice' }, _('Phase 2: Usage Measurement'));
	if (cal.status === 'completed')
		return E('span', { 'class': 'label success' }, _('Completed'));
	if (cal.status === 'error')
		return E('span', {}, [
			E('span', { 'class': 'label danger' }, _('Error')),
			E('span', { 'style': 'margin-left:0.5em' }, cal.error_message || _('Unknown error'))
		]);
	return E('span', { 'class': 'label' }, _('Idle'));
}

// Update calibration UI in open modal during polling
function updateCalibrationInModal() {
	if (!document.querySelector('.cbi-modal')) {
		activeCalibrationSectionId = null;
		return;
	}
	var sid = activeCalibrationSectionId;
	if (!sid || !deviceDataStore[sid]) return;

	var container = document.getElementById('calibration-ui-container');
	if (!container) return;

	var calData = deviceDataStore[sid].calibration;
	var cal = (calData && calData.status) ? calData : { status: 'idle' };

	// Update status badge
	var statusField = document.getElementById('cal-status-field');
	if (statusField) dom.content(statusField, renderCalibrationBadge(cal));

	// Row visibility
	var showPhase1 = (cal.status === 'phase1_running');
	var showPhase2 = (cal.status === 'phase2_running');
	var showPhase1Results = (cal.status === 'phase1_done');
	var showResults = (cal.status === 'completed');
	var showDuration = (cal.status === 'idle' || cal.status === 'completed' || cal.status === 'error');
	var showIdleHint = (cal.status === 'idle' || cal.status === 'error');
	var showApply = (cal.status === 'completed');

	var rows = {
		'cal-row-phase1': showPhase1,
		'cal-row-phase2': showPhase2,
		'cal-row-phase1-results': showPhase1Results,
		'cal-row-idle-stats': showResults,
		'cal-row-usage-stats': showResults,
		'cal-row-recommended': showResults,
		'cal-row-duration': showDuration,
		'cal-row-idle-hint': showIdleHint,
		'cal-row-apply': showApply
	};
	var ids = Object.keys(rows);
	for (var i = 0; i < ids.length; i++) {
		var el = document.getElementById(ids[i]);
		if (el) el.style.display = rows[ids[i]] ? '' : 'none';
	}

	// Update phase 1 progress
	if (showPhase1) {
		var p1 = document.getElementById('cal-phase1-content');
		if (p1) {
			dom.content(p1, E('div', {}, [
				E('div', {}, [
					E('em', {}, _('Do not use the device during this phase.')),
					' ',
					_('%d%% (%d samples)').format(cal.phase1_progress || 0, cal.phase1_samples || 0)
				]),
				E('div', { 'class': 'cbi-progressbar' }, [
					E('div', { 'style': 'width:' + (cal.phase1_progress || 0) + '%' })
				])
			]));
		}
	}

	// Update phase 2 progress
	if (showPhase2) {
		var p2 = document.getElementById('cal-phase2-content');
		if (p2) {
			dom.content(p2, E('div', {}, [
				E('div', {}, [
					E('em', {}, _('Now use the device normally.')),
					' ',
					_('%d%% (%d samples)').format(cal.phase2_progress || 0, cal.phase2_samples || 0)
				]),
				E('div', { 'class': 'cbi-progressbar' }, [
					E('div', { 'style': 'width:' + (cal.phase2_progress || 0) + '%' })
				])
			]));
		}
	}

	// Update phase 1 results
	if (showPhase1Results) {
		var p1r = document.getElementById('cal-phase1-results-content');
		if (p1r) {
			dom.content(p1r, E('div', {}, [
				E('div', {}, _('Idle measurement complete.') + ' ' +
					_('%d samples collected.').format(cal.phase1_samples || 0)),
				E('div', { 'style': 'margin-top:0.5em' },
					E('em', {}, _('Start using the device, then click the button below to begin usage measurement.')))
			]));
		}
	}

	// Update completed results
	if (showResults) {
		var idleField = document.getElementById('cal-idle-stats-content');
		if (idleField) {
			dom.content(idleField, E('span', {},
				formatBytes(cal.result_idle_p95 || 0) +
				' (' + _('Median') + ': ' + formatBytes(cal.result_idle_median || 0) + ')'));
		}

		var usageField = document.getElementById('cal-usage-stats-content');
		if (usageField) {
			var outlierText = (cal.result_stream_outliers > 0)
				? ' (' + cal.result_stream_outliers + ' ' + _('outliers removed') + ')'
				: '';
			dom.content(usageField, E('span', {},
				formatBytes(cal.result_stream_p5 || 0) +
				' (' + _('Median') + ': ' + formatBytes(cal.result_stream_median || 0) + ')' +
				outlierText));
		}

		var recField = document.getElementById('cal-recommended-content');
		if (recField) {
			var recChildren = [
				E('strong', {}, formatBytes(cal.result_recommended || 0)),
				E('br', {}),
				E('em', { 'style': 'font-size:90%' }, _('The result is a guideline — manual adjustment is recommended.'))
			];
			if (cal.result_overlap) {
				recChildren.push(E('br', {}));
				recChildren.push(E('em', { 'style': 'font-size:90%; color:#c00' },
					_('Idle traffic overlaps with usage traffic — result may be unreliable.')));
			}
			dom.content(recField, E('span', {}, recChildren));
		}
	}

	// Update action button text
	var actionBtn = document.getElementById('cal-action-btn');
	if (actionBtn) {
		var newTitle;
		if (cal.status === 'phase1_running' || cal.status === 'phase2_running')
			newTitle = _('Cancel Calibration');
		else if (cal.status === 'phase1_done')
			newTitle = _('Start Usage Measurement');
		else
			newTitle = _('Start Idle Measurement');
		actionBtn.textContent = newTitle;
	}
}

// Calibration Tab widget — extends DummyValue for stable renderWidget
// Pattern from dhcp.js CBILeaseStatus: renderWidget in prototype, not instance
var CBICalibrationUI = form.DummyValue.extend({
	__name__: 'CBI.CalibrationUI',

	renderWidget: function(section_id) {
		activeCalibrationSectionId = section_id;
		var device = deviceDataStore[section_id] || {};
		var calData = device.calibration;
		var cal = (calData && calData.status) ? calData : { status: 'idle' };
		var status = cal.status || 'idle';

		var showPhase1 = (status === 'phase1_running');
		var showPhase2 = (status === 'phase2_running');
		var showPhase1Results = (status === 'phase1_done');
		var showResults = (status === 'completed');
		var showDuration = (status === 'idle' || status === 'completed' || status === 'error');
		var showIdleHint = (status === 'idle' || status === 'error');
		var showApply = (status === 'completed');

		function calRow(id, label, content, visible) {
			return E('div', {
				'class': 'cbi-value', 'id': id,
				'style': visible ? '' : 'display:none'
			}, [
				E('label', { 'class': 'cbi-value-title' }, label),
				E('div', { 'class': 'cbi-value-field' }, content)
			]);
		}

		// Action button title
		var actionTitle;
		if (status === 'phase1_running' || status === 'phase2_running')
			actionTitle = _('Cancel Calibration');
		else if (status === 'phase1_done')
			actionTitle = _('Start Usage Measurement');
		else
			actionTitle = _('Start Idle Measurement');

		// Action button handler
		var actionBtn = E('button', {
			'class': 'btn cbi-button-action', 'id': 'cal-action-btn',
			'click': function() {
				var dev = deviceDataStore[section_id] || {};
				var c = dev.calibration || { status: 'idle' };

				if (c.status === 'phase1_running' || c.status === 'phase2_running') {
					calibrationActionTime[section_id] = Date.now();
					callCancelCalibration(section_id).then(function(result) {
						if (result.success) {
							if (deviceDataStore[section_id])
								deviceDataStore[section_id].calibration = { status: 'idle' };
							updateCalibrationInModal();
						} else {
							ui.addNotification(null, E('p', result.error || _('Failed')), 'error');
						}
					}).catch(function() {
						ui.addNotification(null, E('p', _('Failed')), 'error');
					});
				} else if (c.status === 'phase1_done') {
					calibrationActionTime[section_id] = Date.now();
					callStartCalibrationPhase2(section_id).then(function(result) {
						if (result.success) {
							var prev = (deviceDataStore[section_id] && deviceDataStore[section_id].calibration) || {};
							if (deviceDataStore[section_id])
								deviceDataStore[section_id].calibration = {
									status: 'phase2_running',
									phase1_elapsed: prev.idle_duration || 0,
									phase2_elapsed: 0,
									idle_duration: prev.idle_duration || 0,
									usage_duration: prev.usage_duration || 0,
									phase1_samples: prev.phase1_samples || 0,
									phase2_samples: 0,
									phase1_progress: 100,
									phase2_progress: 0
								};
							updateCalibrationInModal();
						} else {
							ui.addNotification(null, E('p', result.error || _('Failed')), 'error');
						}
					}).catch(function() {
						ui.addNotification(null, E('p', _('Failed')), 'error');
					});
				} else {
					var durEl = document.getElementById('calibration-duration-select');
					var duration = durEl ? parseInt(durEl.value, 10) : 1800;

					calibrationActionTime[section_id] = Date.now();
					callStartCalibration(section_id, duration).then(function(result) {
						if (result.success) {
							if (deviceDataStore[section_id])
								deviceDataStore[section_id].calibration = {
									status: 'phase1_running',
									phase1_elapsed: 0,
									phase2_elapsed: 0,
									idle_duration: Math.floor(duration / 2),
									usage_duration: duration - Math.floor(duration / 2),
									phase1_samples: 0,
									phase2_samples: 0,
									phase1_progress: 0,
									phase2_progress: 0
								};
							updateCalibrationInModal();
						} else {
							ui.addNotification(null, E('p', result.error || _('Failed')), 'error');
						}
					}).catch(function() {
						ui.addNotification(null, E('p', _('Failed')), 'error');
					});
				}
			}
		}, actionTitle);

		// Apply button handler
		var applyBtn = E('button', {
			'class': 'btn cbi-button-action', 'id': 'cal-apply-btn',
			'click': function() {
				var dev = deviceDataStore[section_id] || {};
				var calState = (dev.calibration && dev.calibration.status) ? dev.calibration : {};
				var modalContent = [
					E('p', {}, _('This will update the traffic threshold for this device. Continue?'))
				];
				if (calState.result_overlap) {
					modalContent.push(E('p', { 'style': 'color:#c00' },
						_('Idle traffic overlaps with usage traffic — result may be unreliable.')));
				}
				modalContent.push(E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
					E('button', { 'class': 'btn cbi-button-action', 'click': function() {
						calibrationActionTime[section_id] = Date.now();
						callApplyCalibration(section_id).then(function(result) {
							ui.hideModal();
							if (result.success) {
								ui.addNotification(null, E('p', _('Threshold applied: %s').format(result.threshold)), 'success');
								if (deviceDataStore[section_id])
									deviceDataStore[section_id].calibration = { status: 'idle' };
								updateCalibrationInModal();
							} else {
								ui.addNotification(null, E('p', result.error || _('Failed')), 'error');
							}
						}).catch(function() {
							ui.hideModal();
							ui.addNotification(null, E('p', _('Failed')), 'error');
						});
					}}, _('Apply'))
				]));
				ui.showModal(_('Apply Calibration'), modalContent);
			}
		}, _('Apply Recommended Threshold'));
		var savedDuration = uci.get('device_timer', section_id, 'calibration_duration') || '1800';
		var durationSelect = E('select', { 'class': 'cbi-input-select', 'id': 'calibration-duration-select' }, [
			E('option', { 'value': '300' }, _('5 minutes (quick test)')),
			E('option', { 'value': '900' }, _('15 minutes')),
			E('option', { 'value': '1800' }, _('30 minutes (recommended)')),
			E('option', { 'value': '3600' }, _('60 minutes (best accuracy)'))
		]);
		durationSelect.value = savedDuration;
		durationSelect.addEventListener('change', function() {
			uci.set('device_timer', section_id, 'calibration_duration', this.value);
			uci.save('device_timer');
		});

		return E('div', { 'id': 'calibration-ui-container' }, [
			E('style', {}, [
				'.cbi-value[data-name="_calibration_ui"] { padding:0; margin:0; border:none }',
				'.cbi-value[data-name="_calibration_ui"] > .cbi-value-title { display:none }',
				'.cbi-value[data-name="_calibration_ui"] > .cbi-value-field { margin-left:0; padding:0 }',
				'#calibration-ui-container > .cbi-value { display: flex; align-items: baseline !important }'
			].join('\n')),

			calRow('cal-row-status', _('Status'),
				E('div', { 'id': 'cal-status-field' }, renderCalibrationBadge(cal)), true),

			calRow('cal-row-phase1', _('Phase 1: Idle'),
				E('div', { 'id': 'cal-phase1-content' }, showPhase1 ? [
					E('div', {}, [
						E('em', {}, _('Do not use the device during this phase.')),
						' ',
						_('%d%% (%d samples)').format(cal.phase1_progress || 0, cal.phase1_samples || 0)
					]),
					E('div', { 'class': 'cbi-progressbar' }, [
						E('div', { 'style': 'width:' + (cal.phase1_progress || 0) + '%' })
					])
				] : []), showPhase1),

			calRow('cal-row-phase2', _('Phase 2: Usage'),
				E('div', { 'id': 'cal-phase2-content' }, showPhase2 ? [
					E('div', {}, [
						E('em', {}, _('Now use the device normally.')),
						' ',
						_('%d%% (%d samples)').format(cal.phase2_progress || 0, cal.phase2_samples || 0)
					]),
					E('div', { 'class': 'cbi-progressbar' }, [
						E('div', { 'style': 'width:' + (cal.phase2_progress || 0) + '%' })
					])
				] : []), showPhase2),

			calRow('cal-row-phase1-results', _('Idle Results'),
				E('div', { 'id': 'cal-phase1-results-content' }, showPhase1Results ? [
					E('div', {}, _('Idle measurement complete.') + ' ' +
						_('%d samples collected.').format(cal.phase1_samples || 0)),
					E('div', { 'style': 'margin-top:0.5em' },
						E('em', {}, _('Start using the device, then click the button below to begin usage measurement.')))
				] : []), showPhase1Results),

			calRow('cal-row-idle-stats', _('Idle Traffic'),
				E('div', { 'id': 'cal-idle-stats-content' }, showResults ? [
					E('span', {}, formatBytes(cal.result_idle_p95 || 0) +
						' (' + _('Median') + ': ' + formatBytes(cal.result_idle_median || 0) + ')')
				] : []), showResults),

			calRow('cal-row-usage-stats', _('Usage Traffic'),
				E('div', { 'id': 'cal-usage-stats-content' }, showResults ? (function() {
					var outlierText = (cal.result_stream_outliers > 0)
						? ' (' + cal.result_stream_outliers + ' ' + _('outliers removed') + ')'
						: '';
					return [E('span', {}, formatBytes(cal.result_stream_p5 || 0) +
						' (' + _('Median') + ': ' + formatBytes(cal.result_stream_median || 0) + ')' +
						outlierText)];
				})() : []), showResults),

			calRow('cal-row-recommended', _('Recommended Threshold'),
				E('div', { 'id': 'cal-recommended-content' }, showResults ? (function() {
					var children = [
						E('strong', {}, formatBytes(cal.result_recommended || 0)),
						E('br', {}),
						E('em', { 'style': 'font-size:90%' }, _('The result is a guideline — manual adjustment is recommended.'))
					];
					if (cal.result_overlap) {
						children.push(E('br', {}));
						children.push(E('em', { 'style': 'font-size:90%; color:#c00' },
							_('Idle traffic overlaps with usage traffic — result may be unreliable.')));
					}
					return children;
				})() : []), showResults),

			calRow('cal-row-duration', _('Measurement Duration'), E('div', {}, [
				durationSelect,
				E('div', { 'class': 'cbi-value-description' },
					_('Measures idle and active traffic in two phases to calculate the optimal usage detection threshold.') + ' ' +
					_('A threshold of 1K is recommended during calibration to avoid the device being blocked.'))
			]), showDuration),

			calRow('cal-row-idle-hint', ' ', E('div', {}, [
				E('em', {}, _('Ensure the device is not being used, then click the button below to begin idle measurement.'))
			]), showIdleHint),

			calRow('cal-row-actions', _('Actions'),
				E('div', {}, [ actionBtn ]), true),

			calRow('cal-row-apply', _('Apply'),
				E('div', {}, [ applyBtn ]), showApply)
		]);
	},

	remove: function() {},
	write: function() {}
});

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
			'paused': _('Paused'),
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
				'paused': _('Paused'),
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

			// Check for zero-duration windows (start == end)
			var valParts = value.split(',');
			var valTimeParts = valParts[1].split('-');
			if (valTimeParts[0] === valTimeParts[1])
				return _('Invalid format: %s').format(value);

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

		// Calibration Tab — extends DummyValue for stable renderWidget
		o = s.taboption('calibration', CBICalibrationUI, '_calibration_ui', ' ');
		o.modalonly = true;

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
					if (deviceDataStore[item.id] && item.cal && item.cal.status) {
						// Skip poll update if user recently performed a calibration action
						var actionTs = calibrationActionTime[item.id];
						if (actionTs && (Date.now() - actionTs) < 10000) {
							return;
						}
						delete calibrationActionTime[item.id];
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
				updateCalibrationInModal();
			}, this)).catch(function() {
				// Polling error - stale UI until next poll succeeds
			});
		}, this), Math.max((daemonStatus && daemonStatus.poll_interval) || 60, 10));

		return m.render();
	}
});
