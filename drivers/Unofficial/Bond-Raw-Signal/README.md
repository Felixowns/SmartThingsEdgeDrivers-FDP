# Bond-Raw-Signal (SmartThings Edge driver)

Builds SmartThings devices from whatever is configured on a Bond Bridge, and can
send the Bridge's stored raw RF signals directly (`PUT /v2/signal/tx`).

## Setup
1. SmartThings app > Add device > Scan nearby. The driver finds Bond Bridges by
   mDNS (`_bond._tcp`) and creates a **Bond Bridge** device. (If none is found,
   a manual "Bond Bridge" is created; enter its IP in settings.)
2. Token, either:
   - **Automatic:** power-cycle the Bridge, then within 10 minutes press Refresh
     on the Bond Bridge device ("Read token automatically" on), or
   - **Manual:** enter it in the Bond Bridge settings (Bond app > Bridge settings).
3. The Bridge's devices are read (type, properties, commands, raw signals) and a
   child device is created for each. Press Refresh on the Bond Bridge any time
   to re-read (e.g. after learning new buttons in the Bond app).

## Device behavior (per device setting)
| Type | Bond configuration | Custom (raw signals) |
|---|---|---|
| Ceiling fan | Bridge actions/state | raw signals; speed-step mapping (4 steps -> real speeds), "Fix light/winter state", dimmer press length |
| Shade / pergola | Bridge Open/Close/Hold/SetPosition | momentary-motor positioning by counting raw Open/Close bursts; burst counts, coast, interval |
| Light / single button | light switch | momentary trigger + self-resetting switch (Alexa: "turn on ...") |
| Fireplace / other | power switch | - |

Switching the setting swaps the device profile. Custom needs raw signals: devices
made from a Bond template (no stored signals) only work in Bond configuration
unless the remote's buttons are learned in the Bond app.

## Install
    smartthings edge:drivers:package drivers/Unofficial/Bond-Raw-Signal
    smartthings edge:channels:assign
    smartthings edge:drivers:install
