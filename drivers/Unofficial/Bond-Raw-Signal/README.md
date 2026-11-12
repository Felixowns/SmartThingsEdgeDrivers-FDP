# Bond-Raw-Signal — SmartThings Edge driver for Bond Bridge

Local (LAN) control of a **Bond Bridge / Bond Bridge Pro** from SmartThings. No Bond cloud and no SmartThings linked service are involved: the SmartThings hub talks straight to the Bridge over your home network using the Bond Local API.

The driver reads everything you've set up in the Bond app (fans, shades, lights, fireplaces and anything else) and creates a matching SmartThings device for each one. Each device can then run in one of two ways:

- **Bond configuration**: SmartThings asks the Bridge to run its own actions (TurnOn, SetSpeed, Open, SetPosition…) and reads state back from the Bridge. This is how most people will use it.
- **Custom (raw signals)**: the driver takes the raw RF codes the Bridge learned from your remote and transmits them itself (`PUT /v2/signal/tx`). This unlocks things Bond can't do on its own: burst-counted positioning for hold-to-run motors (pergola louvers, awnings), fan speed remapping, momentary one-button triggers, and multi-press devices like the Shark misting fan.

You can switch any device between the two at any time in its settings.

---

## Contents
1. [Features](#features)
2. [Requirements](#requirements)
3. [Installation](#installation)
4. [Setup](#setup)
5. [Device types](#device-types)
   - [Ceiling fans](#ceiling-fans)
   - [Fan light device](#fan-light-device)
   - [Shades, pergolas and awnings](#shades-pergolas-and-awnings)
   - [Lights and single-button devices](#lights-and-single-button-devices)
   - [Shark misting fan](#shark-misting-fan)
   - [Fireplaces and other devices](#fireplaces-and-other-devices)
6. [Bond vs Custom behavior](#bond-vs-custom-behavior)
7. [Correcting tracked state ("Fix" settings)](#correcting-tracked-state-fix-settings)
8. [Adding or changing devices later](#adding-or-changing-devices-later)
9. [Troubleshooting](#troubleshooting)
10. [Limitations](#limitations)
11. [How it works](#how-it-works)
12. [Files](#files)

---

## Features
- Automatic discovery of Bond Bridges on your network (mDNS `_bond._tcp`), with manual IP entry as a fallback
- Automatic local-token pickup after a Bridge power cycle, or manual token entry
- One SmartThings device per Bond device, created automatically
- **Ceiling fans**: on/off, 4-step speed control with optional mapping to the fan's real speeds, light on/off, light dimmer button, **Winter mode (reverse direction)** on the fan device itself, Breeze button
- **Separate "<Fan> Light" device** for each fan with a light, so it gets its own tile and shows up as its own light in Alexa / Google
- **Shades / pergolas**: open, close, pause and a position slider. Custom mode positions hold-to-run motors by counting RF bursts, with tunable burst counts, end-stop overrun and burst spacing
- **Lights / single buttons**: normal light switch, or a momentary trigger with a self-resetting switch for voice assistants
- **Shark misting fan** layout: power, speed 1–5, Boost, Mist, Swing and Breeze, each reached by counting button presses
- **Fix-state settings** to resync SmartThings with the real device without sending anything
- Everything runs locally on the SmartThings hub

## Requirements
- A SmartThings hub that runs Edge drivers (v2 / v3 / Aeotec / Station)
- A Bond Bridge or Bond Bridge Pro on **firmware v2 or later** (Local API v2)
- The hub and the Bridge on the **same local network/subnet**
- Your devices already set up in the **Bond app**
- For Custom mode: devices whose remote buttons were **learned** in the Bond app (devices made from a Bond template have no stored raw signals)

A fixed IP for the Bridge (DHCP reservation in your router) is recommended but not required.

## Installation

### From the driver channel
1. Open the channel invite: **https://callaway.smartthings.com/channels/2a034761-9a9f-456c-bb58-f65efb66c12a**
2. Sign in, accept the invitation, and choose **Available Drivers**.
3. Install **Bond-Raw-Signal** to your hub.

### From source (SmartThings CLI)
```
smartthings edge:drivers:package drivers/Unofficial/Bond-Raw-Signal
smartthings edge:channels:assign
smartthings edge:drivers:install
```
Live logs while testing:
```
smartthings edge:drivers:logcat
```

## Setup

### 1. Add the Bond Bridge
SmartThings app → **+** → **Add device** → **Scan for nearby devices**.

The driver searches for Bond Bridges and creates a **Bond Bridge <ID>** device for each one it finds. If none is found (or your hub firmware has no mDNS support), it creates one blank **Bond Bridge** device instead. Open its settings and enter the Bridge's IP address.

### 2. Give the driver the local token
Pick one:

- **Automatic (recommended)**: unplug the Bridge, plug it back in, and **within 10 minutes** press **Refresh** on the Bond Bridge device. For about 10 minutes after it boots, the Bridge hands out its token, and the driver reads and saves it. *Read token automatically* must be on (the default).
- **Manual**: copy the Local Token from the Bond app (the Bridge's settings, under Advanced) into **Local token (manual)** on the Bond Bridge device.

### 3. Your devices appear
Once the token works, the driver reads every Bond device (type, properties, commands and learned raw signals) and creates a SmartThings device for each one. Fans with a light also get a second **"<Fan> Light"** device.

### Bond Bridge settings
| Setting | Default | What it does |
|---|---|---|
| Bond Bridge IP address | blank | Leave blank to use the address found by discovery. Fill it in to pin a fixed IP. |
| Local token (manual) | blank | Token from the Bond app. Leave blank to use the automatic token. |
| Read token automatically | On | Read the token from the Bridge in the 10 minutes after a power cycle. |

Changing any of these makes the driver reconnect and re-read the Bridge.

---

## Device types

The Bond device type decides which SmartThings device you get:

| Bond type | SmartThings device |
|---|---|
| `CF` Ceiling fan | Fan (plus "<Fan> Light" if it has a light) |
| `MS` Motorized shade | Shade / blind |
| `LT` Light | Light (Bond) or momentary trigger (Custom) |
| `FP` Fireplace, `GX` Generic, anything else | On/off switch |

### Ceiling fans

The fan's layout is built from what the Bond device supports:

| Bond device has | Extra control on the fan device |
|---|---|
| always | **Fan** (on/off + speed), **Light** on/off, **Light dimmer** button |
| `ToggleDirection` / `SetDirection` | **Winter mode (reverse)** switch |
| `BreezeOn` / `BreezeOff` / `SetBreeze` | **Breeze / random** button |

Direction lives on the fan device as a switch (Winter mode on = reverse), not as a separate device.

**Fan settings**
| Setting | Default | What it does |
|---|---|---|
| Device behavior | Bond configuration | Bond, Custom (raw signals), or Shark misting fan |
| Fan speed for step 1–4 | 0 (automatic) | SmartThings has 4 speed steps (Low / Medium / High / Max). Set the real fan speed each step should use, e.g. a 6-speed fan: 1, 3, 5, 6. With 0, steps are spread evenly across the fan's `max_speed`. |
| Fix light state | No change | Mark the light on/off without sending anything (see [Fix settings](#correcting-tracked-state-fix-settings)) |
| Fix winter mode state | No change | Same, for direction (only on fans that support it) |
| Dimmer press length (ms) | 3000 | How long the dimmer button is "held" per press |

**How each control behaves**
- **Speed**: Bond mode sends `SetSpeed`. Custom mode transmits the learned raw signal for that speed.
- **Power on**: Bond mode uses `TurnOn` or `TogglePower`. Custom mode resends the last speed.
- **Light / Winter mode**: uses the direct command when Bond has one (`TurnLightOn`, `SetDirection`). With toggle-only remotes, it only presses the toggle when the current state is different from what you asked for, so "turn light on" never turns it off.
- **Light dimmer**: holds the dimmer for the set press length (`StartDimmer`, then `Stop`, or repeated raw bursts in Custom).
- **Breeze**: sends `BreezeOn`.

### Fan light device
Each fan with a light also gets a **"<Fan> Light"** device. It controls the same light as the fan's Light switch and stays in sync with it. It exists so the light has its own tile and shows up in Alexa / Google as a normal light. It follows the parent fan's behavior and settings and has no settings of its own.

### Shades, pergolas and awnings

Controls: **Open**, **Close**, **Pause**, and a **position slider** (0% = closed, 100% = open).

**Bond configuration**
- Open/Close use the Bridge's `Open` / `Close`.
- The slider uses `SetPosition` when the Bridge supports it (e.g. a course time is set in the Bond app). Otherwise it opens for 50% and above and closes below.
- Pause sends `Hold` (or `Stop`).
- Position is read back from the Bridge. Bond reports % closed, and the driver flips it to % open.

**Custom (raw signals): burst-counted positioning**

Made for hold-to-run motors (like a pergola louver remote) where each RF burst moves the motor a small step and nothing reports position. The driver keeps track of position by counting bursts:

- Moving from 20% to 70% sends 50% of the "full open" burst count as Open bursts, one every *Burst interval*.
- Moving to exactly 0% or 100% adds *Extra bursts* so the motor runs into its end stop. This also re-zeroes the tracked position.
- **Pause** stops mid-move, and the position is set from the bursts actually sent.
- A new command cancels a move that's in progress.

| Setting | Default | What it does |
|---|---|---|
| Device behavior | Bond configuration | Bond or Custom |
| Bursts for full OPEN | 45 | Open bursts from fully closed to fully open |
| Bursts for full CLOSE | 45 | Close bursts from fully open to fully closed |
| Extra bursts at 0% / 100% | 5 | Overrun to push against the end stop |
| Burst interval (ms) | 620 | Time between bursts |

**Calibrating:** close fully, then count (or time) how many bursts it takes to open fully, and put that in *Bursts for full OPEN*. Do the same for close. If it stops short at the ends, raise *Extra bursts*.

### Lights and single-button devices

**Bond configuration**: a normal light switch using `TurnLightOn` / `TurnLightOff`, or `ToggleLight` only when the state needs to change. State is read from the Bridge.

**Custom (raw signals)**: a **momentary trigger** for one-button devices (gate openers, doors that close themselves, scene buttons). The device gets a **button** and a **switch**. Pressing either transmits the learned signal, and the switch turns itself back off after a few seconds, so "Alexa, turn on <device>" works every time.

| Setting | Default | What it does |
|---|---|---|
| Device behavior | Bond configuration | Bond or Custom |
| Switch resets after (s) | 3 | Custom only: how long the switch stays on after a trigger |

### Shark misting fan
Set a fan's **Device behavior** to **Shark misting fan (custom)** to get a layout built for that remote. Every button on it is a toggle or a cycle, and the fan can't report anything, so the driver tracks each feature and gets to what you pick by counting button presses.

| Control | Remote button learned in Bond as | Behavior |
|---|---|---|
| Fan on/off | `TogglePower` | Turning off resets every feature, the same way the fan does |
| Speed (1–5) | `IncreaseSpeed` / `DecreaseSpeed` | Steps up/down from the tracked speed |
| Boost | `SetSpeed 8` | On/off |
| Mist | `SetDirection` ("Summer") | Off → High → Medium → Low → Off |
| Swing | `ToggleDirection` ("Reverse") | Off → Narrow → Medium → Wide → Off |
| Breeze | `BreezeOn` | Off → Breeze 1 → Breeze 2 → Off |

Choosing a feature while the fan is off turns it on first.

| Setting | Default | What it does |
|---|---|---|
| Fan speed for step 1–4 | 0 (automatic) | Which of the 5 speeds each SmartThings step uses |
| Speed after power on | 1 | The speed the fan starts at when turned on |
| Time between button presses (ms) | 900 | Spacing when a setting needs several presses |
| Fix power / speed / boost / mist / swing / breeze | No change | Resync the tracked state without sending anything |

### Fireplaces and other devices
Fireplaces (`FP`), generic (`GX`) and any other type get an on/off switch using `TurnOn` / `TurnOff` (or `TogglePower`). State is read from the Bridge. These have no behavior setting.

---

## Bond vs Custom behavior

| | Bond configuration | Custom (raw signals) |
|---|---|---|
| What's sent | Bridge actions (`/v2/devices/<id>/actions/...`) | Learned raw RF codes (`/v2/signal/tx`) |
| State | Read from the Bridge | Tracked by the driver |
| Needs learned buttons | No | Yes |
| Template devices (no learned signals) | Work | Don't work, the driver logs "no raw signal" |
| Extras | — | Speed remapping, burst positioning, momentary triggers, Shark layout |

Switching behavior swaps the device's profile, so the available settings change to match. Give the app a few seconds and reopen the device.

> RF remotes are one-way, so the Bridge itself is guessing at state too. If someone uses the physical remote, SmartThings can drift out of sync in either mode. That's what the Fix settings are for.

## Correcting tracked state ("Fix" settings)
If SmartThings shows the light as on but it's actually off (for example, someone used the wall remote), open the device's settings and set **Fix light state** to the real state. Nothing is transmitted:
- In **Custom** mode the driver's tracked state is corrected.
- In **Bond** mode the Bridge's own tracked state is corrected too (`PATCH /v2/devices/<id>/state`), so the Bond app agrees.

The next toggle will then do the right thing. Fan devices have Fix light and Fix winter mode. The Shark layout has Fix settings for every feature.

## Adding or changing devices later
Added a device or learned new buttons in the Bond app? Press **Refresh** on the **Bond Bridge** device. The driver re-reads every Bond device, creates any new ones, and updates the stored commands and raw signals on existing ones. Existing devices keep their names, rooms and automations.

Deleting a device in SmartThings doesn't delete it from Bond. A Refresh on the Bridge will create it again.

## Troubleshooting
| Symptom | What to check |
|---|---|
| Scan finds nothing | Hub and Bridge on the same network/VLAN? A blank "Bond Bridge" device should still be created. Enter the IP in its settings. |
| "no token" in the logs | Power-cycle the Bridge, then press Refresh on the Bond Bridge device within 10 minutes. Or enter the token manually. |
| "could not read devices (check IP/token)" | Wrong IP (the Bridge's IP may have changed, so set a DHCP reservation) or wrong token. |
| Device does nothing in Custom mode, log says "no raw signal" | The Bond device was made from a template. Learn the remote's buttons in the Bond app, then Refresh the Bond Bridge, or use Bond configuration. |
| Light/fan state is backwards | Use the Fix settings. Toggle-only remotes can't report state. |
| Shade stops short or overshoots in Custom mode | Calibrate the burst counts, then adjust Extra bursts and Burst interval. |
| Fan speeds feel wrong | Set *Fan speed for step 1–4* to the speeds you want. |

When asking for help, please include logs (`smartthings edge:drivers:logcat`), your Bridge model and firmware, and the Bond device type.

## Limitations
- State changes made outside SmartThings (Bond app, physical remote) show up when the device is next refreshed or controlled. There are no push updates yet.
- Bond groups and scenes aren't imported.
- Fan timers, up/down lights and shade tilt aren't supported.
- Fireplace flame level isn't exposed. Fireplaces are on/off.
- Custom mode needs learned raw signals.

## How it works
Bond Local API v2 endpoints used (`BOND-Token` header):

| Endpoint | Used for |
|---|---|
| mDNS `_bond._tcp` | Finding Bridges |
| `GET /v2/token` | Automatic token (unlocked for ~10 min after boot) |
| `GET /v2/devices` | Listing devices |
| `GET /v2/devices/<id>` and `/properties` | Type, supported actions, `max_speed` |
| `GET /v2/devices/<id>/commands` and `/commands/<cmd>/signal` | Learned buttons and their raw RF signals |
| `PUT /v2/devices/<id>/actions/<action>` | Bond-mode commands |
| `GET` / `PATCH /v2/devices/<id>/state` | Reading state, Fix settings in Bond mode |
| `PUT /v2/signal/tx` | Sending raw signals in Custom mode |

Reference: https://docs-local.appbond.com/

## Files
| File | Purpose |
|---|---|
| `config.yml` | Driver name, package key, LAN + discovery permissions |
| `src/init.lua` | Discovery, lifecycle, behavior/profile switching, command dispatch |
| `src/hub.lua` | Bond Bridge device: token handling, reading Bond devices, creating child devices, picking profiles |
| `src/bond.lua` | Local API: HTTP, credentials, token, mDNS, raw tx, actions, state |
| `src/fan.lua` | Ceiling fans (both modes) |
| `src/fanlight.lua` | "<Fan> Light" device |
| `src/shade.lua` | Shades / pergolas, burst positioning |
| `src/light.lua` | Lights and momentary triggers |
| `src/shark.lua` | Shark misting fan layout |
| `src/generic.lua` | Fireplaces and other on/off devices |
| `src/util.lua` | Helpers for cached Bond info and settings |
| `profiles/` | `bond-bridge`, `bond-fan[-rev][-breeze][-custom]`, `bond-fan-shark-misting-custom`, `bond-fan-light`, `bond-shade[-custom]`, `bond-light[-custom]`, `bond-generic` |

---
Community driver, not affiliated with or supported by Bond / Olibra or Samsung SmartThings.
