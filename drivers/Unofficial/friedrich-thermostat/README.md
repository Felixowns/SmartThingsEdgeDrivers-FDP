# Friedrich Thermostat (SmartThings Edge, Matter)

Edge driver for the ESP32-C6 Matter bridge (`FriedrichMatter` sketch) on the RS485 bus between the Friedrich/Verdant wall thermostat and the Friedrich VRP.

## What it shows in SmartThings

| Component | Capability | Matter source |
|---|---|---|
| Thermostat (main) | Room temperature | Thermostat LocalTemperature |
| | Mode: Off / Cool / Heat | Thermostat SystemMode 0 / 3 / 4 |
| | Heat and cool setpoints | OccupiedHeatingSetpoint / OccupiedCoolingSetpoint |
| | Heating / Cooling / Fan only / Idle | ThermostatRunningState |
| | Humidity | Relative Humidity Measurement (RS485 CMD 0B) |
| | Thermostat fan mode: On / Auto | "Fan constant" On/Off switch (on = fan always runs, off = only with heat/cool). The switch itself isn't shown |
| | Fan speed: Low / High | Fan Control FanMode 1 / 3 |
| ESP32 control | Switch | On/Off endpoint. On = the ESP32 runs the unit (wall presses ignored), Off = wall-thermostat pass-through |

Changing mode, a setpoint or the fan from SmartThings makes the firmware take over, so the ESP32 control switch turns on by itself.

## Endpoint mapping

The driver finds the endpoints every time it starts and logs the result:

```
[friedrich] endpoint map: thermostat=1 fan=2 humidity=3 temperature=4 control=5 fanconstant=6
```

That is the order the sketch creates them in (Thermostat, Fan, Humidity Sensor, Temperature Sensor, ESP32 control, Fan constant). The Temperature Sensor endpoint is ignored because it starts at a 70 °F placeholder; room temperature comes from the thermostat.

The Fan endpoint also has an On/Off cluster; the driver ignores it and uses the next two On/Off endpoints as ESP32 control and Fan constant, in that order. With older firmware that has no Fan constant switch, On/Auto still works, but picking a speed turns the fan to constant. If the mapping is wrong, enter endpoint numbers in the device **Settings** (0 = automatic). The driver remaps when you save.

Settings also hold the setpoint limits in °F (heat 60–86, cool 61–86 by default). The firmware itself only accepts 60–86 °F, and Matter won't take a cool setpoint below about 61 °F. Values from the app are clamped to these.

## Install

From the repo root:

```
smartthings edge:drivers:package drivers/Unofficial/friedrich-thermostat
smartthings edge:channels:assign          # pick your channel + this driver
smartthings edge:drivers:install          # pick your hub + this driver
smartthings edge:drivers:logcat           # pick this driver to watch the endpoint map
```

Then commission the ESP32 (or, if it's already paired), open the device, tap ⋮ then **Driver**, and choose **Friedrich Thermostat**.

### Fingerprint

The Arduino ESP32 Matter library gives every sketch the same test VID/PID (0xFFF1 / 0x8000), which the Balboa driver already matches. So this driver matches by device types instead: Thermostat (0x0301) + Fan (0x002B) + Humidity Sensor (0x0307), with a Thermostat + Fan fallback. If the hub still picks the Balboa driver, switch it with ⋮ → **Driver**.

## Troubleshooting

- **A setpoint snaps back:** the firmware clamps both setpoints to 60–86 °F. Auto mode is disabled in the sketch, so there is no heat/cool deadband.
- **Operating state never changes:** the firmware isn't reporting ThermostatRunningState. Check that it's enabled in the sketch.
- **No humidity:** CMD 0B is only *likely* humidity (it hasn't been confirmed), and the thermostat sends it every ~20 s, so give it a minute after boot.
