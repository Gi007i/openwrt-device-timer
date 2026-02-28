'use strict';

import { sqrt } from 'math';

// Bubble sort array of integers (ascending)
function sortArray(samples) {
	let arr = [];
	for (let i = 0; i < length(samples); i++) {
		push(arr, int(samples[i]));
	}
	for (let i = 0; i < length(arr); i++) {
		for (let j = i + 1; j < length(arr); j++) {
			if (arr[i] > arr[j]) {
				let tmp = arr[i];
				arr[i] = arr[j];
				arr[j] = tmp;
			}
		}
	}
	return arr;
}

// Calculate percentile from sorted array
function percentile(sorted, p) {
	if (!sorted || !length(sorted)) return 0;
	let idx = int(length(sorted) * p + 0.5);
	if (idx < 1) idx = 1;
	if (idx > length(sorted)) idx = length(sorted);
	return sorted[idx - 1];
}

// Filter array to keep only values within [lower, upper]
function filterRange(sorted, lower, upper) {
	let result = [];
	for (let i = 0; i < length(sorted); i++) {
		if (sorted[i] >= lower && sorted[i] <= upper) {
			push(result, sorted[i]);
		}
	}
	return result;
}

// Analyze two-phase calibration data and compute recommended threshold
function analyzeCalibration(idleSamples, streamingSamples) {
	if (!idleSamples || !length(idleSamples)) {
		return { error: 'No idle samples' };
	}
	if (!streamingSamples || !length(streamingSamples)) {
		return { error: 'No streaming samples' };
	}

	// 1. Idle: P95 (no outlier removal — bursts are relevant)
	let idleSorted = sortArray(idleSamples);
	let idle_p95 = percentile(idleSorted, 0.95);
	let idle_median = percentile(idleSorted, 0.50);

	// 2. Streaming: IQR cleanup (remove buffering bursts), then P5
	let streamSorted = sortArray(streamingSamples);
	let q1 = percentile(streamSorted, 0.25);
	let q3 = percentile(streamSorted, 0.75);
	let iqr = q3 - q1;
	let upper_fence = q3 + 1.5 * iqr;
	let lower_fence = q1 - 1.5 * iqr;
	if (lower_fence < 0) lower_fence = 0;
	let clean = filterRange(streamSorted, lower_fence, upper_fence);

	// Fallback if IQR removes everything
	if (!length(clean)) {
		clean = streamSorted;
	}

	let stream_p5 = percentile(clean, 0.05);
	let stream_median = percentile(clean, 0.50);

	// 3. Geometric mean = optimal separation point
	let product = idle_p95 * stream_p5;
	let recommended = 0;
	let warning = null;
	if (idle_p95 >= stream_p5) {
		warning = 'Idle traffic overlaps with usage traffic - result may be unreliable';
	}
	if (product > 0) {
		recommended = int(sqrt(product));
	}

	return {
		idle_p95: idle_p95,
		idle_median: idle_median,
		idle_min: idleSorted[0],
		idle_max: idleSorted[length(idleSorted) - 1],
		idle_samples: length(idleSamples),
		stream_p5: stream_p5,
		stream_median: stream_median,
		stream_min: clean[0],
		stream_max: clean[length(clean) - 1],
		stream_samples: length(streamingSamples),
		stream_outliers: length(streamingSamples) - length(clean),
		recommended: recommended,
		warning: warning
	};
}

function formatThreshold(bytes) {
	// Keep KB format up to 10MB for better granularity
	if (bytes < 10 * 1024 * 1024) {
		// Minimum 1K, round up
		let kb = int((bytes + 1023) / 1024);
		if (kb < 1) kb = 1;
		return sprintf('%dK', kb);
	} else {
		return sprintf('%dM', int(bytes / (1024 * 1024)));
	}
}

function validateCalibrationParams(duration) {
	let d = int(duration);
	if (d < 300 || d > 3600) {
		return { valid: false, error: 'Duration must be between 5 and 60 minutes' };
	}
	return { valid: true };
}

return {
	analyzeCalibration: analyzeCalibration,
	formatThreshold: formatThreshold,
	validateCalibrationParams: validateCalibrationParams
};
