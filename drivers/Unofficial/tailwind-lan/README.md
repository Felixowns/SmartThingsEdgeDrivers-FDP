# Tailwind LAN (SmartThings Edge)

Local control of Tailwind iQ3 garage door controllers (and the Tailwind Light controller) over the Tailwind Local Control API. No Tailwind cloud, no SmartThings linked service.

Requires controller firmware 9.96+ (identify/reboot need 10.10+, cloud-monitor toggle needs 10.61+).

## Setup
1. Get your **Local Control Key**: web.gotailwind.com > Local Control Key (create one if none is shown; controller must be online).
2. Add device > Scan nearby. The driver finds `TW-WebServer._http._tcp` over mDNS (host `tailwind-<mac>.local`, TXT `vendor=tailwind`) and creates a **Tailwind iQ3** device. If mDNS finds nothing, a blank controller is created: enter its IP in settings.
3. Open the controller's settings and enter the Local Control Key. Doors appear as child devices within a few seconds.

## Devices
| Device | Capabilities |
|---|---|
| Controller (`tailwind-iq3`) | signalStrength (Wi-Fi RSSI), refresh; **Status LED** component = switchLevel (green LED brightness); **Identify** and **Reboot** = momentary |
| Door N (`tailwind-door`, EDGE_CHILD) | doorControl, contactSensor, tamperAlert (= door lockup), refresh; **Partial open** = momentary |
| Tailwind Light (`tailwind-light`) | switch, switchLevel (power), **Mode** auto (radar) / manual, signalStrength, identify, reboot; radar delay / lux / sensitivity in settings |

A door that the controller reports as disabled is marked offline. Doors are only created for door slots the controller reports (`door_num`).

## Status
- **Push**: the driver opens a UDP port on the hub and registers it with `notify_url` (proto udp). Door changes arrive immediately. Re-registered every 30 min, after a reboot event, and after IP/key changes.
- **Backup poll**: `dev_st` every 60 s (setting).
- If the controller stops answering, the driver re-runs mDNS to find a new IP (unless a fixed IP is set) and marks it offline after 3 failures. A `Fail` reply (bad key) marks it offline right away.
- Open/close shows Opening/Closing until the controller reports the target state or the door's **travel time** (default 20 s) runs out.

## API coverage (Tailwind Local Control API)
All calls: `POST http://<ip>/json`, header `TOKEN: <key>`.
| API | Name | Used for |
|---|---|---|
| 3.1 | `get dev_st` | status poll / refresh |
| 3.2 | `set notify_url` | UDP push (disabled again when the device is removed or push is turned off) |
| 3.3 | `set door_op` `{door_idx, cmd, partial_time}` | open / close / partial open |
| 3.4 | `set status_led` `{brightness}` | Status LED level |
| 3.5 | `set dev_op` (light) `{power, delay, lux, distance, mode}` | Tailwind Light |
| 3.6 | `set identify` (v0.2) | Identify button |
| 3.7 | `set reboot` (v0.2) | Reboot button |
| 3.8 | `set server_monitor` (v0.2) `{enable}` | "Cloud connection monitoring" setting |

Notification events handled: open, close, lock, enable, disable, reboot.

## Files
- `src/init.lua` — lifecycle, discovery, children, status mapping, command handlers
- `src/tailwind_api.lua` — HTTP JSON client for every API call
- `src/push.lua` — UDP status listener
- `src/discovery.lua` — mDNS scan / IP re-lookup

Reference: github.com/Scott--R/Tailwind_Local_Control_API
