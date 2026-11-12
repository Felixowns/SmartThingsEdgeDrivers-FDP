# Ergomotion Bed — SmartThings Edge Driver

Local control of **Ergomotion adjustable bed bases with a Keeson controller and Wi‑Fi module** from SmartThings.

The driver runs on your SmartThings hub and talks directly to the bed's Wi‑Fi module on your home network (TCP port 5000). It doesn't use a cloud service or a linked account, so the bed keeps working from SmartThings when your internet is down. It also reads the bed's status back. Head and foot positions, massage levels, the massage timer and the vibration pattern in the app match what the bed is actually doing, including changes made with the hand remote.

---

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Setup](#setup)
- [Controls](#controls)
- [Settings](#settings)
- [How it works](#how-it-works)
- [Automation examples](#automation-examples)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [Protocol reference](#protocol-reference)
- [File layout](#file-layout)
- [Credits and references](#credits-and-references)

---

## Features

- **Local only**: the hub talks to the bed's Wi‑Fi module over your LAN.
- **SmartThings Motion card** (`motionBed`):
  - **Hold-to-move** Head, Foot and Elevation (lumbar) up/down buttons. The bed moves while you hold a button and stops when you let go.
  - **Preset buttons**: Preset (Memory A), Preset 2 (Memory B), Zero gravity and Flat.
  - **Current mode**: the card shows which preset the bed is in. The driver learns where each preset puts the bed, then recognizes when the bed is there.
- **Position sliders** for Head and Foot (0–100 %). These use the bed's real reported position: set 60 % and the bed drives to 60 % and stops.
- **Lumbar slider** (0–100 %). The bed doesn't report lumbar position, so this one is estimated from motor run time.
- **Massage card**:
  - Massage on/off.
  - Head, foot and whole-bed intensity (Off / Low / Medium / High).
  - Timer (10 / 20 / 30 min) and **"Ends at"** for the current massage.
- **Vibration pattern** slider: three pulse speeds plus continuous.
- **Online status**: the switch is on while the bed is reachable. After two failed connection attempts in a row, SmartThings marks the device **offline**, and it comes back online by itself when the bed responds again.
- **Auto-calibration**: head and foot travel limits are learned the first time you drive each to 100 %.
- **Follows the hand remote**: whenever the driver talks to the bed it reads the full status, so changes made with the remote appear on the next refresh or command.

---

## Requirements

| Item | Requirement |
|---|---|
| SmartThings hub | Any hub that runs Edge drivers |
| Bed | Ergomotion base with a Keeson controller and its Wi‑Fi module, already connected to your Wi‑Fi (set up with the manufacturer's app) |
| Network | Hub and bed on the same LAN. The bed must accept connections on **TCP port 5000** |
| IP address | The bed's IP address. A **DHCP reservation** on your router is strongly recommended so the address doesn't change |

**Tested on:** one Ergomotion base with a Keeson controller and Wi‑Fi module. Other bases that use the same Keeson controller (some Serta, Tempur, GhostBed and Askona models) may also work. Those are untested; please report back if you try one.

---

## Installation

### From the channel

1. Open the channel invite link and sign in with your Samsung account:
   **https://bestow-regional.api.smartthings.com/invite/r3MyN0639J2p**
2. Enroll your hub, open **Available Drivers**, and install **Ergomotion Bed Driver**.

### From source (SmartThings CLI)

```bash
smartthings edge:drivers:package drivers/Unofficial/ergomotion-bed
smartthings edge:channels:assign        # pick your channel and the driver
smartthings edge:drivers:install        # pick your hub
```

The hub can take a few minutes to pick up a new version. Run `smartthings edge:drivers:installed` to confirm which version is installed.

---

## Setup

### 1. Add the device

In the SmartThings app: **+ → Add device → Scan for nearby devices**. A device named **Ergomotion Bed …** is created. Each scan adds one bed, so for a split base, scan once for each side.

### 2. Enter the bed's IP address

Open the device → **⋮ → Settings** → **Bed IP Address**, and enter the address of the bed's Wi‑Fi module. Within a few seconds the switch turns on, and the sliders and cards fill in with the bed's current state.

If you don't know the address, look for the bed's Wi‑Fi module in your router's client list. It's the device with port 5000 open.

### 3. Calibrate head and foot (once)

The controller reports head and foot position as a raw count, but not its maximum. The driver learns the maximum the first time each motor reaches the top:

1. Set **Head Position** to **100 %**. The head rises until the position stops changing, and that point is saved as 100 %.
2. Do the same for **Foot Position**.

Until you calibrate, the percentages are based on a guessed maximum. If you already know your bed's raw maximums, you can enter them in Settings instead (see [Settings](#settings)).

### 4. Set the lumbar travel time

Time how long your lumbar takes to go from fully down to fully up, and enter that number in **Lumbar full travel (seconds)** (default 15). The first lumbar move after installing lowers the lumbar all the way, so the estimate starts from a known position.

### 5. Teach it your presets

Press **Preset**, **Preset 2** and **Zero gravity** once each on the Motion card, and let the bed finish moving each time. After each one settles (see **Preset settle time**), the driver saves where the bed ended up. From then on the Motion card shows that mode whenever the bed is in that position. **Flat** is always recognized at head 0 / foot 0.

If you reprogram a memory button on the remote, use **Relearn preset position** in Settings (see below).

---

## Controls

### Bed (main card)

| Control | What it does |
|---|---|
| **Motion card: Head / Foot ▲▼** | Hold to move, release to stop. Stops automatically at the end of travel or after 50 s |
| **Motion card: Elevation ▲▼** | Hold to move the **lumbar** (this bed has no whole-base lift, so Elevation is used for the lumbar). Updates the lumbar estimate |
| **Motion card: Preset / Preset 2 / Zero gravity / Flat** | Memory A / Memory B / Zero‑G / Flat on the remote. The card shows the current mode, or nothing highlighted when the bed isn't at a known preset |
| **Massage card: power** | Off: turns all massage off. On: restarts the last intensities used (Low on head and foot the first time) |
| **Massage card: intensity** | Head, foot or whole bed: Off / Low / Medium / High |
| **Massage card: Time** | Off / 10 / 20 / 30 minutes. Changing the time while a massage is running restarts it with the new time at the same intensities, the same way the remote works |
| **Massage card: Ends at** | When the current massage will stop, based on the countdown the bed reports |
| **Switch** | Shows whether the bed is online. Tapping it only triggers a connection check, and the switch returns to the real state |

### Other controls

| Control | What it does |
|---|---|
| **Head Position** | 0–100 %, the bed's real position. Setting it drives the head there and stops |
| **Foot Position** | Same for the foot |
| **Lumbar Position** | 0–100 %, estimated from motor run time. Setting 0 % or 100 % runs the motor a little past full travel to correct any drift |
| **Vibration Pattern** | 1 = slow pulses, 2 = faster, 3 = fastest, 4 = continuous. (0 also selects continuous, since the bed has no "off" pattern) |

---

## Settings

| Setting | Default | Description |
|---|---|---|
| **Bed IP Address** | — | IP address of the bed's Wi‑Fi module |
| **Lumbar full travel (seconds)** | 15 | Time for the lumbar to go from fully down to fully up. The lumbar slider is only as accurate as this number |
| **Preset settle time (seconds)** | 50 | How long to wait after a preset before reading the position. Reading too early would stop the bed partway (see [How it works](#how-it-works)), so keep this at least as long as your slowest preset takes |
| **Head max travel (raw, 0 = auto)** | 0 | Leave at 0 to learn it by setting the head to 100 %, or enter a raw value yourself |
| **Foot max travel (raw, 0 = auto)** | 0 | Same for the foot |
| **Relearn preset position** | No | Pick Memory A, Memory B, Zero‑G or All presets to forget their saved positions; the next press of that preset saves its position again. Set it back to **No** afterwards, because picking the same option twice in a row has no effect |

---

## How it works

- **Commands** are 14-byte frames that mirror the hand remote's buttons. Motors run only while frames keep arriving, so the driver resends a movement frame about every 150 ms for as long as the bed should move. That's how hold-to-move and the sliders work.
- **Status** comes back as a 27-byte frame, but only in reply to a command. The bed never sends status on its own. To read the status, the driver sends the "no buttons pressed" frame (the same frame as STOP). That frame stops any motor or preset movement, but it does **not** stop a running massage.
- **Presets** move the bed on their own after a single press. Because reading the status would stop a preset partway, the driver waits for the **Preset settle time** before reading the final position.
- **While a massage is running**, the driver reads the status every 60 s, so the Massage card updates when the timer runs out.
- **Online check:** every 5 minutes (every minute while offline) the driver opens a connection to the bed and closes it without sending anything, which doesn't affect the bed. Every normal command also counts as a successful check.
- **Massage intensity and the timer** are set by pressing the bed's own up/down and Timer buttons until the status shows the requested value.

---

## Automation examples

- **Bedtime**: at 10:30 pm, set Motion mode → **Preset** (your reading position) and turn the massage on.
- **Wake up**: at 6:45 am, set Motion mode → **Flat**.
- **Snoring helper**: when a sound sensor or button is triggered, set **Head Position** to 15 %.
- **Alert**: if the bed goes **offline** (switch off) for more than 10 minutes, send a notification.

---

## Troubleshooting

Run `smartthings edge:drivers:logcat`, choose **Ergomotion Bed Driver**, and refresh the device. Each status read logs a line like:

```
[Bed] head=3787 foot=0 headMas=0 footMas=0 timer=1 remaining=600s
```

| Symptom | Likely cause |
|---|---|
| Switch stays off / device offline | Wrong IP, the IP changed (set a DHCP reservation), or the hub and bed are on different VLANs/subnets |
| `Connection to …:5000 failed` | Same as above, or the Wi‑Fi module is asleep or powered off |
| Head/foot percentages look wrong | Not calibrated yet: set each one to 100 % once, or enter the raw maximums in Settings |
| Lumbar slider drifts | Set **Lumbar full travel** to the real time, then set 0 % or 100 % to re-sync |
| Preset not highlighted on the Motion card | That preset hasn't been learned yet (press it once and wait), or the remote button was reprogrammed (use **Relearn preset position**) |
| Learned preset position is partway | **Preset settle time** is too short: raise it, then relearn that preset |
| A new control shows no value after an update | Pull down to refresh the device. Refresh resends every value |
| `capability definition not available on this hub` | Your hub doesn't have that capability yet (the massage capabilities are new). That control is skipped, and everything else keeps working |

---

## Limitations

- **The massage capabilities are SmartThings "proposed" capabilities** (`massageIntensityControl`, `massageIntensityChange`, `massageOperating`, `massageOperatingState`, `massageTimeControl`, `massageTimeChange`). SmartThings may still change them, and how the app shows them may change too.
- **Lumbar position is an estimate.** The bed doesn't report it.
- **Head and foot positions are the controller's own estimates** (it counts motor run time). They're consistent, but they're not an exact angle.
- **Reading the status stops any movement in progress.** If you're moving the bed with the hand remote at the moment the driver reads the status (a refresh, or the 60-second massage check), the movement stops. Release the button and press it again.
- **Status isn't instant for remote changes.** The bed only reports when asked, so a change made with the hand remote appears on the next refresh, command or periodic check.
- **The timer and massage are linked the same way as on the remote.** Changing the timer while a massage is running briefly turns the massage off and back on.
- **Vibration pattern has no "off"**: it only cycles between the four patterns.
- **Matching the Motion mode ignores the lumbar**, since its position isn't reported.

---

## Protocol reference

Decoded from this bed; values are little-endian.

**Command frame (14 bytes):** `AA 03 00 0A 00 | 04 01 b1 b2 b3 b4 crc | outer 55`

- `crc = ~(0x04 + 0x01 + b1 + b2 + b3 + b4) & 0xFF`
- `outer = ~(sum of bytes 1–12) & 0xFF`
- `b1`: `01` head up, `02` head down, `04` foot up, `08` foot down, `40` lumbar up, `80` lumbar down
- `b2`: `01` vibration, `02` timer / all off, `04` foot massage up, `08` head massage up, `10` Zero‑G, `20` Memory A, `40` Memory B
- `b3`: `80` head massage down
- `b4`: `01` foot massage down, `08` Flat
- All zero = STOP / status poll

**Status frame (27 bytes):** `AA 83 00 17 xx | 0C 01 …`

| Byte(s) | Meaning |
|---|---|
| 7–8 | Head position |
| 9–10 | Foot position |
| 11 | High nibble: vibration pattern 1–4. Low nibble: head massage 0 / 1 / 3 / 6 |
| 12 | Foot massage 0 / 1 / 3 / 6 |
| 13–15 | Massage time remaining, 1/100 s |
| 17 | Motor-active flag (`01` head/foot, `08` lumbar) |
| 18 | Timer setting 1 / 2 / 3 = 10 / 20 / 30 min |
| 19 | `~sum(bytes 5–18) & 0xFF` |
| 25 | `~sum(bytes 1–24) & 0xFF` |

---

## File layout

```
ergomotion-bed/
├── config.yml                  driver name and LAN permissions
├── profiles/ergomotion-bed.yaml  components, capabilities and settings
├── src/init.lua                driver code
├── README.md                   this file
└── FORUM_POST.md               SmartThings Community announcement
```

---

## Credits and references

- Keeson MC120PR / MC122SP UART protocol breakdown on the Home Assistant community: <https://community.home-assistant.io/t/guide-ergomotion-serta-tempur-ghostbed-askona-adjustable-beds-keeson-mc120pr-mc122sp-uart-protocol-full-breakdown/1018253>
- AlexxIT's Ergomotion integration for Home Assistant (Bluetooth): <https://github.com/alexxit/ergomotion>

This is an unofficial community driver, not affiliated with Ergomotion, Keeson or SmartThings. Use it at your own risk. Moving furniture can pinch, so make sure nothing and nobody is in the way before running automations.
