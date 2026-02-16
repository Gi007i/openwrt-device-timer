'use strict';

// Calculate 90th percentile from array of integers
function calculateP90(samples) {
	if (!samples || !length(samples)) return 0;

	// Convert to integers and create sorted array
	let arr = [];
	for (let i = 0; i < length(samples); i++) {
		push(arr, int(samples[i]));
	}

	// Bubble sort
	for (let i = 0; i < length(arr); i++) {
		for (let j = i + 1; j < length(arr); j++) {
			if (arr[i] > arr[j]) {
				let tmp = arr[i];
				arr[i] = arr[j];
				arr[j] = tmp;
			}
		}
	}

	// P90 index (1-based to 0-based conversion)
	let idx = int(length(arr) * 0.9 + 0.5);
	if (idx < 1) idx = 1;
	if (idx > length(arr)) idx = length(arr);

	return arr[idx - 1];
}

function formatThreshold(bytes) {
	if (bytes < 1024 * 1024) {
		// Minimum 1K, round up
		let kb = int((bytes + 1023) / 1024);
		if (kb < 1) kb = 1;
		return sprintf('%dK', kb);
	} else {
		return sprintf('%dM', int(bytes / (1024 * 1024)));
	}
}

function validateCalibrationParams(duration, interval) {
	const durationInt = int(duration);
	const intervalInt = int(interval);

	if (durationInt < 300 || durationInt > 3600) {
		return { valid: false, error: 'Duration must be between 5 and 60 minutes (300-3600s)' };
	}

	if (intervalInt < 5 || intervalInt > 30) {
		return { valid: false, error: 'Sample interval must be between 5 and 30 seconds' };
	}

	return { valid: true };
}

return {
	calculateP90: calculateP90,
	formatThreshold: formatThreshold,
	validateCalibrationParams: validateCalibrationParams
};
