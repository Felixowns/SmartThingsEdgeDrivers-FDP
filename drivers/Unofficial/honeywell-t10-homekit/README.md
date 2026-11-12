# Honeywell T10 (HomeKit local)

A SmartThings Edge driver for **Honeywell Home / Resideo T10, T10+ Pro and T9** thermostats and their wireless room sensors.

The SmartThings hub pairs with the thermostat **directly over Apple HomeKit on your local network** and keeps an encrypted connection open to it. There is no Resideo cloud, no Apple device or Home hub, and no bridge computer. Changes show up in SmartThings within about a second, and control keeps working when your internet is down.

* Driver name: `Honeywell T10 (HomeKit local)` (package key `honeywell-t10-homekit`)
* Tested: two T10+ Pro thermostats (HomeKit model "T9/T10 (+)", firmware 3.3.8) with six RedLINK 3.0 room sensors (C7189R3002)
* T9 support is built in but has not been tested on a real T9

Based on [Honeywell T6 (HomeKit local)](https://github.com/Stoeckie/smartthings-honeywell-t6-homekit-local) by Stoeckie (Apache 2.0), whose pure-Lua HomeKit controller made this possible. See [Credits and license](#credits-and-license).

---

## Contents

1. [What you get](#what-you-get)
2. [Requirements](#requirements)
3. [Install](#install)
4. [Pair the thermostat](#pair-the-thermostat)
5. [Devices and what they show](#devices-and-what-they-show)
6. [Settings](#settings)
7. [How it works](#how-it-works)
8. [Limitations](#limitations)
9. [Troubleshooting](#troubleshooting)
10. [Developer notes](#developer-notes)
11. [Credits and license](#credits-and-license)

---

## What you get

**Thermostat device**

| Feature | Notes |
|---|---|
| Temperature | indoor temperature at the thermostat |
| Humidity | indoor humidity at the thermostat |
| Operating state | what the system is doing right now: idle, heating or cooling |
| Mode | off, heat, cool, auto (the modes the thermostat reports as valid) |
| Heating setpoint | in heat mode, the thermostat's target temperature; in auto, the heat-to temperature |
| Cooling setpoint | in cool mode, the thermostat's target temperature; in auto, the cool-to temperature |
| Humidity target | the thermostat's humidity setpoint, for a humidifier or dehumidifier, as a 0–100 % control |
| Filter 1 / Filter 2 | Normal or Replace, each with a button to reset the reminder after a filter change |
| Refresh | re-reads everything from the thermostat |

**Room sensor devices** (one per sensor, created automatically)

| Feature | Notes |
|---|---|
| Temperature | room temperature |
| Humidity | room humidity |
| Motion | live motion at the sensor |
| Battery | 100 % when the battery is fine, 10 % when it is low (see [Limitations](#limitations)) |

**Also**

* Live push updates from the thermostat, with automatic reconnect
* Temperature and humidity recorded every 5 minutes (adjustable) even when they don't change, so SmartThings history and graphs have regular data points
* °F or °C display
* Multiple thermostats: each one is its own device with its own sensors

---

## Requirements

* A SmartThings hub that runs Edge drivers
* The thermostat and the hub on the **same network and subnet** (HomeKit is found with mDNS/Bonjour)
* The thermostat must **not** be paired with Apple Home. HomeKit allows one owner, so this driver and Apple Home can't both control the same thermostat. If it's in Apple Home now, remove it there first, or reset HomeKit on the thermostat.
* Using the Resideo app or Resideo cloud at the same time is fine. This driver only uses HomeKit.

---

## Install

**From the driver channel (recommended)**

1. Open the channel invite: https://callaway.smartthings.com/channels/2a034761-9a9f-456c-bb58-f65efb66c12a
2. Sign in with your Samsung account, accept the invitation and enroll your hub.
3. Under **Available drivers**, install **Honeywell T10 (HomeKit local)**.

**From source**

```
git clone https://github.com/Felixowns/SmartThingsEdgeDrivers-FDP.git
cd SmartThingsEdgeDrivers-FDP
smartthings edge:drivers:package drivers/Unofficial/honeywell-t10-homekit --channel <channelId> --hub <hubId>
```

Passing `--channel` and `--hub` uploads the driver, assigns it to your channel and installs it on the hub in one step. Without them the hub installs the new version on its own schedule, which can take hours.

---

## Pair the thermostat

1. On the thermostat, open **Menu > Connect HomeKit**. It shows a QR code and an 8-digit setup code. Leave that screen open.
2. In the SmartThings app: **+ > Add device > Scan nearby**. A device called **Honeywell T10** appears for each thermostat found. Rename it if you like (for example "First Floor").
3. Open the new device, then **⋮ > Settings > HomeKit code**, and type the 8 digits (with or without dashes).
4. Wait 1 to 2 minutes. Pairing does heavy cryptography in Lua on the hub, so it is slow; that's normal.
5. When pairing finishes, the thermostat device goes online and one device per room sensor is created automatically, named after the sensor.

For more than one thermostat, repeat steps 1, 3 and 4 for each device.

If you type the code before pairing starts, it is used right away. If pairing is already waiting, the hub waits up to 5 minutes for the code. After 5 failed attempts in a row it stops trying until you enter a code again.

---

## Devices and what they show

### Thermostat

The device page lists, in this order: temperature, humidity, operating state, mode, heating setpoint, cooling setpoint, refresh. Below them are three extra sections:

* **Humidity target:** a 0–100 % control for the thermostat's humidity setpoint. It uses SmartThings' standard level control, because SmartThings has no standard humidity setpoint capability, so the app draws it like a dimmer slider. Whether it is a humidify or dehumidify target depends on how your equipment is set up on the thermostat.
* **Filter 1 / Filter 2:** Normal or Replace. Press the section's button after changing a filter to reset the reminder; you can also reset it on the thermostat.

**Operating state** is the thermostat's own "what am I doing now" report: **idle**, **heating** or **cooling**. HomeKit does not report heat/cool stages or "pending" states.

### Room sensors

Each sensor is its own device (category temperature/humidity sensor), listing temperature, humidity, motion and battery. Their online state follows the thermostat's connection: if the hub loses the thermostat, its sensors go offline with it.

If you remove a sensor device, refresh its thermostat (or turn **Room sensor devices** off and on) to create it again. A recreated sensor is a new device, so routines that used the old one need to be pointed at the new one.

### Routines

Everything above works in routines: temperature, humidity, motion and battery as conditions; mode, setpoints and humidity target as actions; filter status as a condition (for example, notify when a filter needs replacing).

---

## Settings

On the thermostat device: **⋮ > Settings**.

| Setting | Default | What it does |
|---|---|---|
| HomeKit code | empty | The 8-digit code from Menu > Connect HomeKit. Only needed for pairing. |
| Temperature unit | Fahrenheit | °F or °C for everything SmartThings shows, including the room sensors. |
| Record interval (minutes) | 5 | Temperature and humidity of the thermostat and all its sensors are recorded at least this often, even when they don't change. 0 = record only on change. Range 0–120. |
| Room sensor devices | on | Create a SmartThings device for each room sensor. Turning it off doesn't delete existing sensor devices. |
| Thermostat IP (optional) | auto | Leave on `auto`; the thermostat is found with mDNS. Only set it if discovery fails. |
| HomeKit port (optional) | 0 | 0 = auto. Needed together with a fixed IP. |
| Remove pairing | off | Unpairs the hub from the thermostat, for example before pairing it with something else. |

---

## How it works

* **Pairing:** the hub acts as a HomeKit controller and runs HomeKit pair setup (SRP-3072 with your 8-digit code, then Ed25519 keys). The resulting keys are stored on the device in SmartThings, so pairing happens once.
* **Session:** after pairing, the hub connects to the thermostat, verifies the pairing (X25519), and keeps one encrypted (ChaCha20-Poly1305) session open. It subscribes to every value the thermostat offers for push updates.
* **Updates:** when a value changes, the thermostat pushes it and the driver passes it to SmartThings within about a second. Values that haven't changed are not resent, apart from the regular temperature/humidity data points (Record interval).
* **Safety net:** if nothing at all has arrived for 15 minutes, the driver reads all values directly. If the connection drops, it reconnects with a growing delay (3 s up to 5 min) and follows the thermostat to a new IP via mDNS. The device only shows offline after a reconnect attempt has failed.
* **Temperatures:** HomeKit always uses °C. Setpoints you set in °F are converted and rounded to the thermostat's step; temperatures are shown in your chosen unit.
* **Profile choice:** the driver reads what the thermostat exposes over HomeKit and picks the matching device layout (see [Developer notes](#developer-notes)).

---

## Limitations

These come from what the thermostat exposes over HomeKit, not from SmartThings:

* **No fan control.** The T10 does not expose its fan over HomeKit (firmware 3.3.8), so fan On / Auto / Circulate can't be controlled locally. The driver has fan support built in (Auto, On, and a hub-timed Circulate) and switches it on automatically if a future firmware exposes a fan.
* **No heat/cool stages, no "pending" states** in the operating state.
* **Battery is a low/OK flag**, not a percentage. The sensors only report "battery low" over HomeKit, so the driver shows 100 % (OK) or 10 % (low). A routine like "battery below 20 %" works as a low-battery alert.
* **No filter life percentage**, only Normal / Replace.
* **One humidity setpoint.** The T10 can have separate humidify and dehumidify setpoints; HomeKit exposes one.
* **The thermostat's own occupancy is not shown.** It is Honeywell's "room occupied" state, which stays on long after movement and looked like constant motion, so the driver leaves it out. Room sensor motion is live motion.
* **No Apple Home at the same time** (one HomeKit owner).

---

## Troubleshooting

**Watch the log**

```
smartthings edge:drivers:logcat <driverId> --hub-address <hub-ip>
```

Driver lines start with `[t10]`. A healthy start looks like:

```
[t10] Honeywell T10 (HomeKit local) driver starting, build 2026-11-10c
[t10] tree aid 2: 3E{...} 4A{F#35=0 33#36=3 11#37=21 35#38=22 ...} BA{...} BA{...} 86{...}
[t10] Resideo Technologies, Inc. T9/T10 (+) (fw 3.3.8), modes off/heat/cool/auto, fan none, 3 room sensor(s)
[t10] session up
```

| Problem | What to do |
|---|---|
| Thermostat not found by Scan nearby | Hub and thermostat must be on the same subnet (no VLAN or guest-network split). A "Honeywell T10" device is created anyway; set **Thermostat IP** and **HomeKit port** by hand (the port is in the thermostat's `_hap._tcp` mDNS record, visible in any Bonjour browser app). |
| `HomeKit error 2` | Wrong code. Check the code on Menu > Connect HomeKit and enter it again. |
| `HomeKit error 6` (or 5) | The thermostat is already paired (Apple Home) or locked after too many tries. Remove it from Apple Home or reset HomeKit on the thermostat, wait a few minutes, then enter the code again. |
| `pairing failed 5 times` | Automatic retries stopped. Clear the **HomeKit code** setting and type the code again to retry. |
| `unknown accessory id` / `authentication` | The thermostat no longer knows the hub (HomeKit was reset). Switch **Remove pairing** on, then off. Open Menu > Connect HomeKit on the thermostat, clear the **HomeKit code** setting and type the code again (pairing starts when the code changes). |
| Thermostat offline | The hub can't reach the thermostat: check its Wi-Fi and IP. Give it a DHCP reservation in your router; the driver also follows a new IP via mDNS. |
| Room sensors offline, thermostat online | Make sure the hub runs build 2026-11-10c or later. Then refresh the thermostat. |
| Room sensor missing | Refresh the thermostat, or turn **Room sensor devices** off and on. |
| New icon/category not showing on old devices | The app keeps what it chose when the device was created. Change the icon under ⋮ > Edit, or remove the device and let it be recreated. |
| Driver doesn't restart after an update | `package` without `--channel`/`--hub` only uploads. Check `smartthings edge:drivers:installed --hub <hubId>`, then install with `smartthings edge:drivers:install <driverId> --hub <hubId> --channel <channelId>`. |

---

## Developer notes

### Files

| File | Purpose |
|---|---|
| `config.yml` | driver name, package key, LAN and discovery permissions |
| `src/init.lua` | driver: discovery, pairing, session, events, commands, room sensor devices, record interval |
| `src/t10_model.lua` | maps the HomeKit accessory tree to SmartThings fields |
| `src/hap_client.lua` | HomeKit (HAP) controller: pair setup, pair verify, encrypted session, get/put/subscribe |
| `src/srp.lua`, `bignum.lua`, `curve25519.lua`, `chacha20poly1305.lua`, `sha512.lua`, `tlv8.lua`, `rng.lua` | crypto and encoding for HomeKit |
| `src/emitq.lua` | sends only changed values to the hub; `record()` adds the regular data points |
| `profiles/*.yml` | device profiles (below) |
| `LICENSE`, `NOTICE` | Apache 2.0 license and attribution; keep both with the code |

### Profiles

The driver picks the thermostat profile from what it finds over HomeKit (T9 and T10 report the same model name):

| Profile | Chosen when | Extra sections |
|---|---|---|
| `honeywell-t10` | humidity target exposed (T10 / T10+ Pro) | Humidity target, Filter 1, Filter 2 |
| `honeywell-t10-fan` | a fan service is exposed | as above, plus fan mode and a *Circulate minutes per hour* setting |
| `honeywell-t9-filter` | no humidity target, filter reminder exposed (T9) | Filter |
| `honeywell-t9` | no humidity target, no filter | none |

Room sensor profiles, by what each sensor exposes:

| Profile | Capabilities | Category |
|---|---|---|
| `honeywell-t10-sensor-hmb` | temperature, humidity, motion, battery | TempHumiditySensor |
| `honeywell-t10-sensor-hm` | temperature, humidity, motion | TempHumiditySensor |
| `honeywell-t10-sensor-h` | temperature, humidity | TempHumiditySensor |
| `honeywell-t10-sensor` | temperature | TempSensor |

### HomeKit mapping

Short HomeKit type codes, as printed in the `[t10] tree` log lines (`type#iid=value`):

| HomeKit | Code | SmartThings |
|---|---|---|
| Thermostat service | `4A` | thermostat device |
| Current Heating Cooling State | `F` | thermostatOperatingState (0 idle, 1 heating, 2 cooling) |
| Target Heating Cooling State | `33` | thermostatMode (0 off, 1 heat, 2 cool, 3 auto) |
| Current Temperature | `11` | temperatureMeasurement |
| Target Temperature | `35` | heating setpoint in heat mode, cooling setpoint in cool mode |
| Heating / Cooling Threshold | `12` / `D` | heating / cooling setpoint in auto mode |
| Current Relative Humidity | `10` | relativeHumidityMeasurement |
| Target Relative Humidity | `34` | switchLevel on component `humidityTarget` |
| Filter Maintenance | `BA` | filterStatus (`AC` change indication) + momentary reset (`AD`) on `filter1`, `filter2` |
| Fan v2 / Fan | `B7` / `40` | thermostatFanMode (not exposed by T10 firmware 3.3.8) |
| Temperature / Humidity sensor | `8A` / `82` | room sensor temperature / humidity |
| Motion sensor | `85` | room sensor motionSensor |
| Battery | `96` | room sensor battery (`68` level, `79` low flag) |
| Occupancy sensor (thermostat) | `86` | ignored on purpose (see Limitations) |

Every other accessory behind the thermostat that has sensor services becomes one room sensor device.

### Adding a model

On every driver start, the log prints the full HomeKit tree once (`[t10] tree aid N: ...`). For a thermostat model that maps wrongly, those lines show exactly which services and values it exposes.

---

## Credits and license

* HomeKit controller and crypto (`hap_client.lua`, `srp.lua`, `bignum.lua`, `curve25519.lua`, `chacha20poly1305.lua`, `sha512.lua`, `tlv8.lua`, `rng.lua`, `emitq.lua`) by **Stoeckie**, from [smartthings-honeywell-t6-homekit-local](https://github.com/Stoeckie/smartthings-honeywell-t6-homekit-local), Apache 2.0. `emitq.lua` gained a `record()` function; the rest is unchanged.
* `init.lua` and `t10_model.lua` adapted from that project for the T10: cooling and auto thresholds, °F, humidity target, filters, room sensors as their own devices, regular data points, T9 profiles, optional fan with Circulate.

Licensed under the Apache License 2.0, see `LICENSE` and `NOTICE`.

Not affiliated with, endorsed by or supported by Honeywell, Resideo, Apple or Samsung. Honeywell Home, Resideo, HomeKit and SmartThings are trademarks of their owners. Use at your own risk.
