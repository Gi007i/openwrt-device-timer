'use strict';
'require view';
'require form';
'require uci';

return view.extend({
	load: function() {
		return uci.load('device_timer');
	},

	render: function() {
		var m, s, o;

		m = new form.Map('device_timer', _('Device Timer Configuration'),
			_('Global settings for device usage monitoring.'));

		// Global Settings Section
		s = m.section(form.TypedSection, 'global', _('Global Settings'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('Enable Monitoring'),
			_('Enable or disable the entire monitoring system.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'default_threshold', _('Default Traffic Threshold'),
			_('Minimum traffic to count as active usage, e.g., 6M or 500K.'));
		o.default = '6M';
		o.placeholder = '6M';
		o.validate = function(section_id, value) {
			if (!value) return true;
			if (!/^\d+[KkMm]$/.test(value))
				return _('Invalid format, use e.g., 6M or 500K');
			return true;
		};

		o = s.option(form.Value, 'poll_interval', _('Poll Interval'),
			_('How often the daemon checks device activity (in seconds).'));
		o.datatype = 'range(10,300)';
		o.default = '60';
		o.placeholder = '60';

		return m.render();
	}
});
