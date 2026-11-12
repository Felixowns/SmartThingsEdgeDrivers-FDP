# Tailwind LAN — SmartThings Edge Driver

Local control of **Tailwind iQ3** smart garage door controllers (and the **Tailwind Light** controller) from SmartThings, using Tailwind's official **Local Control API**.

Everything runs on your SmartThings hub and talks directly to the Tailwind controller on your home network. There is no Tailwind cloud, no SmartThings linked service (Schema / cloud-to-cloud), and no extra bridge, so door control keeps working when your internet is down.

---

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Setup](#setup)
- [Devices and capabilities](#devices-and-capabilities)
- [Settings](#settings)
- [How it works](#how-it-works)
- [Automation examples](#automation-examples)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [Tailwind API coverage](#tailwind-api-coverage)
- [File layout](#file-layout)
- [Credits and references](#credits-and-references)

---

## Features

- **100% local**: the hub talks to the iQ3 over HTTP on your LAN.
- **Automatic discovery** over mDNS, with a manual IP fallback.
- **One SmartThings device per door**: up to 3 doors per iQ3, created automatically.
- **Instant status**: the controller pushes door changes to the hub over UDP, so state updates arrive within about a second, including when the door is moved by a remote, the wall button, or the Tailwind app.
- **Backup polling** in case a push is missed.
- **Opening / Closing** shown while the door travels.
- **Partial open** button with a configurable run time.
- **Door lockup** reported as a tamper alert.
- **Controller extras**: status-LED brightness, Wi‑Fi signal strength, Identify (blink), Reboot, and the cloud-connection watchdog toggle.
- **Self-healing**: if the controller gets a new IP address, the driver finds it again with mDNS.
- **Tailwind Light** support: on/off, brightness, auto (radar) / manual mode, and radar settings. This part is untested; see [Limitations](#limitations).

---

## Requirements

| Item | Requirement |
|---|---|
| SmartThings hub | Any hub that runs Edge drivers (v2, v3, Aeotec, Station, or a hub built into a TV or appliance) |
| Tailwind controller | iQ3 (any generation), or Tailwind Light |
| Controller firmware | **9.96 or newer** (required for the JSON API and the token). Identify and Reboot need **10.10+**; the cloud-monitor toggle needs **10.61+** |
| Network | Hub and controller on the same LAN/subnet. mDNS discovery needs multicast to pass between them; a manual IP works without it |
| Local Control Key | 6-digit key from the Tailwind web dashboard (see below) |

Works with the iQ3 in both **dry contact** and **digital control** modes, since the local API is the same either way.

---

## Installation

### From the channel

1. Open the channel invite link and sign in with your Samsung account:
   **https://bestow-regional.api.smartthings.com/invite/r3MyN0639J2p**
2. Enroll your hub, open **Available Drivers**, and install **Tailwind LAN**.

### From source (SmartThings CLI)

```bash
smartthings edge:drivers:package drivers/Unofficial/tailwind-lan
smartthings edge:channels:assign        # pick your channel and the driver
smartthings edge:drivers:install        # pick your hub
```

The hub can take a few minutes to pick up a new version. To confirm what is installed, run `smartthings edge:drivers:installed` and compare the version timestamp.

---

## Setup

### 1. Get your Local Control Key

1. Go to **https://web.gotailwind.com** and log in.
2. Click **Local Control Key** in the top menu.
3. If no key is shown, click **Create new local command key**. The controller must be online when you do this.
4. Note the 6-digit code.

> If the key ever leaks, create a new one the same way and update it in the driver settings.

### 2. Add the controller

1. In the SmartThings app: **+ → Add device → Scan for nearby devices**.
2. The driver searches for `TW-WebServer._http._tcp` on your network and creates a **Tailwind iQ3** device for each controller it finds.
3. If nothing is found (for example, multicast is blocked between VLANs), a blank **Tailwind iQ3** device is created instead. Enter its IP address in settings.

### 3. Enter the key

1. Open the **Tailwind iQ3** device → **⋮ → Settings**.
2. Enter the **Local Control Key**.
3. Go back and pull down to refresh.

Within a few seconds a device for each door (for example **Tailwind iQ3 Door 1**) appears in the same room. Move it to any room you like.

> **Tip:** give the controller a DHCP reservation in your router. The driver re-finds it if the IP changes, but a fixed address is faster and more reliable.

---

## Devices and capabilities

### Tailwind iQ3 (controller)

The parent device. It shows in the app with the "hub" style icon, but it is just the controller.

| Component | Capability | What it does |
|---|---|---|
| main | **Signal Strength** | Controller Wi‑Fi RSSI in dBm. Above about −67 is good; below −75 can cause missed commands |
| main | **Refresh** | Reads status now and re-registers instant updates |
| Status LED | **Switch Level** | Brightness 0–100 of the controller's green "online" LED. 0 turns it off |
| Identify | **Momentary** | Blinks the controller's white light 3 times so you can find it (fw 10.10+) |
| Reboot controller | **Momentary** | Restarts the controller (about 2 s). The driver re-arms push afterward (fw 10.10+) |

### Tailwind iQ3 Door N (one per door)

Child devices, created automatically for each door the controller reports. A door that is **disabled** in the Tailwind app is skipped, or shown offline if it already exists.

| Component | Capability | What it does |
|---|---|---|
| main | **Door Control** | Open / Close. Shows *Opening* or *Closing* until the controller reports the new position or the travel time runs out |
| main | **Contact Sensor** | Open / Closed position only. Best for automation conditions |
| main | **Tamper Alert** | *Detected* when the controller reports the door is in **lockup** (it refused to move after a fault). Normally *Clear* |
| main | **Refresh** | Refreshes the parent controller |
| Partial open | **Momentary** | Opens the door for the configured *Partial open time*, then stops. Disabled until that time is set |

Tapping **Open** on an already-open door (or **Close** on a closed one) does nothing. The driver checks the current state first, so a wrong-direction command can't reverse a door that's already where you want it.

### Tailwind Light (if you have one)

| Component | Capability | What it does |
|---|---|---|
| main | **Switch** | On / off. On restores the last brightness |
| main | **Switch Level** | Light power 0–100 (sets manual mode) |
| main | **Signal Strength**, **Refresh** | Same as the controller |
| Mode | **Mode** | `auto` = radar motion sensor controls the light, `manual` = fixed brightness |
| Identify / Reboot | **Momentary** | Same as the controller |

---

## Settings

### Controller settings

| Setting | Default | Description |
|---|---|---|
| Local Control Key | — | 6-digit key from web.gotailwind.com. **Required** |
| IP address (optional) | blank | Leave blank to use discovery. Set it to pin a fixed address (this also disables automatic re-discovery) |
| Instant status (UDP push) | On | Controller reports changes to the hub immediately. Turning it off also tells the controller to stop sending |
| Backup poll interval (seconds) | 60 | How often the driver reads status anyway (10–3600) |
| Cloud connection monitoring | On | **Off** stops the controller from rebooting itself when it can't reach Tailwind's servers. Useful if you block its internet or have an unreliable connection (fw 10.61+) |

### Door settings

| Setting | Default | Description |
|---|---|---|
| Door travel time (seconds) | 20 | How long *Opening/Closing* is shown before trusting the reported state. Set it to about how long your door takes to move |
| Partial open time (seconds) | 0 | Run time for the **Partial open** button. 0 = disabled |

### Tailwind Light settings

| Setting | Default | Description |
|---|---|---|
| Stay-on time after motion (s) | 300 | How long the light stays on after motion (0–65535) |
| Radar active below (lux) | 1000 | The radar only triggers when ambient light is below this |
| Radar sensitivity (0–15) | 15 | Higher is more sensitive |

---

## How it works

```
 SmartThings app / automations
            │
            ▼
   SmartThings hub (Edge driver: tailwind-lan)
     │  HTTP POST /json  (TOKEN header)        ▲  UDP status report
     ▼                                          │  (on every door change)
   Tailwind iQ3 controller  ────────────────────┘
     │  dry contact or digital control
     ▼
   Garage door opener
```

- **Commands**: every action is an HTTP `POST` to `http://<controller-ip>/json` with header `TOKEN: <local key>` and a small JSON body. Each request has a 5-second timeout and retries once.
- **Status**: `dev_st` returns the controller info plus every door's `status` (open/close), `lockup`, and `disabled`.
- **Push**: on startup the driver opens a UDP port on the hub and registers `hub-ip:port` with the controller (`notify_url`, proto `udp`). The controller then sends its full status plus a `notify` event (`open`, `close`, `lock`, `enable`, `disable`, `reboot`) on every change. Registration is renewed every 30 minutes, after a controller reboot, and after an IP or key change.
- **Polling**: a `dev_st` read every *Backup poll interval* covers missed pushes and also re-checks the push registration.
- **Discovery**: mDNS browse of `_http._tcp`, matching the `TW-WebServer` service, a `tailwind-<mac>.local` host, or TXT `vendor=tailwind`. The controller's MAC becomes the SmartThings network ID (`tailwind-<mac>`).
- **Failure handling**: after 2 failed reads, the driver re-runs mDNS to look for a new IP (unless you set one). After 3, the controller and its doors are marked offline. A `Fail` reply from the controller (usually a wrong key) marks it offline right away.
- **Removal**: deleting the controller device disables its push reports.

---

## Automation examples

- **Garage left open**: *If* Door 1 contact is **Open** for 15 minutes *and* time is after 10:00 PM → notify me, or *then* close Door 1.
- **Arrival**: *If* my phone arrives home → open Door 1. Consider adding a condition such as "Door is Closed" and "time is daytime".
- **Leaving**: *If* everyone leaves → close all doors.
- **Lockup alert**: *If* Door 1 tamper is **Detected** → notify me (the door refused to move).
- **Night LED**: at 10 PM set Status LED level to 0; at 7 AM set it to 50.

> ⚠️ Automatically closing a garage door you can't see is a safety risk. The opener's safety sensors still apply, but think about whether people, pets or vehicles could be in the way.

---

## Troubleshooting

Run the live log while you test:

```bash
smartthings edge:drivers:logcat     # pick "Tailwind LAN"
```

| Symptom / log line | Cause | Fix |
|---|---|---|
| Controller added but **no door device** | No status read yet | Enter the Local Control Key, then refresh. Look for `tailwind: creating door` in the log |
| `has no Local Control Key` | Key not set or not saved | Enter the key in Settings and back out so it saves |
| `has no IP address yet` | Discovery didn't record an IP | Enter the controller's IP (shown in the Tailwind app) in Settings |
| `status failed … device: …` | The controller rejected the request, usually a wrong or regenerated key | Copy the current key from web.gotailwind.com |
| `status failed … timeout` / `connection refused` | The hub can't reach that IP | Check the IP and that the hub and controller share a subnet/VLAN |
| `no door data in status … raw: {…}` | The controller's reply has an unexpected format | Open an issue / post the raw line |
| `door N is disabled in the Tailwind app` | That door is turned off in Tailwind | Enable it in the Tailwind app |
| Door state only updates once a minute | Push isn't reaching the hub | Make sure *Instant status* is on, check the log for `reports to <ip:port>`, and make sure nothing blocks UDP from the controller to the hub |
| Identify / Reboot do nothing | Firmware older than 10.10 | Update the controller in the Tailwind app |
| New driver version not running | The hub hasn't updated yet | `smartthings edge:drivers:installed` to check the version; reinstall, and restart logcat |
| Not found by scan | Multicast blocked, or the controller is on another VLAN | Scan creates a blank device; enter the IP manually |

Each refresh logs the full controller status at debug level (`tailwind: status {...}`). That line is the most useful thing to include when asking for help.

---

## Limitations

- **No opener light or lock control.** Tailwind's local API exposes only door open/close/partial open, even in digital control mode. "Light" in the API is the separate Tailwind Light product, not the opener's bulb.
- **No real-time position.** Doors report only open or closed, so *Opening/Closing* is time-based using *Door travel time*.
- **No HTTPS.** The API is plain HTTP on your LAN, protected by the 6-digit key. Keep the controller on a trusted network.
- **Push uses UDP.** If your network blocks UDP from the controller to the hub, you get polling only.
- **Tailwind Light support is untested.** It is written from the API documentation, without a physical device.
- **The controller shows as a "hub"** in the app; that's just the icon category.
- Door commands from the API trigger a phone notification from the Tailwind app ("Local Network Control opened …"). Turn those off in the Tailwind app if you don't want them.

---

## Tailwind API coverage

All requests are `POST http://<ip>/json` with header `TOKEN: <local control key>`.

| API § | Command (`data.name`) | Body (`data.value`) | Protocol | Used for |
|---|---|---|---|---|
| 3.1 | `get dev_st` | — | 0.1 | Status poll / refresh |
| 3.2 | `set notify_url` | `{url, proto: "udp", enable}` | 0.1 | Instant UDP push (disabled on removal / when turned off) |
| 3.3 | `set door_op` | `{door_idx: 0-2, cmd: "open"/"close", partial_time?}` | 0.1 | Open / close / partial open |
| 3.4 | `set status_led` | `{brightness: 0-100}` | 0.1 | Status LED level |
| 3.5 | `set dev_op` (product `light`) | `{power, delay, lux, distance, mode}` | 0.1 | Tailwind Light |
| 3.6 | `set identify` | — | 0.2 | Identify button |
| 3.7 | `set reboot` | — | 0.2 | Reboot button |
| 3.8 | `set server_monitor` | `{enable: bool}` | 0.2 | Cloud connection monitoring setting |

Push events handled: `open`, `close`, `lock`, `enable`, `disable`, `reboot`.

Example status reply (iQ3):

```json
{"result":"OK","product":"iQ3","dev_id":"_30_ae_a4_80_18_80_","proto_ver":"0.2",
 "door_num":1,"night_mode_en":0,"fw_ver":"10.10","led_brightness":100,
 "router_rssi":-35,"server_monitor":true,
 "data":{"door1":{"index":0,"status":"close","lockup":0,"disabled":0}}}
```

---

## File layout

```
tailwind-lan/
├── config.yml                  # driver name, packageKey, permissions (lan, discovery)
├── profiles/
│   ├── tailwind-iq3.yaml       # controller: RSSI, refresh, status LED, identify, reboot + settings
│   ├── tailwind-door.yaml      # door child: doorControl, contact, tamper, partial open + settings
│   └── tailwind-light.yaml     # Tailwind Light: switch, level, mode, radar settings
└── src/
    ├── init.lua                # lifecycle, discovery, child doors, status mapping, command handlers
    ├── tailwind_api.lua        # HTTP JSON client for every Local Control API call
    ├── push.lua                # UDP listener for controller status reports
    └── discovery.lua           # mDNS scan and IP re-lookup
```

---

## Credits and references

- Tailwind Local Control API (official): https://github.com/Scott--R/Tailwind_Local_Control_API
- Tailwind "Works with" page: https://gotailwind.com/pages/what-does-tailwind-work-with
- `aiotailwind` Python library by pauln, a useful second reference: https://github.com/pauln/aiotailwind

Tailwind and iQ3 are trademarks of Tailwind. This is an unofficial community driver, not affiliated with or supported by Tailwind or Samsung SmartThings. Use at your own risk.
