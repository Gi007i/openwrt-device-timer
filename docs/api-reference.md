# API Reference

The Device Timer exposes a [ubus](https://openwrt.org/docs/techref/ubus) JSON-RPC interface at `luci.device-timer`. All endpoints are accessible via HTTP POST to `/ubus` on the router.

## Authentication

Every request requires a valid session token. Obtain one by calling the `session.login` method:

```sh
curl -s -X POST http://ROUTER_IP/ubus \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "call",
    "params": [
      "00000000000000000000000000000000",
      "session",
      "login",
      { "username": "root", "password": "YOUR_PASSWORD" }
    ]
  }'
```

The response contains `ubus_rpc_session` — use this value as `TOKEN` in all subsequent requests. Tokens expire after **5 minutes**.

## Request Format

All API calls follow the ubus JSON-RPC format:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "call",
  "params": ["TOKEN", "luci.device-timer", "METHOD", { ...ARGS }]
}
```

## Quick Reference

| Method | Type | Description |
|--------|------|-------------|
| [`devices`](#devices) | READ | List all configured devices with status |
| [`device`](#device) | READ | Get details for a single device |
| [`settings`](#settings) | READ | Get global daemon settings |
| [`status`](#status) | READ | Get daemon process status |
| [`validate`](#validate) | READ | Validate a list of schedules |
| [`getcalibration`](#getcalibration) | READ | Get calibration progress and results |
| [`reset`](#reset) | WRITE | Reset usage counter for a device |
| [`setflatrate`](#setflatrate) | WRITE | Enable or disable flatrate mode |
| [`setpause`](#setpause) | WRITE | Temporarily block a device (overrides flatrate) |
| [`startcalibration`](#startcalibration) | WRITE | Start calibration phase 1 (idle measurement) |
| [`startcalibrationphase2`](#startcalibrationphase2) | WRITE | Start calibration phase 2 (usage measurement) |
| [`applycalibration`](#applycalibration) | WRITE | Apply calibration result as threshold |
| [`cancelcalibration`](#cancelcalibration) | WRITE | Cancel a running calibration |

---

## Endpoints

### devices

List all configured devices with their current status, usage, and schedule information.

**Parameters:** None

**Request:**

```sh
curl -s -X POST http://ROUTER_IP/ubus \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "call",
    "params": ["TOKEN", "luci.device-timer", "devices", {}]
  }'
```

**Response:**

```json
{
  "devices": [
    {
      "id": "tablet_kid",
      "name": "Tablet Kid",
      "ip": "192.168.1.42",
      "mac": "AA:BB:CC:DD:EE:FF",
      "schedule": ["Mon,14:00-18:00,60", "Sat,10:00-20:00,120"],
      "todays_limit": 60,
      "usage_minutes": 23,
      "enabled": 1,
      "status": "active",
      "has_schedule_today": 1,
      "in_time_window": 1,
      "todays_timerange": "14:00-18:00",
      "traffic_threshold": "6M",
      "flatrate_active": 0,
      "pause_active": 0
    }
  ]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `traffic_threshold` | string\|null | Per-device traffic threshold (e.g. `"6M"`), or `null` if using global default |
| `pause_active` | int | `1` if device is paused (blocked), `0` otherwise |

---

### device

Get detailed information for a single device.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | UCI section ID of the device |

**Request:**

```sh
curl -s -X POST http://ROUTER_IP/ubus \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "call",
    "params": ["TOKEN", "luci.device-timer", "device", {"id": "tablet_kid"}]
  }'
```

**Response:**

```json
{
  "id": "tablet_kid",
  "name": "Tablet Kid",
  "ip": "192.168.1.42",
  "mac": "AA:BB:CC:DD:EE:FF",
  "schedule": ["Mon,14:00-18:00,60", "Sat,10:00-20:00,120"],
  "todays_limit": 60,
  "usage_minutes": 23,
  "enabled": 1,
  "status": "active",
  "has_schedule_today": 1,
  "in_time_window": 1,
  "todays_timerange": "14:00-18:00",
  "traffic_threshold": "6M",
  "flatrate_active": 0,
  "pause_active": 0
}
```

**Errors:**
- `Missing device id` — no `id` parameter provided
- `Invalid device id` — `id` contains invalid characters (only alphanumeric and underscore allowed)
- `Device not found` — no device with this UCI section ID exists

---

### settings

Get global daemon settings from UCI configuration.

**Parameters:** None

**Request:**

```sh
curl -s -X POST http://ROUTER_IP/ubus \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "call",
    "params": ["TOKEN", "luci.device-timer", "settings", {}]
  }'
```

**Response:**

```json
{
  "enabled": 1,
  "default_threshold": "6M",
  "poll_interval": 60
}
```

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | int | `1` if daemon is enabled, `0` if disabled |
| `default_threshold` | string | Default traffic threshold for new devices (e.g. `"6M"`) |
| `poll_interval` | int | Daemon polling interval in seconds |

---

### status

Get the current daemon process status.

**Parameters:** None

**Request:**

```sh
curl -s -X POST http://ROUTER_IP/ubus \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "call",
    "params": ["TOKEN", "luci.device-timer", "status", {}]
  }'
```

**Response:**

```json
{
  "running": true,
  "pid": 1234,
  "poll_interval": 60,
  "last_reset_date": "2026-02-17"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `running` | boolean | `true` if daemon process is alive |
| `pid` | int\|null | Process ID, or `null` if not running |
| `poll_interval` | int | Daemon polling interval in seconds |
| `last_reset_date` | string\|null | Date of last midnight counter reset (`YYYY-MM-DD`) |

---

### validate

Validate a list of schedule entries for format errors and overlapping time windows on the same day.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `schedules` | array | Yes | List of schedule strings in `Day,HH:MM-HH:MM,Limit` format |

**Request:**

```sh
curl -s -X POST http://ROUTER_IP/ubus \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "call",
    "params": ["TOKEN", "luci.device-timer", "validate", {
      "schedules": ["Mon,14:00-18:00,60", "Mon,16:00-20:00,90"]
    }]
  }'
```

**Response (valid):**

```json
{
  "valid": true
}
```

**Response (invalid):**

```json
{
  "valid": false,
  "error": "Overlapping schedules on Mon: Mon,14:00-18:00,60 and Mon,16:00-20:00,90"
}
```

**Validation rules:**
- Format must be `Day,HH:MM-HH:MM,Limit` (3 comma-separated parts)
- Valid days: `Mon`, `Tue`, `Wed`, `Thu`, `Fri`, `Sat`, `Sun`
- Time format: `HH:MM` (00:00–23:59)
- Zero-duration windows (start equals end) are rejected
- Limit must be `0` (unlimited) or a positive integer (minutes)
- Overlapping time windows on the same day are rejected
- Overnight windows (e.g. `22:00-06:00`) are supported

---

### getcalibration

Get the current two-phase calibration status and results for a device. Calibration runs in two phases: phase 1 measures idle traffic, phase 2 measures active usage traffic. The recommended threshold is the geometric mean of idle P95 and usage P5.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | UCI section ID of the device |

**Request:**

```sh
curl -s -X POST http://ROUTER_IP/ubus \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "call",
    "params": ["TOKEN", "luci.device-timer", "getcalibration", {"id": "tablet_kid"}]
  }'
```

**Response (idle):**

```json
{
  "id": "tablet_kid",
  "status": "idle",
  "phase1_elapsed": 0,
  "phase2_elapsed": 0,
  "idle_duration": 0,
  "usage_duration": 0,
  "phase1_samples": 0,
  "phase2_samples": 0,
  "phase1_progress": 0,
  "phase2_progress": 0
}
```

**Response (phase 1 running):**

```json
{
  "id": "tablet_kid",
  "status": "phase1_running",
  "phase1_elapsed": 450,
  "phase2_elapsed": 0,
  "idle_duration": 900,
  "usage_duration": 900,
  "poll_interval": 60,
  "phase1_samples": 7,
  "phase2_samples": 0,
  "phase1_progress": 50,
  "phase2_progress": 0
}
```

**Response (completed):**

```json
{
  "id": "tablet_kid",
  "status": "completed",
  "phase1_elapsed": 900,
  "phase2_elapsed": 900,
  "idle_duration": 900,
  "usage_duration": 900,
  "poll_interval": 60,
  "phase1_samples": 15,
  "phase2_samples": 15,
  "phase1_progress": 100,
  "phase2_progress": 100,
  "result_idle_p95": 4061,
  "result_idle_median": 1200,
  "result_stream_p5": 1266317,
  "result_stream_median": 2100000,
  "result_stream_outliers": 2,
  "result_recommended": 71680,
  "result_overlap": 0,
  "error_message": ""
}
```

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Device identifier |
| `status` | string | `idle`, `phase1_running`, `phase1_done`, `phase2_running`, `completed`, or `error` |
| `phase1_elapsed` | int | Seconds elapsed in phase 1 (idle measurement) |
| `phase2_elapsed` | int | Seconds elapsed in phase 2 (usage measurement) |
| `idle_duration` | int | Total duration of phase 1 in seconds (half of total duration) |
| `usage_duration` | int | Total duration of phase 2 in seconds (half of total duration) |
| `poll_interval` | int | Daemon polling interval in seconds (only present when calibration data exists) |
| `phase1_samples` | int | Number of idle traffic samples collected |
| `phase2_samples` | int | Number of usage traffic samples collected |
| `phase1_progress` | int | Phase 1 completion percentage (0–100) |
| `phase2_progress` | int | Phase 2 completion percentage (0–100) |
| `result_idle_p95` | int | 95th percentile of idle traffic in bytes |
| `result_idle_median` | int | Median idle traffic in bytes |
| `result_stream_p5` | int | 5th percentile of usage traffic in bytes (after IQR outlier removal) |
| `result_stream_median` | int | Median usage traffic in bytes |
| `result_stream_outliers` | int | Number of streaming samples removed as outliers |
| `result_recommended` | int | Recommended threshold in bytes: `sqrt(idle_p95 × stream_p5)` |
| `result_overlap` | int | `1` if idle traffic overlaps with usage traffic (result may be unreliable), `0` otherwise |
| `error_message` | string | Error description (set by daemon on failure) |

**Errors:**
- `Missing device id`
- `Invalid device id`
- `Device not found`

---

### reset

Reset the usage counter for a device. The counter is set to zero and the daemon is signaled to process the change immediately. The device is unblocked within seconds.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | UCI section ID of the device |

**Request:**

```sh
curl -s -X POST http://ROUTER_IP/ubus \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "call",
    "params": ["TOKEN", "luci.device-timer", "reset", {"id": "tablet_kid"}]
  }'
```

**Response:**

```json
{
  "success": true,
  "id": "tablet_kid",
  "message": "Counter reset successfully"
}
```

**Errors:**
- `Missing device id`
- `Invalid device id`
- `Device not found`

---

### setflatrate

Enable or disable flatrate mode for a device. When enabled, the device has unlimited access regardless of time limits. The daemon is signaled to process the change immediately.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | UCI section ID of the device |
| `enabled` | int | Yes | `1` to enable, `0` to disable |

**Request:**

```sh
curl -s -X POST http://ROUTER_IP/ubus \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "call",
    "params": ["TOKEN", "luci.device-timer", "setflatrate", {"id": "tablet_kid", "enabled": 1}]
  }'
```

**Response:**

```json
{
  "success": true,
  "id": "tablet_kid",
  "flatrate": 1,
  "message": "Flatrate enabled"
}
```

**Errors:**
- `Missing device id`
- `Missing enabled parameter`
- `Invalid device id`
- `Invalid enabled value (must be 0 or 1)`
- `Device not found`

---

### setpause

Temporarily block a device's internet access. When enabled, the device is immediately blocked regardless of schedule, usage, or flatrate status. Pause takes priority over all other access rules. The daemon is signaled to process the change immediately.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | UCI section ID of the device |
| `enabled` | int | Yes | `1` to pause (block), `0` to unpause |

**Request:**

```sh
curl -s -X POST http://ROUTER_IP/ubus \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "call",
    "params": ["TOKEN", "luci.device-timer", "setpause", {"id": "tablet_kid", "enabled": 1}]
  }'
```

**Response:**

```json
{
  "success": true,
  "id": "tablet_kid",
  "paused": 1,
  "message": "Pause enabled"
}
```

**Errors:**
- `Missing device id`
- `Missing enabled parameter`
- `Invalid device id`
- `Invalid enabled value (must be 0 or 1)`
- `Device not found`

---

### startcalibration

Start a two-phase calibration run. Phase 1 (idle measurement) begins immediately. The total duration is split equally between the two phases. Traffic is sampled once per daemon poll interval.

**Parameters:**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `id` | string | Yes | — | UCI section ID of the device |
| `duration` | int | No | `1800` | Total calibration duration in seconds (300–3600), split 50/50 between phases |

**Request:**

```sh
curl -s -X POST http://ROUTER_IP/ubus \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "call",
    "params": ["TOKEN", "luci.device-timer", "startcalibration", {
      "id": "tablet_kid",
      "duration": 1800
    }]
  }'
```

**Response:**

```json
{
  "success": true,
  "id": "tablet_kid",
  "duration": 1800,
  "message": "Calibration started (phase 1: idle measurement)"
}
```

**Errors:**
- `Missing device id`
- `Invalid device id`
- `Device not found`
- `Device must be enabled for calibration`
- `Duration must be between 5 and 60 minutes`

---

### startcalibrationphase2

Start calibration phase 2 (usage measurement). Phase 1 must be completed first (`phase1_done` status). The user should actively use the device during this phase to generate representative traffic.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | UCI section ID of the device |

**Request:**

```sh
curl -s -X POST http://ROUTER_IP/ubus \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "call",
    "params": ["TOKEN", "luci.device-timer", "startcalibrationphase2", {"id": "tablet_kid"}]
  }'
```

**Response:**

```json
{
  "success": true,
  "id": "tablet_kid",
  "message": "Calibration phase 2 started (usage measurement)"
}
```

**Errors:**
- `Missing device id`
- `Invalid device id`
- `Phase 1 must be completed before starting phase 2`

---

### applycalibration

Apply the recommended threshold from a completed calibration to the device's UCI configuration. The calibration state is cleared after applying.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | UCI section ID of the device |

**Request:**

```sh
curl -s -X POST http://ROUTER_IP/ubus \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "call",
    "params": ["TOKEN", "luci.device-timer", "applycalibration", {"id": "tablet_kid"}]
  }'
```

**Response:**

```json
{
  "success": true,
  "id": "tablet_kid",
  "threshold": "5M",
  "message": "Threshold applied successfully"
}
```

**Errors:**
- `Missing device id`
- `Invalid device id`
- `No completed calibration found`
- `Invalid calibration result`
- `Failed to commit UCI changes`

---

### cancelcalibration

Cancel an active calibration (any phase). Has no effect if calibration status is `idle`.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | UCI section ID of the device |

**Request:**

```sh
curl -s -X POST http://ROUTER_IP/ubus \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "call",
    "params": ["TOKEN", "luci.device-timer", "cancelcalibration", {"id": "tablet_kid"}]
  }'
```

**Response:**

```json
{
  "success": true,
  "id": "tablet_kid",
  "message": "Calibration cancelled"
}
```

**Errors:**
- `Missing device id`
- `Invalid device id`
- `No active calibration to cancel`

---

## Device Status Values

The `status` field in device responses indicates the current state:

| Status | Description |
|--------|-------------|
| `active` | Device is within its time window and has remaining usage time |
| `paused` | Device is temporarily blocked via pause API (overrides all other rules) |
| `blocked` | Usage limit for the current time window has been reached, device is blocked by firewall |
| `unlimited` | Flatrate mode is enabled or the schedule limit is set to `0` |
| `outside_window` | Device has schedules for today but none is currently active |
| `no_schedule` | No schedule is configured for today |
| `disabled` | Device monitoring is disabled (`enabled: 0`) |

## Schedule Format

Schedules follow the format `Day,HH:MM-HH:MM,Limit`:

| Part | Format | Example | Description |
|------|--------|---------|-------------|
| Day | `Mon`–`Sun` | `Mon` | Day of the week |
| Time window | `HH:MM-HH:MM` | `14:00-18:00` | Start and end time (24h format) |
| Limit | integer | `60` | Usage limit in minutes per time window, `0` for unlimited |

Overnight windows like `22:00-06:00` are supported. Multiple schedules per day are allowed as long as their time windows do not overlap.
