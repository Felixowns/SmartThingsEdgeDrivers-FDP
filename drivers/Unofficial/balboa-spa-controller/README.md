# Balboa Spa Controller (SmartThings Edge, Matter)

Edge driver for the ESP32-C6 Matter bridge on the Balboa BP7's Wi-Fi module (RS485) port.

## What it shows in SmartThings

| Component | Capability | Matter source |
|---|---|---|
| Spa (main) | Water temp, heat setpoint, heating/idle* | Thermostat cluster (or Temperature Measurement for the reading) |
| Temperature range | Mode: Low / High (dropdown) | On/Off plug EP 10: on = High, off = Low. The setpoint slider follows the range's limits (Thermostat Min/MaxHeatSetpointLimit: High 80–104 °F, Low 50–99 °F) |
| Spa status | Mode (read-only): Heating, Heat waiting, Idle, Priming, Startup cycle, Settings reset, Initializing, Hold, Test mode, Unknown | Mode Select EP 11 |
| Circulation pump | Mode (read-only): Running / Off | Contact sensor EP 12 (true = running) |
| Filter cycle | Mode (read-only): Off, Filter 1, Filter 2, Filter 1 + 2 | Mode Select EP 14 |
| Heat mode | Mode: Ready / Rest / Ready in rest | Shown from Mode Select EP 13 (the spa's own heat mode). Set via Thermostat SystemMode (Heat = Ready, Off = Rest). Ready in rest is display-only |
| Pump 1 | Mode: Off / Low / High | Fan Control (FanMode 0/1/3) or Mode Select. A plain On/Off endpoint works too, as Off / High |
| Pump 2–4 | Switch | On/Off |
| Light | Switch | On/Off (the endpoint with a Light device type is chosen first) |
| Heater sensor A / B | Temperature (°F) | Temperature Sensor endpoints 8 / 9 (the panel's A/B temps) |

## Endpoint mapping

The driver finds the endpoints itself every time it starts and writes the result to the log:

```
[balboa] endpoint map: thermostat=1 pump1=2 pump2=3 ... | pump1 via fan | temp via thermostat
```

Automatic order: Thermostat first; then Fan Control or Mode Select becomes Pump 1; a light-type On/Off endpoint becomes Light; the remaining On/Off endpoints, from lowest number up, become Pump 2, Pump 3, Pump 4.
Heater sensors A and B are matched by endpoint number, because the firmware has three Temperature Sensor endpoints. The lowest one (2) only repeats the water temperature, so it's hidden; the next two (8, 9) become A and B.
While the spa's A/B temps are off (booting, priming), the firmware reports no value. The driver then sends nothing, so the heater tiles keep the last known reading (blank until the first one). They never show 0, so Routines aren't fooled.
Aux (speakers) and the ozonator aren't controllable from the spa, so the driver doesn't show them.
If the firmware orders them differently, open the device's **Settings** in the app and enter the endpoint number for each function (0 means automatic). The driver remaps as soon as you save.

## New endpoints after a firmware update

SmartThings only lists the endpoints that existed when the spa was paired. If 8 and 9 aren't in that list, the driver still talks to them directly (log: `heaterA not in the paired endpoint list, using firmware default EP 8`).

If the heater sensors don't appear after flashing the new firmware, SmartThings is still using the old endpoint list. Remove the spa in SmartThings, hold BOOT on the ESP32 for 5 s, then pair it again.

## Install

From the repo root:

```
smartthings edge:drivers:package drivers/Unofficial/balboa-spa-controller
smartthings edge:channels:assign          # pick your channel + this driver
smartthings edge:drivers:install          # pick your hub + this driver
smartthings edge:drivers:logcat           # pick this driver to watch the endpoint map
```

Then in the app, open the spa device, tap ⋮ then **Driver**, and choose **Balboa Spa Controller**.

### Fingerprint
Every Arduino-ESP32 Matter sketch shares the test VID/PID 0xFFF1 / 0x8000, so the driver doesn't match on it (it would also grab the Friedrich bridge). It matches the device-type mix instead: Thermostat (0x0301) + Fan (0x002B) + On/Off Light (0x0100).

\* Heating/idle comes only from the firmware: the Thermostat cluster's ThermostatRunningState (bit 0 = heating), or PIHeatingDemand if RunningState isn't implemented. The driver never guesses. Until the firmware reports one of them, the indicator stays blank.

Temperatures are reported in °F. The setpoint moves in 1 °F steps, limited to the min/max set in the device's Settings (default 80–104 °F).

## Read-only status tiles

Spa status, Circulation pump and Filter cycle use the standard Mode capability so they can have their own text lists without a custom capability. They look like dropdowns, but picking a value does nothing: the driver logs it and puts the tile back to the real value. Heat mode also shows Ready in rest (from EP 13), which can't be selected. Endpoints 11–14 were added after pairing, so the driver uses the fixed IDs (pin them in Settings if the firmware ever changes). The standard Operating state is limited to Heating / Idle; the other states are in Spa status.
