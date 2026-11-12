# Samsung Audio Group – all your Samsung multiroom speakers in one SmartThings device

An unofficial SmartThings Edge driver for Samsung Wi-Fi multiroom speakers and soundbars (the ones
controlled by the **Samsung Multiroom** app). It runs entirely on your SmartThings hub over your
local network, and puts **every speaker into one SmartThings device**. 12 speakers count as one
device, not 12.

It's a rebuild of SmartThings' own `samsung-audio` driver, which kept showing speakers as offline.

* **Driver channel (install link):** https://callaway.smartthings.com/channels/2a034761-9a9f-456c-bb58-f65efb66c12a
* **Source code:** https://github.com/Felixowns/SmartThingsEdgeDrivers-FDP/tree/main/drivers/Unofficial/samsung-audio-group

---

## What you get

**One device ("Samsung Speakers") with:**

* **All Speakers** (the first section): power, play / pause / stop, next / previous, volume, mute and
  announcements sent to every speaker at once. It shows *"12 of 12 speakers online"* and what's
  playing where (*"Playing: Office Left Speaker (song title)"*).
* **One section per speaker** (Speaker 1, Speaker 2, …, up to 16), each with:
  * Power, play / pause / stop, next / previous track
  * Volume and mute
  * Now playing: song title, artist, album, track length. When idle it shows the speaker's
    name, IP address and model instead.
  * Input source (Wi-Fi, Bluetooth; soundbars also HDMI, Optical, Aux, USB)
  * Shuffle, repeat and song progress (see the limitations below)
  * EQ preset (None, Pop, Jazz, Classic)

**It also:**

* Finds your speakers automatically, and keeps finding new ones (re-scans every 30 minutes).
* Works with Spotify and other streaming apps, showing the song, artist, album and length.
* Understands **Multiroom groups**. Speakers grouped in the Samsung Multiroom app show the group
  leader's song (*"Spotify · grouped with Office Left Speaker"*). Play / pause / next pressed on any
  speaker in the group controls the group.
* Updates the speaker you just controlled within 1.5 to 5 seconds, without waiting for the
  regular status check.
* Follows a speaker when your router gives it a new IP address.
* Lists speakers alphabetically by the names you gave them in the Samsung Multiroom app.

---

## Speakers it has been tested with

| Model as reported by the speaker | Type |
|---|---|
| SPK-WAM550 | Wi-Fi speaker |
| SPK-WAM1500 | Wi-Fi speaker |
| SPK-WAM3500 | Wi-Fi speaker |
| SPK-WAM750 / HW-MS550 / HW-MS750 | Soundbar (reports either model name) |

Any Samsung speaker that works with the **Samsung Multiroom** app should work. The driver detects
speakers by whether they answer Samsung's speaker API (port 55001), not by a fixed model list.
Samsung TVs and newer SmartThings-native soundbars that don't use the Multiroom app are ignored.

---

## Requirements

* A SmartThings hub that runs Edge drivers (v2, v3, Aeotec, or a Station).
* The hub and the speakers on the **same network / subnet**.
* The speakers set up in the Samsung Multiroom app and connected to Wi-Fi.
* Recommended: give each speaker a **reserved (static) IP address** in your router. The driver
  follows IP changes, but fixed addresses make everything faster and more reliable.

---

## Installation

### 1. Install the driver from the channel

1. Open the channel link: https://callaway.smartthings.com/channels/2a034761-9a9f-456c-bb58-f65efb66c12a
2. Sign in with your Samsung account, **accept** the invitation, and **enroll** your hub.
3. Go to **Available Drivers** and install **Samsung Audio Group**.

It can take a few minutes for the driver to reach your hub.

### 2. If you used SmartThings' built-in Samsung Audio driver before

The built-in driver creates one device per speaker, and those will conflict with this one.

1. In the SmartThings app, **delete each speaker device** made by the old driver.
2. Optional: uninstall the old driver from the hub so it doesn't re-create them. You can remove it
   from the hub's driver list in the SmartThings app, or use the CLI:
   `smartthings edge:drivers:uninstall`

### 3. Add the speakers

1. SmartThings app → **+** → **Add device** → **Scan nearby**.
2. A device called **Samsung Speakers** appears. It's created even if no speaker answers right
   away, so you can always reach its settings.
3. Open it. Within about a minute it switches to a layout with one section per speaker, and the
   All Speakers section shows *"N of N speakers online"*.

If some speakers are missing, see **Troubleshooting** below.

---

## Settings

Open the Samsung Speakers device → **⋮** → **Settings**.

| Setting | What it does | Default |
|---|---|---|
| **Status refresh interval (seconds)** | How often every speaker is checked (15–600). Changes made outside SmartThings, like in the Spotify app, show up on the next check. | 60 |
| **Speaker IPs (always included)** | Comma-separated IP addresses that are always checked, even if network discovery misses them. Use this if a speaker never shows up by itself. Example: `192.168.1.40, 192.168.1.41` | none |
| **Excluded IPs** | Comma-separated IP addresses to ignore. Those speakers are removed right away and never added back, even if they're also listed above. | none |
| **Rebuild speaker list** | Flip this switch (either way) to forget all speakers and search again. Use it after replacing or renaming speakers. | off |

**Tip:** whenever the driver's speaker list changes, it writes a line like
`speaker list (12): 192.168.1.36, 192.168.1.29, …` to the driver log. Paste that into
**Speaker IPs** to pin all your speakers.

---

## Using it

### Which section is which speaker?

Sections are numbered in **alphabetical order of the speaker names** from the Samsung Multiroom
app (Speaker 1 = first name alphabetically). Each section's *Now playing* area shows that speaker's
real name and IP whenever it's not playing.

SmartThings doesn't let a driver rename the section headers, so they stay "Speaker 1", "Speaker 2"
and so on. If you add a speaker whose name sorts into the middle, the speakers after it move down
one number.

### All Speakers vs. a single speaker

* Commands on **All Speakers** go to every speaker that's online.
* Commands on a **speaker section** go to that speaker only, except play / pause / next /
  previous / shuffle / repeat on a grouped speaker, which go to the group leader (see below).
* **Volume and mute** always apply to the individual speaker, even inside a group.

### Multiroom groups

Group speakers in the **Samsung Multiroom** app as usual. The driver detects the group by itself:

* The **leader** shows what's playing.
* The other speakers in the group show the leader's song, with *"· grouped with"* and the leader's
  name.
* Play / pause / next / previous on any speaker in the group controls the whole group.
* On **All Speakers**, the group gets each command once (so *next* doesn't skip two songs).

Ungroup in the Multiroom app and each speaker shows its own status again at the next check.

### Spotify and other streaming apps

Song title, artist, album, track length and play / pause state are read from the speaker while
Spotify (or another streaming app) plays. Play / pause / next / previous from SmartThings control
the stream.

### EQ preset

Each speaker section has an **EQ preset** list: None, Pop, Jazz, Classic. The preset is set on that
speaker only.

### Automations

Everything above can be used in SmartThings Routines (e.g. *"at 7 am, set Kitchen speaker volume
to 20 and play"*). In a Routine you pick the device **Samsung Speakers** and then the speaker
section.

---

## Known limitations

| Limitation | Why |
|---|---|
| **Announcements / text-to-speech don't play** | SmartThings sends announcement audio as an HTTPS link. These speakers can only play plain HTTP links and reject it. The attempt shows in the driver log. |
| **No album art in the SmartThings app** | The driver sends the album-art link, but the SmartThings app's *Now playing* display is text-only for this kind of device. Third-party dashboards that read SmartThings data, like SharpTools, can show it. |
| **Song progress stays at 00:00 during Spotify** | The speakers don't report the playback position for streaming apps. |
| **Shuffle / repeat don't reflect Spotify** | The speakers only report and change shuffle / repeat for their built-in player (phone or USB music), not for streaming apps. Use the Spotify app for those. |
| **Section headers can't be renamed** | SmartThings doesn't allow it for a driver. Use the speaker name shown in each section. |
| **EQ presets are None / Pop / Jazz / Classic only** | That's the list the speakers report. Custom presets made in the Multiroom app (e.g. "Custom 1") show their name but can't be picked from SmartThings. |
| **No 7-band EQ sliders** | They were tried: seven sliders on each of 12 speakers made the SmartThings device page hang on "Loading…". |
| **Up to 16 speakers per hub** | The driver has layouts for 1 to 16 speakers. |
| **"On / off" means standby** | It's the speaker's standby mode. A speaker in standby still answers on the network. |

---

## Troubleshooting

To see what the driver is doing, use the SmartThings CLI:
`smartthings edge:drivers:logcat`, then pick the **Samsung Audio Group** driver.

| Problem | What to do |
|---|---|
| **No speakers found / "No speakers found yet"** | The hub didn't get any answers to the network search. This is common when the router blocks multicast (IGMP snooping, "AP isolation", guest network, separate VLAN). The driver then tries every address on the hub's subnet. If speakers are on another subnet, enter their IPs in **Speaker IPs**. |
| **Some speakers missing** | Wait for the next scan (every 30 minutes), tap **Refresh** on All Speakers, or enter the missing IPs in **Speaker IPs**. |
| **A speaker shows "(unreachable)"** | It didn't answer 3 checks in a row: it's off, unplugged, or on a new IP. The driver re-scans automatically to find it again. Reserving its IP in the router prevents this. |
| **A speaker appears twice** | Flip **Rebuild speaker list**. |
| **A device you don't want (e.g. a PC or TV) shows up as a speaker** | Add its IP to **Excluded IPs**. |
| **"Not all devices have updated their status"** in the app | Tap **Refresh** on All Speakers once. If it keeps happening, check the log for speakers that time out. |
| **Some controls show "–"** | That value hasn't reached the app yet. Tap **Refresh**. Shuffle / repeat stay "–" until the speaker reports them (see Known limitations). |
| **Soundbar shows "doesn't answer play status; checking it less often"** in the log | Normal. Soundbars don't answer that request; the driver checks them a different way. |
| **Timeouts in the log while Spotify plays** | Normal. The speaker doesn't support shuffle / repeat / progress requests during streaming; after two misses the driver only retries them every 20th check. |
| **Device page stuck on "Loading…"** | Force-close and reopen the SmartThings app. If it continues, post the output of `smartthings devices:presentation <device id>`. |

---

## For developers: building from source

The source is in
https://github.com/Felixowns/SmartThingsEdgeDrivers-FDP/tree/main/drivers/Unofficial/samsung-audio-group

| Path | What it is |
|---|---|
| `src/init.lua` | Driver: discovery, polling, groups, commands, event sending |
| `src/command.lua` | Speaker API requests (`/UIC` and `/CPM` on port 55001) |
| `src/disco.lua` | SSDP discovery and subnet sweep |
| `src/custom_caps.lua` | Generated: which custom capability namespace the driver uses |
| `profiles/samsung-audio-group-1…16.yml` | Generated: one layout per speaker count |
| `capabilities/eqPreset.json` | EQ preset capability definition |
| `capabilities/eqPreset.presentation.json` | How the EQ preset list looks in the app |
| `capabilities/namespace.txt` | The namespace the profiles were built for |
| `make_profiles.py` | Regenerates the profiles and `src/custom_caps.lua` |

### The EQ preset capability (one-time, per SmartThings account)

The EQ preset is a **custom capability**. The published driver uses `worldinside12377.eqPreset`. If
you install from the channel above, you don't need to do anything. If you **package the driver
under your own SmartThings account**, either:

**a) Build without it:**

```
python make_profiles.py --no-eq
```

**b) Create your own copy** (run from the `samsung-audio-group` folder):

```
smartthings capabilities:create -i capabilities/eqPreset.json
```

This prints an id like `yournamespace12345.eqPreset`. The part before the dot is your account's
**namespace** (SmartThings assigns it on your first custom capability). Then:

```
smartthings capabilities:presentation:create yournamespace12345.eqPreset -i capabilities/eqPreset.presentation.json
python make_profiles.py yournamespace12345
```

Notes from setting it up:

* `capabilities:presentation:create` takes **only the id, no version number**. Adding `1` after the
  id makes the current CLI crash with `unknownArguments` / `isAxiosError`.
* Attribute and command names can't contain digits. SmartThings rejects them with
  `PatternError … ^[[a-z]*([A-Z][a-z]*)*]{1,36}$`.
* A list in a presentation needs its choices written out. An empty `alternatives` list is
  rejected with `must not be null at detailView[].list.state.alternatives`, so the preset names
  are fixed in `eqPreset.presentation.json`. To add one, edit that file and run
  `smartthings capabilities:presentation:update <namespace>.eqPreset -i capabilities/eqPreset.presentation.json`.
  The driver matches preset names ignoring capitalization (soundbars report `NONE`, `POP`, …).
* New capabilities can take a few minutes to appear in the app.

### Package and install

```
smartthings edge:drivers:package drivers/Unofficial/samsung-audio-group
smartthings edge:channels:assign
smartthings edge:drivers:install
```

To share your channel: `smartthings edge:channels:invites:create`

### How it works (short version)

* **Discovery:** SSDP search for `urn:samsung.com:device:RemoteControlReceiver:1` and
  `urn:schemas-upnp-org:device:MediaRenderer:1`, sent 3 times. Every answer is verified by asking
  the speaker its name on port 55001. If nothing answers, every address in the hub's /24 is tried
  on port 55001. Speakers are identified by the MAC in their UPnP UDN (or by IP when there's no
  description).
* **Status:** each speaker is polled in parallel. `UIC GetPlayStatus` gives the source and play
  state for the built-in player. When the source is a streaming app (submode `cp`), the driver asks
  `CPM GetPlayStatus` / `CPM GetRadioInfo` for the real state and song info. Note that `/CPM`
  replies are wrapped in `<CPM>`, not `<UIC>`. Groups come from `UIC GetAcmMode` (mode `aasync`
  plus the leader's MAC).
* **Reachability:** a speaker counts as online if it answers at all. It's unreachable after 3
  missed checks, and the device is only offline when every speaker is. Requests time out after
  4 s. A request a speaker misses twice in a row is only retried every 20th check.
* **Events:** only changed values are sent to SmartThings. Re-sending everything every minute
  got the device throttled and the app stopped updating. After a command, the targeted speaker's
  state is always re-sent, because the app waits for it. *Refresh* re-sends everything.
* **Layouts:** profiles `samsung-audio-group-1` to `-16`. The driver switches profile when the
  number of speakers changes.

Speaker API commands used: `GetSpkName`, `GetPlayStatus`, `GetVolume`/`SetVolume`,
`GetMute`/`SetMute`, `SetPlaybackControl`, `SetTrickMode`, `SetStandbyMode`, `GetFunc`/`SetFunc`,
`GetAcmMode`, `GetMusicInfo`, `GetShuffleMode`/`SetShuffleMode`, `GetRepeatMode`/`SetRepeatMode`,
`GetCurrentPlayTime`, `Get7BandEQList`, `GetCurrentEQMode`, `Set7bandEQMode`, `SetUrlPlayback`;
CPM: `GetPlayStatus`, `GetRadioInfo`, `SetPlaybackControl`, `SetSkipCurrentTrack`,
`SetPreviousTrack`.

---

## Credits and license

Based on SmartThings' `samsung-audio` Edge driver
(https://github.com/SmartThingsCommunity/SmartThingsEdgeDrivers), Apache License 2.0. This is an
unofficial community driver, not made or supported by Samsung or SmartThings.

Questions and bug reports are welcome. Please include a few lines of
`smartthings edge:drivers:logcat` output.
