# Tesla Wall Connector — SmartThings Edge Driver

Local monitoring of a **Tesla Gen 3 Wall Connector** from SmartThings, using the Wall Connector's built-in local HTTP API.

Everything runs on your SmartThings hub and reads the Wall Connector directly over your home network. There is no Tesla account, no Tesla cloud, no SmartThings linked service, and no extra bridge, so it keeps working when your internet is down.

---

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Setup](#setup)
- [Device and capabilities](#device-and-capabilities)
- [Settings](#settings)
- [How it works](#how-it-works)
- [SmartThings Energy](#smartthings-energy)
- [Automation examples](#automation-examples)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [Wall Connector API coverage](#wall-connector-api-coverage)
- [File layout](#file-layout)
- [Credits and references](#credits-and-references)

---

## Features

- **100% local**: the hub reads the Wall Connector over HTTP on your LAN.
- **Automatic discovery**: scans the hub's subnet and identifies Wall Connectors by serial number. A manual IP can be entered as a fallback.
- **Charging state** using SmartThings' native EV charger capability (`evseState`): *Not plugged in*, *Plugged in*, *Plugged in – demand*, *Charging*, and *Fault*.
- **Live power** in watts, including 3-phase installs.
- **Lifetime energy** (kWh) as a running total, plus **SmartThings Energy** reporting.
- **Current session energy** (kWh) in its own component.
- **Grid voltage**.
- **Three temperatures**: main circuit board, charging handle, and internal processor.
- **Self-healing**: if the Wall Connector gets a new IP address, the driver finds it again by serial number.
- **Stable online/offline**: the device goes offline only after several failed polls in a row, so a single dropped Wi‑Fi packet doesn't make it flap.
- Events are sent only when a value changes, so your history and routines aren't flooded.

---

## Requirements

| Item | Requirement |
|---|---|
| SmartThings hub | Any hub that runs Edge drivers (v2, v3, Aeotec, Station, or a hub built into a TV or appliance) |
| Charger | **Tesla Gen 3 Wall Connector** (the Wi‑Fi model). Gen 1 and Gen 2 have no local API. Other Tesla chargers with the same API may work but are untested |
| Network | Wall Connector connected to your home Wi‑Fi (set up through the Tesla One app) |
| Subnet | Auto-discovery scans the hub's own /24 subnet (for example 192.168.1.1–254). If the charger is on another subnet or VLAN, enter its IP manually and make sure the hub can reach it on port 80 |

No Tesla account, token or API key is needed. The local API is read-only and needs no login.

---

## Installation

### From the channel

1. Open the channel invite link and sign in with your Samsung account:
   **https://bestow-regional.api.smartthings.com/invite/r3MyN0639J2p**
2. Enroll your hub, open **Available Drivers**, and install **Tesla Wall Connector**.

### From source (SmartThings CLI)

```bash
smartthings edge:drivers:package drivers/Unofficial/tesla-wall-connector
smartthings edge:channels:assign        # pick your channel and the driver
smartthings edge:drivers:install        # pick your hub
```

The hub can take a few minutes to pick up a new version. To confirm what is installed, run `smartthings edge:drivers:installed` and compare the version timestamp.

---

## Setup

### 1. Make sure the Wall Connector is on Wi‑Fi

In the **Tesla One** app, check that the Wall Connector is connected to your home network. You can confirm it's reachable by opening `http://<wall-connector-ip>/api/1/vitals` in a browser on the same network. You should see a page of JSON values.

### 2. Add the device

1. In the SmartThings app: **+ → Add device → Scan for nearby devices**.
2. The driver scans every address on the hub's subnet (this takes about 15–20 seconds). Anything that answers `/api/1/version` with a Wall Connector serial and part number is added as **Tesla Wall Connector**.
3. Readings appear within a few seconds.

### 3. If it isn't found

Discovery only covers the hub's own subnet. If your charger is on another VLAN, or the scan misses it:

1. Find the Wall Connector's IP in your router or the Tesla One app.
2. Run the scan once more if no device was created, or open an existing device → **⋮ → Settings**.
3. Enter the IP in **Wall Connector IP Address**.

> **Tip:** give the Wall Connector a DHCP reservation in your router. The driver re-finds it by serial number if the IP changes, but a fixed address is faster and more reliable.

---

## Device and capabilities

One SmartThings device is created per Wall Connector. It shows in the app with the EV charger icon.

| Component | Capability | What it shows |
|---|---|---|
| main | **EVSE State** | *Not plugged in*, *Plugged in – no demand*, *Plugged in – demand* (power enabled, car not drawing), *Charging*, or *Fault*. Also supply state (enabled / disabled / error) and fault state |
| main | **Power Meter** | Power the car is drawing, in W |
| main | **Energy Meter** | **Lifetime** energy delivered, in kWh. Only goes up |
| main | **Power Consumption Report** | 15-minute energy reports for SmartThings Energy |
| main | **Voltage Measurement** | Grid voltage, in V |
| main | **Temperature Measurement** | Main circuit board temperature |
| main | **Refresh** | Reads the Wall Connector now |
| Current Session | **Energy Meter** | Energy delivered in the **current/last charging session**, in kWh. Resets when a new session starts |
| Charging Handle | **Temperature Measurement** | Temperature in the charging handle |
| Internal Processor | **Temperature Measurement** | MCU temperature |

### How charging state is decided

| Wall Connector reports | SmartThings shows |
|---|---|
| `evse_state` = 7 (error) | **Fault**, supply *Disabled (error)* |
| `vehicle_connected` = false | **Not plugged in** |
| Connected, contactor closed, current ≥ 1 A | **Charging** |
| Connected, contactor closed, current < 1 A | **Plugged in – demand** |
| Connected, contactor open | **Plugged in – no demand** |

Supply state is *Charging enabled* when the contactor is closed and *Disabled* when it's open.

---

## Settings

| Setting | Default | Description |
|---|---|---|
| Wall Connector IP Address | `192.168.1.xxx` | **Optional.** Leave the placeholder to use the auto-discovered IP. Enter a real IP to pin it. A pinned IP also turns off automatic re-discovery |
| Polling Interval (Seconds) | 30 | How often the driver reads the Wall Connector (15–300) |

Changing the IP polls right away. Changing the interval restarts the polling timer.

---

## How it works

```
 SmartThings app / routines / SmartThings Energy
            │
            ▼
   SmartThings hub (Edge driver: tesla-wall-connector)
     │  HTTP GET /api/1/vitals     (every poll)
     │  HTTP GET /api/1/lifetime   (every poll)
     │  HTTP GET /api/1/version    (discovery, and once to learn the serial)
     ▼
   Tesla Gen 3 Wall Connector  (Wi‑Fi, port 80)
```

- **Polling**: every *Polling Interval* the driver reads `vitals` (live values) and `lifetime` (totals). Each request has a 5-second timeout.
- **Discovery**: the driver works out the hub's /24 subnet and probes `http://<ip>/api/1/version` on all 254 addresses, 16 at a time, with a 1-second timeout. A reply with both `serial_number` and `part_number` is a Wall Connector. The serial becomes the SmartThings network ID (`tesla_wc_<serial>`), so the same charger is never added twice. Chargers you already have are skipped, and the scan stops when you leave the *Scan nearby* screen.
- **Failure handling**: after 3 failed polls in a row, the device is marked offline. After 5, the driver re-scans the subnet for the charger's serial number (unless you pinned an IP) and switches to the new address if it finds it. Re-scans run at most once every 15 minutes.
- **Startup**: when the hub or driver restarts, the driver polls right away instead of assuming the device is online.
- **Power**: grid voltage × vehicle current. On 3-phase installs (current reported on phase C) it adds up voltage × current for each phase.
- **Events**: values are rounded (power to whole watts, temperatures and voltage to 0.1, energy to 0.001 kWh) and sent only when they change.

---

## SmartThings Energy

The main **Energy Meter** shows the Wall Connector's **lifetime** energy counter, so it only goes up. This is what SmartThings expects from an energy meter. Every 15 minutes the driver also sends a **Power Consumption Report** with the energy used since the previous report, which feeds the SmartThings Energy graphs.

The first reading after you add the device only sets a starting point. The first Energy report arrives about 15 minutes later.

Per-session energy is kept separately in the **Current Session** component, so its reset at each new session doesn't affect the totals.

---

## Automation examples

- **Charging started**: *If* EVSE state is **Charging** → notify me.
- **Charging finished**: *If* EVSE state changes from **Charging** to **Plugged in – no demand** → notify me ("Car is done charging").
- **Forgot to plug in**: *If* EVSE state is **Not plugged in** *and* time is 10:00 PM *and* the car is home → remind me to plug in.
- **High load**: *If* power is above 7,000 W *and* the dryer is running → notify me, or turn off another load.
- **Hot handle**: *If* Charging Handle temperature is above 60 °C → notify me.
- **Fault alert**: *If* EVSE state is **Fault** → notify me.

---

## Troubleshooting

Run the live log while you test:

```bash
smartthings edge:drivers:logcat     # pick "Tesla Wall Connector"
```

Poll details are logged at debug level. Warnings and errors show by default.

| Symptom / log line | Cause | Fix |
|---|---|---|
| Scan finds nothing | The charger is on another subnet/VLAN, or isn't on Wi‑Fi | Check `http://<ip>/api/1/vitals` in a browser, then enter the IP in Settings |
| `Could not determine hub IPv4 address; falling back to 192.168.1.x` | The hub hadn't reported its IP yet when the scan started | Wait a minute and scan again, or enter the IP manually |
| `No IP configured or discovered; skipping poll` | Device has no address | Enter the IP in Settings |
| `Poll failed (N in a row): HTTP nil` | The hub can't reach the charger (timeout or refused) | Check the IP, Wi‑Fi signal at the charger, and that hub and charger share a subnet |
| `Poll failed … JSON parse error` | Something other than a Wall Connector answered at that IP | The IP is wrong (possibly reassigned). Fix it in Settings, or reset it to the placeholder to use discovery |
| `Unreachable; searching subnet for serial …` | Normal after 5 failures | Wait for `Wall Connector moved to <ip>`. If you see `Rescan did not find serial`, the charger is off or off the network |
| `Active alerts: …` | The Wall Connector is reporting alerts | Check the Tesla One app for details |
| Device keeps showing an old IP | A manual IP is pinned | Set the IP setting back to `192.168.1.xxx` to use discovery |
| Energy graph is empty | First 15 minutes after adding | Wait for the first report |
| New driver version not running | The hub hasn't updated yet | `smartthings edge:drivers:installed` to check the version; reinstall, and restart logcat |

---

## Limitations

- **Read-only.** The Wall Connector's local API has no commands, so the driver can't start or stop charging or change the current limit. To control charging, use the car (Tesla app / Fleet API) instead.
- **Undocumented API.** Tesla hasn't published the local API. Field names are based on what the Gen 3 firmware returns and could change with a firmware update.
- **The *Fault* state is based on `evse_state = 7`**, a commonly reported value for an error. Other codes are mapped from the plugged-in / contactor / current fields instead.
- **No HTTPS or login.** The API is plain HTTP on your LAN. Anyone on your network can read it, as they can with the Tesla app's local status.
- **Discovery covers one /24 subnet.** Larger or routed networks need a manual IP.
- **Single-unit tested.** Power-sharing setups with several Wall Connectors should work (each is its own device) but are untested.

---

## Wall Connector API coverage

All requests are `GET http://<ip>/api/1/<endpoint>` with no authentication.

| Endpoint | Fields used | Used for |
|---|---|---|
| `vitals` | `grid_v`, `vehicle_current_a`, `currentA/B/C_a`, `voltageA/B/C_v`, `vehicle_connected`, `contactor_closed`, `evse_state`, `session_energy_wh`, `pcba_temp_c`, `handle_temp_c`, `mcu_temp_c`, `current_alerts` | Every poll |
| `lifetime` | `energy_wh` | Lifetime Energy Meter and Energy reports |
| `version` | `serial_number`, `part_number` | Discovery and identifying the charger after an IP change |

Example `vitals` reply (trimmed):

```json
{"contactor_closed":true,"vehicle_connected":true,"session_s":3725,
 "grid_v":242.1,"grid_hz":59.98,"vehicle_current_a":31.9,
 "currentA_a":31.8,"currentB_a":31.9,"currentC_a":0.0,
 "pcba_temp_c":38.4,"handle_temp_c":29.1,"mcu_temp_c":44.6,
 "session_energy_wh":7684.2,"evse_state":11,"current_alerts":[]}
```

---

## File layout

```
tesla-wall-connector/
├── config.yml                      # driver name, packageKey, permissions (lan, discovery)
├── profiles/
│   └── tesla-wall-connector.yaml   # main (EVSE state, power, energy, voltage, temp, refresh),
│                                   # Current Session, Charging Handle, Internal Processor + settings
└── src/
    └── init.lua                    # discovery, polling, event mapping, re-discovery, lifecycle
```

---

## Credits and references

- The Home Assistant `tesla_wall_connector` integration and the `tesla-wall-connector` Python library were useful references for the local API's endpoints and fields.
- SmartThings' own Matter EVSE driver (`drivers/SmartThings/matter-energy`) for the `evseState` capability and Energy reporting pattern.

Tesla and Wall Connector are trademarks of Tesla, Inc. This is an unofficial community driver, not affiliated with or supported by Tesla or Samsung SmartThings. Use at your own risk.
