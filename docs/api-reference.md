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
| [`reset`](#reset) | WRITE | Reset daily usage counter for a device |
| [`setflatrate`](#setflatrate) | WRITE | Enable or disable flatrate mode |
| [`startcalibration`](#startcalibration) | WRITE | Start traffic threshold calibration |
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
      "flatrate_active": 0
    }
  ]
}
```

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
  "flatrate_active": 0
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

Get the current calibration status and results for a device.

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
  "elapsed": 0,
  "duration": 0,
  "sample_count": 0,
  "progress_percent": 0
}
```

**Response (running):**

```json
{
  "id": "tablet_kid",
  "status": "running",
  "elapsed": 450,
  "duration": 1800,
  "sample_interval": 10,
  "sample_count": 45,
  "progress_percent": 25,
  "result_p90": 0,
  "result_recommended": 0,
  "error_message": ""
}
```

**Response (completed):**

```json
{
  "id": "tablet_kid",
  "status": "completed",
  "elapsed": 1800,
  "duration": 1800,
  "sample_interval": 10,
  "sample_count": 180,
  "progress_percent": 100,
  "result_p90": 5242880,
  "result_recommended": 6291456,
  "error_message": ""
}
```

| Field | Type | Description |
|-------|------|-------------|
| `status` | string | `idle`, `running`, `completed`, or `error` |
| `elapsed` | int | Seconds elapsed since calibration start |
| `duration` | int | Total calibration duration in seconds |
| `sample_interval` | int | Seconds between traffic samples |
| `sample_count` | int | Number of traffic samples collected |
| `progress_percent` | int | Completion percentage (0–100) |
| `result_p90` | int | 90th percentile traffic value in bytes |
| `result_recommended` | int | Recommended threshold in bytes |
| `error_message` | string | Error description if status is `error` |

**Errors:**
- `Missing device id`
- `Invalid device id`

---

### reset

Reset the daily usage counter for a device. The counter is set to zero and firewall rules are updated on the next daemon poll cycle.

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

Enable or disable flatrate mode for a device. When enabled, the device has unlimited access regardless of time limits.

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

### startcalibration

Start a traffic threshold calibration run. The daemon samples the device's traffic at regular intervals and calculates a recommended threshold based on the 90th percentile.

**Parameters:**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `id` | string | Yes | — | UCI section ID of the device |
| `duration` | int | No | `1800` | Calibration duration in seconds (300–3600) |
| `sample_interval` | int | No | `10` | Seconds between samples (5–30) |

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
      "duration": 1800,
      "sample_interval": 10
    }]
  }'
```

**Response:**

```json
{
  "success": true,
  "id": "tablet_kid",
  "duration": 1800,
  "sample_interval": 10,
  "message": "Calibration started"
}
```

**Errors:**
- `Missing device id`
- `Invalid device id`
- `Device not found`
- `Device must be enabled for calibration`
- Duration/interval validation errors (must be within allowed ranges)

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

Cancel a running calibration. Has no effect if no calibration is in progress.

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
- `No running calibration to cancel`

---

## Device Status Values

The `status` field in device responses indicates the current state:

| Status | Description |
|--------|-------------|
| `active` | Device is within its time window and has remaining usage time |
| `blocked` | Daily usage limit has been reached, device is blocked by firewall |
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
| Limit | integer | `60` | Daily limit in minutes, `0` for unlimited |

Overnight windows like `22:00-06:00` are supported. Multiple schedules per day are allowed as long as their time windows do not overlap.
