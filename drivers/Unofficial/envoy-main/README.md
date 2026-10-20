# Enphase Envoy Local — SmartThings Edge Driver

A SmartThings Edge LAN driver for local integration with Enphase IQ Gateway (Envoy) running Firmware 7.x or newer. Communicates directly over your local network — no cloud dependency, no Enphase cloud polling.

---

## What It Shows

The driver creates a single **Enphase Envoy** device in SmartThings with three components visible as separate tiles:

| Component | Label | Data Source | Shows |
|---|---|---|---|
| `main` | Solar Production | `/production.json` → `production[type=eim]` | Current watts + today kWh |
| `consumed` | Home Consumption | `/production.json` → `consumption[total-consumption]` | Current watts + today kWh |
| `grid` | Grid | `/production.json` → `consumption[net-consumption]` | Absolute watts + direction switch |

### Grid Component
The `grid` component uses two capabilities together to represent flow direction without negative numbers:

- **powerMeter** — absolute wattage (always positive, great for automations)
- **switch** — `ON` = exporting to grid (solar surplus), `OFF` = importing from grid

This makes ST automations clean and readable:
> *"When Grid switch is ON AND Grid power > 2000 → run dishwasher"*
> *"When Grid switch turns OFF → notify 'Drawing from grid'"*

---

## Requirements

- SmartThings Hub (v2, v3, or Aeotec) on the same local network as your Envoy
- Enphase IQ Gateway (Envoy) running Firmware 7.x or newer
- Static/reserved IP for your Envoy (set in your router — strongly recommended)
- An Enphase JWT token (valid for 1 year — see below)
- [SmartThings CLI](https://github.com/SmartThingsCommunity/smartthings-cli) installed

---

## Getting Your Enphase API Token

Enphase Firmware 7.x+ requires a JWT for local API access. Tokens are valid for **1 year** — you'll need to repeat this annually.

1. Go to [entrez.enphaseenergy.com](https://entrez.enphaseenergy.com/)
2. Log in with your Enphase app credentials
3. In **Select System**, type your system name (as it appears in the Enphase app)
4. Select your gateway serial number from **Select Gateway**
5. Click **Generate Token**
6. Copy the full token text — it is approximately 1,000+ characters long

> **Important:** The SmartThings app preference field cannot hold the full token in one paste. The driver splits the token across two fields — see [Configuration](#configuration) below.

---

## Installation

### 1. Clone the repository

```bash
git clone https://github.com/JaragonCR/envoy.git
cd envoy
```

### 2. Create a channel (first time only)

```bash
smartthings edge:channels:create \
  --name "MyDrivers" \
  --description "Personal edge drivers" \
  --termsOfServiceUrl "https://example.com"
```

Save the channel ID from the output.

### 3. Enroll your hub in the channel (first time only)

```bash
smartthings edge:channels:enroll \
  <HUB_ID> \
  --channel <CHANNEL_ID>
```

Find your hub ID with: `smartthings edge:drivers:install` (it lists hubs before prompting).

### 4. Build, upload, and assign to channel

```bash
smartthings edge:drivers:package --assign
```

Select your channel when prompted.

### 5. Install to your hub

```bash
smartthings edge:drivers:install
```

Select your channel → select **Enphase Envoy Local** → select your hub.

### 6. Add the device in the SmartThings app

1. Tap **+** → **Add device** → **Scan for nearby devices**
2. Wait up to 30 seconds — **Enphase Envoy** will appear
3. Tap it to add it to a room

---

## Configuration

Open the device in the ST app → tap **⋮** → **Settings**:

| Field | Value |
|---|---|
| **Envoy IP Address** | Local IPv4 of your Envoy, e.g. `192.168.1.50` |
| **API Token (Part 1)** | First half of your JWT token |
| **API Token (Part 2)** | Second half of your JWT token |

### Splitting the Token

The ST app truncates long text fields, so the token must be split in two. Find the midpoint and paste each half:

```bash
# Check total token length
echo -n "YOUR_FULL_TOKEN" | wc -c

# Find the midpoint, e.g. if length is 1100, split at 550
echo -n "YOUR_FULL_TOKEN" | cut -c1-550    # → Part 1
echo -n "YOUR_FULL_TOKEN" | cut -c551-     # → Part 2
```

Paste Part 1 into **API Token (Part 1)** and Part 2 into **API Token (Part 2)**. The driver concatenates them automatically.

---

## Updating the Driver

After making changes to the source:

```bash
smartthings edge:drivers:package --assign
smartthings edge:drivers:install
```

The hub pulls the update within ~60 seconds. If the profile changed (e.g. new components or capabilities), delete the device in the ST app and re-discover it so it picks up the new profile.

---

## Annual Token Renewal

Your JWT expires after 1 year. When it does, the driver will log:

```
[ENVOY] HTTP GET /production.json → 401
```

To renew:
1. Generate a new token at [entrez.enphaseenergy.com](https://entrez.enphaseenergy.com/)
2. Split it into two halves (see above)
3. Open the device in the ST app → **⋮** → **Settings** → update both token fields
4. The driver detects the preference change and polls immediately

---

## Data Source

All data comes from a single local API call per poll cycle:

```
GET https://<ENVOY_IP>/production.json
```

| Field | Used For |
|---|---|
| `production[type=eim].wNow` | Solar watts now |
| `production[type=eim].whToday` | Solar kWh today |
| `production[type=eim].whLastSevenDays` | Solar kWh last 7 days (logged) |
| `production[type=eim].whLifetime` | Solar kWh lifetime (logged) |
| `consumption[total-consumption].wNow` | Home consumption watts now |
| `consumption[total-consumption].whToday` | Home consumption kWh today |
| `consumption[net-consumption].wNow` | Net grid flow (negative = exporting) |

The driver uses `production[type=eim]` (the energy meter) rather than `production[type=inverters]` for production data, as the EIM provides accurate metered values including reactive power and true RMS measurements.

Polling interval: every **5 minutes**. An immediate poll fires on driver init and on any preference change.

---

## Automations

Because the grid component uses a `switch` + `powerMeter`, you can build automations entirely within SmartThings without any third-party apps:

**Export surplus to appliances:**
> If Grid switch = ON AND Grid power ≥ 1500 → turn on EV charger / washing machine

**Grid protection alert:**
> If Grid switch changes to OFF → send notification "Drawing from grid"

**Peak solar notification:**
> If Solar Production power ≥ 8000 → send notification "System near peak output"

**Away mode solar optimization:**
> If Grid switch = ON AND mode = Away → turn on water heater

---

## Troubleshooting

**401 Unauthorized** — Token is expired or incorrectly split. Regenerate at entrez.enphaseenergy.com and re-enter both halves.

**IP or token not set** — Both preference fields must be saved before the first poll fires.

**Device not appearing during scan** — Make sure the driver is installed on the hub (`smartthings edge:drivers:installed`). Delete the device and re-scan if the profile looks stale.

**-0W showing for solar** — Normal nighttime behavior. The driver clamps `wNow` to 0 for display but the raw EIM value is -0.0 when no production is occurring.

**Stream live logs:**
```bash
smartthings edge:drivers:logcat
```

---

## File Structure

```
envoy/
├── config.yml                  # Driver metadata and LAN permissions
├── profiles/
│   └── envoy.yaml              # Device profile (3 components)
└── src/
    └── init.lua                # Driver logic
```

---

## Acknowledgements

Inspired by prior Enphase SmartThings integrations:
- [ahndee/Envoy-ST](https://github.com/ahndee/Envoy-ST) — original classic DTH
- [Matthew1471/Enphase-API](https://github.com/Matthew1471/Enphase-API) — comprehensive local API documentation
- [vpsupun/hubitat](https://github.com/vpsupun/hubitat) — Hubitat consumption metering approach

---

## License

MIT
