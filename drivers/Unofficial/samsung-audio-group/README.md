# Samsung Audio Group (Unofficial)

Rebuild of `drivers/SmartThings/samsung-audio` that puts **every Samsung multiroom
speaker on the network into one SmartThings device** ("Samsung Speakers").

| Component | What it does |
|-----------|--------------|
| `main` (All Speakers) | Power / play / pause / volume / mute / TTS sent to every reachable speaker. Shows "N of M speakers online" and what's playing. |
| `speaker1` … `speaker16` | Each individual speaker. Track-data card shows the speaker's name (or the current track). |

The profile (`samsung-audio-group-N`) is switched automatically as speakers are found.

## Fixes vs. the stock driver (speakers showing offline)

* Stock driver marked a speaker **offline whenever `GetPlayStatus` had no `playstatus` field**
  (standby, TV/optical input, group follower). Now any valid reply = reachable.
* One missed poll no longer = offline. A speaker is "unreachable" after 3 failed polls, and the
  whole device only goes offline when *every* speaker is unreachable.
* HTTP requests have a 4 s timeout (stock used the 60 s default).
* `init` no longer loops forever on SSDP; discovery runs in the background.
* Speakers are verified by answering the speaker API on port 55001 instead of a hardcoded model
  list, so newer models are picked up.
* If a speaker stops answering, the driver re-runs discovery (max every 5 min) to catch DHCP IP
  changes; a full re-scan also runs every 30 min to add new speakers.

## Settings (device preferences)

* **Status refresh interval** – seconds between polls (default 60).
* **Speaker IPs (always included)** – comma-separated IPs that are always checked, even when SSDP
  misses them. The driver logs `speaker list (N): ip, ip, ...` whenever its saved list changes –
  paste that here to pin your speakers. (SmartThings doesn't let a driver write its own settings,
  so this field can't fill itself in.) Reserving the IPs in your router is recommended.
* **Excluded IPs** – comma-separated IPs to ignore. Matching speakers are removed from the saved
  list right away and never re-added by discovery (exclusion wins over "Speaker IPs").
* **Rebuild speaker list** – flip to forget all speakers and search again.

## Install

**First time in a SmartThings account:** create the EQ preset capability first (see
[EQ preset – one-time setup](#eq-preset-custom-capability--one-time-setup)); packaging fails while
the profiles reference a capability the account doesn't have.

```
smartthings edge:drivers:package drivers/Unofficial/samsung-audio-group
smartthings edge:channels:assign
smartthings edge:drivers:install
```
Delete the speaker devices created by the old SamsungAudio driver (and uninstall it from the
hub) so they don't get re-created, then *Add device → Scan nearby*.

## Speaker order and names

Speakers are kept in alphabetical order. The saved list only grows: newly discovered speakers are
added, existing ones stay (IP is updated if DHCP moves one). "Rebuild speaker list" clears it.

Component headers are "Speaker 1" … "Speaker N" (alphabetical order). An Edge driver can't rename
them itself; whenever the list changes the driver logs
`component rename body for device <id>: {"components":[{"id":"speaker1","label":"..."}, ...]}`
which can be applied from outside the driver (app or SmartThings API). Adding a speaker that sorts
into the middle shifts the ones after it, so re-apply the labels after the list changes.

Each speaker card also shows the speaker's name and IP on its track-data card.

## Streaming (Spotify etc.) and groups

* Streaming apps report through the speaker's content-provider player (`/CPM?cmd=…`, replies wrapped
  in `<CPM>`), not `GetPlayStatus`. The driver reads play state, title, artist, album, album art
  (Spotify `scdn.co` links are switched to `https://` so the app loads them) and track length there.
* Speakers grouped in the Samsung Multiroom app report group mode `aasync` plus the leader's MAC
  (`GetAcmMode`). Followers show the leader's track ("· grouped with …") and their
  play/pause/next/previous/shuffle/repeat go to the leader. On *All Speakers*, followers are
  skipped so the leader isn't sent a command twice.
* After a command the affected speaker (and its group) is re-checked 1.5 s later (next/previous
  also at 5 s) so the card updates without waiting for the poll.
* Only changed values are sent to SmartThings (re-sending everything every poll got the device
  throttled). Exceptions: after any command the targeted speaker's state is always re-sent (the app
  shows "not all devices have updated their status" if a command produces no event), and *Refresh*
  / the 30-minute re-scan re-send everything.
* Speakers are polled in parallel, so slow soundbars don't hold up the others and *Refresh*
  finishes in a few seconds; the network re-scan runs after the refresh, not before.

## Announcements (known limitation)

SmartThings sends TTS as an HTTPS link; these older speakers can only fetch plain HTTP and answer
`ng`. Announcements are logged (`announcement -> …`) but don't play yet.

## Per-speaker controls

Each speaker section shows input source, shuffle, repeat and song progress (standard capabilities).
Shuffle / repeat / next / previous on a grouped follower are sent to the group leader.
Input sources offered: soundbars (HW-…) Wi-Fi, Bluetooth, HDMI, Optical, Aux, USB; WAM speakers
Wi-Fi and Bluetooth.

## EQ preset (custom capability) – one-time setup

Each speaker section has an **EQ preset** list (None / Pop / Jazz / Classic). It uses a custom
capability that lives in a SmartThings developer account, so it has to be created once per account
with the SmartThings CLI before the driver can be packaged.

| File | What it is |
|------|------------|
| `capabilities/eqPreset.json` | capability definition (`preset`, `supportedPresets`, command `setPreset`) |
| `capabilities/eqPreset.presentation.json` | how the preset list looks in the app |
| `capabilities/namespace.txt` | the account namespace the profiles were built with |
| `make_profiles.py` | rebuilds `profiles/*.yml` and `src/custom_caps.lua` for a namespace |

### Steps (run from this driver folder)

1. Create the capability:

   ```
   smartthings capabilities:create -i capabilities/eqPreset.json
   ```

   It prints an `"id"` such as `worldinside12377.eqPreset`. The part before the dot is the
   account's **namespace** (assigned by SmartThings on the first capability you create).

2. Create the app layout. **No version number** – the current CLI only takes the id
   (`smartthings capabilities:presentation:create <id> 1 …` fails with an `unknownArguments` /
   `isAxiosError` crash):

   ```
   smartthings capabilities:presentation:create <namespace>.eqPreset -i capabilities\eqPreset.presentation.json
   ```

3. Build the profiles for that namespace, then package and install as usual:

   ```
   python make_profiles.py <namespace>
   smartthings edge:drivers:package
   smartthings edge:drivers:install
   ```

   `make_profiles.py` remembers the namespace in `capabilities/namespace.txt`; later runs can
   omit it. `--no-eq` builds the profiles without any custom capability (the EQ code then stays off).

New capabilities can take a few minutes to appear in the app; reopen the device if the EQ preset is
missing at first.

### This repo's current setup

The capability was created in account namespace **`worldinside12377`** and the profiles in
`profiles/` are already built for it. Someone using a different SmartThings account must do steps
1–3 with their own namespace (packaging fails while a profile references a capability the account
doesn't have).

### Things learned while creating it

* **A list presentation needs its options written out.** An empty `alternatives` list (meant to be
  filled from the speaker at runtime) was rejected with
  `must not be null at detailView[].list.state.alternatives`. The preset names are therefore fixed
  in `eqPreset.presentation.json`: **None, Pop, Jazz, Classic** – the list a WAM1500 returns for
  `/UIC?cmd=<name>Get7BandEQList</name>`. If a speaker reports other presets, add them there and
  update the presentation (`smartthings capabilities:presentation:update <namespace>.eqPreset -i …`);
  the driver matches presets by name.
* Attribute and command names can't contain digits (`PatternError … ^[[a-z]*([A-Z][a-z]*)*]{1,36}$`).
* **A 7-band EQ (seven sliders per speaker) was tried and removed.** With 12 speakers that added
  84 sliders and the SmartThings app's device page hung on "Loading…" (the device presentation
  itself was valid). Don't add per-speaker sliders back to this one-device layout.
* Speaker-side EQ commands used by the driver: `Get7BandEQList` (preset list), `GetCurrentEQMode`
  (reply: `presetindex`, `presetname`, …), `Set7bandEQMode` (select a preset).
