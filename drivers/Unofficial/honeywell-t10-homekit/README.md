# Honeywell T10 (HomeKit local)

SmartThings Edge driver for the **Honeywell Home (Resideo) T10 / T10+ Pro and T9** thermostat. The hub pairs with the thermostat directly over **HomeKit** on your LAN: no Resideo cloud, no Apple device, no bridge computer.

Based on [Honeywell T6 (HomeKit local)](https://github.com/Stoeckie/smartthings-honeywell-t6-homekit-local) by Stoeckie (Apache 2.0). The pure-Lua HomeKit controller (SRP pair setup, Ed25519, X25519, ChaCha20-Poly1305, encrypted sessions and events) is used unchanged; the thermostat mapping and driver were rewritten for the T10. See `NOTICE`.

## What you get

* Temperature, humidity
* Mode: off / heat / cool / auto (whatever the thermostat reports as valid)
* Heating and cooling setpoints. In heat or cool mode they map to HomeKit *Target Temperature*; in auto to the *Heating/Cooling Threshold* characteristics
* Operating state: what the system is doing right now, from HomeKit *Current Heating Cooling State*: idle / heating / cooling, plus "fan only" when the fan runs on its own (only if the fan is exposed). HomeKit does not report stages or "pending"
* Fan mode Auto / On / Circulate, **only if** the thermostat exposes a Fan service over HomeKit (the driver switches to the `honeywell-t10-fan` profile then). HomeKit itself only knows auto and on, so Circulate is timed by the hub: the fan runs for *Circulate minutes per hour* (default 20) and is back on auto the rest of the hour. SmartThings has no "Off" fan mode; Auto is the fan-off position (it only runs with heating or cooling)
* **Humidity target** (HomeKit *Target Relative Humidity*) as a 0-100 % slider in its own "Humidity target" section
* **Filter 1 / Filter 2** status (normal / replace) from HomeKit *Filter Maintenance*, each with a button that resets the reminder after a filter change
* **RedLINK room sensors** as their own devices (temperature, humidity, occupancy → motion, battery), if the thermostat shares them over HomeKit
* Live push updates, a fallback poll after 15 minutes of silence, automatic reconnect
* °F or °C display (setting). HomeKit always uses °C internally; setpoints are converted and rounded to the thermostat's step

## Profiles

The driver picks the profile from what the thermostat exposes over HomeKit (T9 and T10 report the same model name):

| Profile | When | Extra sections |
|---|---|---|
| `honeywell-t10` | humidity target exposed (T10 / T10+ Pro) | Humidity target, Filter 1, Filter 2 |
| `honeywell-t10-fan` | a fan service is exposed | as above plus fan mode |
| `honeywell-t9-filter` | no humidity target, filter reminder exposed (T9) | Filter |
| `honeywell-t9` | no humidity target, no filter | none |

All of them have temperature, humidity, operating state, mode and heating / cooling setpoints. Room sensors (RCHTSENSOR on the T9, RedLINK on the T10) become their own devices either way.

## Setup

1. Package and install to your hub/channel:
   `smartthings edge:drivers:package drivers/Unofficial/honeywell-t10-homekit`
2. The thermostat must **not** be paired with Apple Home (HomeKit accepts one owner controller). Remove it from Apple Home first, or reset HomeKit on the thermostat.
3. On the thermostat: **Menu > Connect HomeKit**. It shows a QR code and an 8-digit setup code.
4. SmartThings app: **Add device > Scan nearby**. A "Honeywell T10" device appears.
5. Open the device > Settings > **HomeKit code**, type the 8 digits. Pairing takes 1 to 2 minutes (3072-bit SRP in Lua on the hub).
6. Room sensor devices are created after the first session comes up.

If the code is entered before the hub starts pairing, it is used directly. If the thermostat makes a new code for every attempt (as the T6 does), the hub waits up to 5 minutes for you to type the one now on the screen. After 5 failed attempts in a row it stops until you enter a code again.

## Settings

| Setting | Meaning |
|---|---|
| HomeKit code | the 8-digit code from Menu > Connect HomeKit, needed once |
| Temperature unit | F (default) or C for what SmartThings shows |
| Record interval (minutes) | temperature and humidity are recorded at least this often even without a change (default 5; 0 = only on change) |
| Room sensor devices | create child devices for RedLINK sensors (default on) |
| Circulate minutes per hour | fan Circulate: fan minutes per hour, 5 to 55 (default 20; fan profile only) |
| Thermostat IP / HomeKit port | `auto` / `0` (mDNS), or fixed values if discovery fails |
| Remove pairing | unpair the hub from the thermostat |

## First run: check the mapping

The T10 mapping is built from the HomeKit spec and has not been confirmed on a real T10 yet. On every driver start the log prints the whole HomeKit tree once:

```
smartthings edge:drivers:logcat <driverId> --hub-address <hub-ip>
[t10] tree aid 1: 3E{...} 4A{F#10=0 33#11=3 11#12=22.5 35#13=21 D#14=25.5 12#15=20 10#16=41 36#17=1} ...
[t10] tree aid 2: 3E{...} 8A{11#9=20.5} 86{71#11=0} 96{68#13=80 79#14=0}
[t10] Resideo THX321WF (fw ...), modes off/heat/cool/auto, fan none, 2 room sensor(s)
```

Service codes: `4A` thermostat, `B7`/`40` fan, `8A` temperature, `82` humidity, `86` occupancy, `96` battery. If something is missing or mapped wrongly, those lines are what's needed to fix it.

You can also pair from a PC (needs `pip install lupa`) to dump `tools/accessories.json` and then unpair, before involving the hub:

```
python3 tools/pair_test.py <thermostat-ip> <port> <8-digit-code>
```

## Troubleshooting

* **HomeKit error 2**: wrong code.
* **HomeKit error 6**: already paired with another controller (Apple Home), or locked after too many tries. Remove it there / reset HomeKit and wait a few minutes.
* **Not found by Scan nearby**: thermostat and hub must be on the same subnet. A device is created anyway; set IP and port by hand (the port is in the mDNS `_hap._tcp` record, e.g. from a Bonjour browser app).
* Give the thermostat a DHCP reservation; the driver also follows a new IP via mDNS.

## Files

* `src/init.lua`: driver (discovery, pairing, session, commands, child devices)
* `src/t10_model.lua`: maps the HomeKit tree to SmartThings
* `src/hap_client.lua`, `srp.lua`, `bignum.lua`, `curve25519.lua`, `chacha20poly1305.lua`, `sha512.lua`, `tlv8.lua`, `rng.lua`: HomeKit controller and crypto (unchanged from the T6 driver)
* `src/emitq.lua`: only sends changed values to the hub (unchanged)

Not affiliated with Honeywell or Resideo. Apache 2.0.
