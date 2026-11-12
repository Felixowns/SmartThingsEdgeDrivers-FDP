# Ring LAN Bridge — SmartThings Edge Driver

Brings **Ring Alarm contact sensors** and **Ring camera lights** (floodlight / spotlight cams) into SmartThings, with near-instant status updates.

Edge drivers can only talk to devices on your local network, and Ring has no local API. So a small Node.js bridge runs on an always-on device on your LAN (an old Android phone in Termux works well). The bridge signs in to Ring with [`ring-client-api`](https://github.com/dgreif/ring), keeps a live connection to Ring, and pushes every change to the hub over your LAN.

```
Ring sensors / cameras ⇄ Ring cloud ⇄ ring-bridge.js (Termux + PM2) ⇄ LAN ⇄ SmartThings hub (this driver)
```

---

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Bridge setup (Termux + PM2)](#bridge-setup-termux--pm2)
- [Driver setup](#driver-setup)
- [Devices and capabilities](#devices-and-capabilities)
- [Combining two-pane window sensors](#combining-two-pane-window-sensors)
- [Settings](#settings)
- [How it works](#how-it-works)
- [Bridge API](#bridge-api)
- [Automation examples](#automation-examples)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [File layout](#file-layout)
- [Credits](#credits)

---

## Features

- **Ring Alarm contact sensors** (doors, windows, gates) as SmartThings contact sensors.
- **Ring camera lights** as SmartThings switches: on/off from the app, routines, and voice assistants.
- **Instant status**: the bridge pushes each change to the hub as soon as Ring reports it, usually in about a second.
- **Backup polling** every 30 seconds, one request for all devices, in case a push is missed.
- **Online / offline**: devices show offline when the bridge can't be reached, instead of showing stale data.
- **Combined window devices**: merge two pane sensors (left and right) into one window device, with a combined state on the tile and each pane in the detail view.
- **Exclusion list**: hide Ring devices you don't want in SmartThings, such as shared neighborhood cameras.
- **Discovery**: "Scan for nearby devices" creates every Ring device the bridge exposes, without making duplicates.
- **Automatic token refresh**: the bridge saves Ring's rotated refresh token, so restarts don't log you out.

---

## Requirements

| Item | Requirement |
|---|---|
| SmartThings hub | Any hub that runs Edge drivers |
| Ring | A Ring account with Ring Alarm contact sensors and/or cameras with lights |
| Bridge device | Always-on device on the same LAN as the hub. Tested on an Android phone with **Termux**. Any machine with Node.js works (Raspberry Pi, PC, NAS) |
| Node.js | **18 or newer** (uses the built-in `fetch`) |
| Network | Hub and bridge on the same LAN/subnet. The hub must reach the bridge on port 8080, and the bridge must reach the hub on the port the driver opens |
| Internet | Required. The bridge talks to Ring's cloud |

> **Tip:** give the bridge device a DHCP reservation in your router so its IP never changes.

---

## Installation

### From the channel

1. Open the channel invite link and sign in with your Samsung account:
   **https://bestow-regional.api.smartthings.com/invite/r3MyN0639J2p**
2. Enroll your hub, open **Available Drivers**, and install **Ring LAN Bridge**.

### From source (SmartThings CLI)

```bash
smartthings edge:drivers:package drivers/Unofficial/Ring-LAN-Bridge
smartthings edge:channels:assign        # pick your channel and the driver
smartthings edge:drivers:install        # pick your hub
```

---

## Bridge setup (Termux + PM2)

### 1. Install Node.js and PM2

Install **Termux** from F-Droid or GitHub (the Play Store build is outdated), then:

```bash
pkg update && pkg install nodejs
npm install -g pm2
termux-wake-lock        # keeps Android from putting Termux to sleep
```

Also turn off battery optimization for Termux in Android settings.

### 2. Create the bridge folder

```bash
mkdir ~/ring-bridge && cd ~/ring-bridge
npm init -y
npm install ring-client-api express
```

Copy [`ringbridge.txt`](ringbridge.txt) from this folder to `~/ring-bridge/ring-bridge.js`.

### 3. Get a Ring refresh token

```bash
npx -p ring-client-api ring-auth-cli
```

Sign in, enter your 2FA code, and copy the token it prints. Then paste it into `ring-bridge.js`:

```js
const HARDCODED_TOKEN = 'paste your token here';
```

You can set the `RING_REFRESH_TOKEN` environment variable instead.

> **Keep the token private.** Anyone with it can access your Ring account. Don't commit `ring-bridge.js` or `.ring-token` to a public repository.

### 4. Configure devices (optional)

Near the top of `ring-bridge.js`:

- `EXCLUDED_DEVICE_NAMES`: Ring device names to hide. Matching is exact and case-insensitive.
- `WINDOW_GROUPS`: pairs of pane sensors to combine. See [Combining two-pane window sensors](#combining-two-pane-window-sensors).
- `HIDE_GROUPED_SENSORS`: `true` keeps paired pane sensors out of discovery.
- `PORT`: default `8080`, or set the `PORT` environment variable.

### 5. Test, then run under PM2

```bash
node ring-bridge.js
```

You should see your devices listed, then `Bridge ready. Total active endpoints monitored: N`. From another device, open `http://<bridge-ip>:8080/api/devices`. It should list your devices. Then press Ctrl+C and run it under PM2:

```bash
pm2 start ring-bridge.js --name ring-bridge
pm2 save
pm2 startup             # optional: follow the printed instructions to start on boot
```

Useful PM2 commands:

```bash
pm2 list                                   # status and restart count
pm2 logs ring-bridge --lines 50 --nostream # recent output
pm2 restart ring-bridge                    # after editing the script
```

### Token refresh

Ring issues a new refresh token as the bridge uses it, and older tokens eventually stop working. The bridge saves each new token to `.ring-token` next to the script, prints `Saved refreshed Ring token`, and uses that file first on every start. The hardcoded token is only a fallback.

- **Normal restarts:** leave `.ring-token` alone.
- **New token from `ring-auth-cli`:** paste it into the script, **delete `.ring-token`**, and restart.
- **Run only one copy of the bridge per token.** Two copies refreshing the same token can invalidate each other.

---

## Driver setup

1. Start the bridge first.
2. In the SmartThings app, go to **+ → Add device → Scan for nearby devices**.
3. The driver reads `/api/devices` from the bridge and creates one device per Ring sensor, light and window group. Discovery uses `192.168.1.17:8080` by default, or the bridge address of an existing Ring LAN Bridge device.
4. If your bridge uses another address: after the first device is created, open its **⋮ → Settings**, set **Bridge IP Address** and **Bridge Port**, then scan again. Each device keeps its own bridge settings.
5. Move the new devices into the right rooms.

Within about 30 seconds the bridge log shows `Hub subscribed: http://<hub-ip>:<port>/ring/event`. From then on, changes are pushed instantly.

---

## Devices and capabilities

### Ring contact sensor (`ring-contact`)

| Component | Capability | Notes |
|---|---|---|
| main | **Contact Sensor** | Open / Closed (Ring reports the sensor as "faulted" when it's open) |
| main | **Refresh** | Reads the bridge now |

### Ring camera light (`ring-light`)

| Component | Capability | Notes |
|---|---|---|
| main | **Switch** | Turns the camera's light on/off. State updates when Ring reports the light changed, including from the Ring app or a motion trigger |
| main | **Refresh** | Reads the bridge now |

The switch only shows the new state after the bridge confirms the command. If the command fails, the tile goes back to the real state.

### Ring window (`ring-window`)

A combined device built from two pane sensors.

| Component | Capability | Notes |
|---|---|---|
| Window (main) | **Contact Sensor**, **Refresh** | **Open** if either pane is open, Closed only when both are closed. This is what the tile shows |
| Left Pane | **Contact Sensor** | The left pane's own state |
| Right Pane | **Contact Sensor** | The right pane's own state |

---

## Combining two-pane window sensors

Some windows have one sensor per pane or sash. Instead of two separate devices, the bridge can present them as one window. Add an entry to `WINDOW_GROUPS` in `ring-bridge.js`:

```js
const WINDOW_GROUPS = [
  {
    id: 'window-living-room',          // unique; becomes the SmartThings network ID
    name: 'Living Room Window',        // name used when the device is created
    left: 'Living Room Left Window Sensor',    // exact Ring sensor name
    right: 'Living Room Right Window Sensor',  // exact Ring sensor name
  },
];
```

Then restart the bridge (`pm2 restart ring-bridge`) and check the log for:

```
[WINDOW GROUP] "Living Room Window" = "Living Room Left Window Sensor" + "Living Room Right Window Sensor"
```

If it says `skipped - sensor not found`, a name doesn't exactly match the Ring app, or that sensor is on the exclusion list. Finally, **Scan for nearby devices** to add the window.

With `HIDE_GROUPED_SENSORS = true`, the two pane sensors are left out of discovery, so they aren't re-added after you delete their separate SmartThings devices. Existing pane devices keep working until you delete them. Rebuild any routines that use them first.

**How it looks:** the tile shows the combined state. Tap it to see **Window**, **Left Pane** and **Right Pane**. The dashboard tile can't show both panes without a custom capability, so this driver keeps to standard capabilities.

---

## Settings

Every Ring LAN Bridge device has:

| Setting | Default | Description |
|---|---|---|
| Bridge IP Address | `192.168.1.17` | IP of the device running `ring-bridge.js` |
| Bridge Port | `8080` | Port the bridge listens on |

Changing either one takes effect right away. The driver re-registers with the bridge and refreshes.

---

## How it works

- **Push:** when the driver starts, it opens a small HTTP listener on the hub (random port) and registers `http://<hub-ip>:<port>/ring/event` with the bridge (`POST /api/subscribe`). It re-registers every 30 seconds, so a restarted bridge picks it up again. The bridge uses `ring-client-api`'s live subscriptions and POSTs `{ "id": ..., "state" | "on": ... }` to the hub only when a value actually changes. The bridge drops subscriptions that haven't been renewed in 5 minutes.
- **Backup poll:** every 30 seconds the driver makes one `GET /api/states` request per bridge and updates every device from it. The driver only sends SmartThings events when a value changes.
- **Older bridges:** if `/api/states` doesn't exist, the driver falls back to one request per device (`/api/sensors/<id>`, `/api/lights/<id>`).
- **Online / offline:** devices are marked offline only when the bridge can't be reached at all, and back online on the next successful read or push.
- **Network IDs:** devices are created as `ring-<ring device id>`. Window groups use `ring-<group id>`.
- **Timeouts:** each HTTP request to the bridge times out after 3 seconds, so an unreachable bridge can't stall the driver.

---

## Bridge API

| Method | Path | Body / response |
|---|---|---|
| GET | `/api/devices` | `[{ "id", "name", "category": "contact" \| "light" \| "window" }]` |
| GET | `/api/states` | `{ "<id>": { "state": "open" \| "closed" } \| { "on": true \| false } \| { "state", "left", "right" } }` |
| GET | `/api/sensors/<id>` | `{ "state": "open" \| "closed" }` |
| GET | `/api/lights/<id>` | `{ "on": true \| false }` |
| POST | `/api/lights/<id>/state` | `{ "on": true \| false }` → `{ "success": true, "on": ... }` |
| POST | `/api/subscribe` | `{ "url": "http://<hub-ip>:<port>/ring/event" }` |

---

## Automation examples

- **Window left open:** *If* Master Bedroom Window is **Open** for 30 minutes *and* the thermostat is cooling → notify me.
- **Which pane opened:** *If* Master Bedroom Window → **Left Pane** opens → notify "Master bedroom: left pane opened". Routines can use each pane separately. Standard device alerts only name the whole window.
- **Light on arrival:** *If* someone arrives home after sunset → turn on the Driveway light for 10 minutes.
- **Gate opened at night:** *If* Back Gate opens between 11 PM and 6 AM → turn on the Backyard light and notify me.

---

## Troubleshooting

Live driver log:

```bash
smartthings edge:drivers:logcat     # pick "Ring LAN Bridge"
```

| Symptom | Cause | Fix |
|---|---|---|
| All devices **offline** | The hub can't reach the bridge | Open `http://<bridge-ip>:8080/api/devices` from a PC on the same network. If it doesn't load, the bridge isn't running, Termux is asleep, or the IP changed. Check `pm2 list`, run `termux-wake-lock`, and set a DHCP reservation |
| `/api/devices` returns `[]` | Still starting up, or the Ring login failed | Wait 15 seconds and reload. Then check `pm2 logs ring-bridge --err` |
| `Refresh token is not valid` | Ring rejected the token | Run `npx -p ring-client-api ring-auth-cli`, paste the new token, delete `.ring-token`, then `pm2 restart ring-bridge` |
| Updates take ~30 s instead of ~1 s | Push isn't reaching the hub | Look for `Hub subscribed:` in the bridge log, and `push listener on port` in the driver log. Make sure nothing blocks the bridge from connecting to the hub |
| `[WINDOW GROUP] ... skipped - sensor not found` | Name mismatch | Copy the sensor names exactly as the bridge log or the Ring app shows them |
| A device you excluded still appears | Matching is exact | Use the full device name in `EXCLUDED_DEVICE_NAMES` |
| Scan finds nothing | Wrong bridge address | Set **Bridge IP Address/Port** on an existing device and scan again |
| `crypto-key is missing` / `ERR_CRYPTO_ECDH_INVALID_PUBLIC_KEY` in the bridge log | Ring push-notification setup inside `ring-client-api` | Harmless for this bridge; it uses the live device connection, not phone notifications |
| Light tile goes back after you tap it | The bridge or Ring rejected the command | Check the bridge log for the error; the camera may be offline in the Ring app |

---

## Limitations

- **Not fully local.** The hub-to-bridge link is local, but the bridge needs Ring's cloud. If your internet is down, nothing updates.
- **Contact sensors and camera lights only.** Motion sensors, the alarm mode, sirens, locks and doorbells aren't exposed yet.
- **No authentication on the bridge API.** Anyone on your LAN can read states and switch camera lights. Keep the bridge on a trusted network.
- **The bridge address is set per device.** All devices normally point to the same bridge.
- **Window tile shows the combined state only.** Pane detail is in the device view and in routines.
- This is an unofficial community driver, not affiliated with or supported by Ring, Amazon, or Samsung SmartThings. It relies on Ring's unofficial API via `ring-client-api`, which Ring can change at any time.

---

## File layout

```
Ring-LAN-Bridge/
├── config.yml                 # driver name, packageKey, permissions (lan, discovery)
├── ringbridge.txt             # Node.js bridge, copy to ring-bridge.js on the bridge device
├── profiles/
│   ├── ring-contact.yaml      # contact sensor + refresh, bridge IP/port settings
│   ├── ring-light.yaml        # switch + refresh, bridge IP/port settings
│   └── ring-window.yaml       # Window (main) + Left Pane + Right Pane contact sensors
└── src/
    └── init.lua               # discovery, push listener, polling, commands, lifecycle
```

---

## Credits

- [`ring-client-api`](https://github.com/dgreif/ring) by dgreif, which makes the Ring connection possible. See its [refresh token wiki](https://github.com/dgreif/ring/wiki/Refresh-Tokens).
- Source: https://github.com/Felixowns/SmartThingsEdgeDrivers-FDP/tree/main/drivers/Unofficial/Ring-LAN-Bridge

Ring is a trademark of Ring LLC / Amazon. Use at your own risk.
