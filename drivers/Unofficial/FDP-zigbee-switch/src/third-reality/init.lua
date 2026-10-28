-- Third Reality smart plug sub-driver for the FDP Zigbee Switch driver
-- (merged from drivers/Unofficial/third-reality)
--
-- Reference: zigbee2mqtt.io 3RSP02028BZ / 3RSP02064Z pages and the zigbee-herdsman-converters
-- definitions behind them (src/devices/third_reality.ts).
--
-- Both plugs: switch, power, voltage, current, energy, power-on behavior (OnOff StartUpOnOff 0x4003),
--   and manufacturer cluster 0xFF03: reset energy (0x0000), countdown ON->OFF (0x0001),
--   countdown OFF->ON (0x0002).
-- Gen 2 (3RSP02028BZ, mfg 0x1233): LED brightness 0xFF03/0x0010. Fixed scaling, as Z2M uses:
--   voltage /10, current /1000, power /10, energy /3600000.
-- Gen 3 (3RSP02064Z, mfg 0x1407): LED brightness Basic 0x0000/0xFF01, power rise/drop report
--   thresholds 0xFF03/0x0040 + 0x0041 (1-3200 W), native metering-only mode 0xFF03/0x0050.
--   Scaling is read from the plug (multiplier/divisor attributes) like Z2M's electricityMeter.
-- Metering-only mode is Gen 3 only: the plug locks its own relay (including the button) and the
-- driver also refuses OFF from the app/automations. Gen 2 has no such attribute, so it is not offered.
-- The driver never turns a plug back on by itself.
-- SmartThings Energy: powerConsumptionReport is emitted on every energy report. Its `energy` is the
-- plug's own running total in Wh (the app's Reset energy offset is not applied), and `deltaEnergy`
-- is the Wh used since the previous report (never negative).

local capabilities = require "st.capabilities"
local clusters = require "st.zigbee.zcl.clusters"
local cluster_base = require "st.zigbee.cluster_base"
local data_types = require "st.zigbee.data_types"

local OnOff = clusters.OnOff
local Basic = clusters.Basic
local SimpleMetering = clusters.SimpleMetering
local ElectricalMeasurement = clusters.ElectricalMeasurement

local FINGERPRINTS = require "third-reality.fingerprints"

local MFG_CLUSTER = 0xFF03
local MFG_CODE = { [2] = 0x1233, [3] = 0x1407 }
local ATTR_RESET_ENERGY = 0x0000
local ATTR_COUNTDOWN_OFF = 0x0001
local ATTR_COUNTDOWN_ON = 0x0002
local ATTR_LED_GEN2 = 0x0010     -- on 0xFF03
local ATTR_LED_GEN3 = 0xFF01     -- on Basic
local ATTR_POWER_RISE = 0x0040
local ATTR_POWER_DROP = 0x0041
local ATTR_METERING_ONLY = 0x0050

-- device fields
local ENERGY_OFFSET = "energy_offset_wh"        -- same names as the standalone driver, so values carry over
local LAST_RAW_ENERGY = "last_raw_energy_wh"
local ENERGY_DIVISOR = "tr_energy_divisor"
local ENERGY_MULTIPLIER = "tr_energy_multiplier"
local POWER_DIVISOR = "tr_power_divisor"
local POWER_MULTIPLIER = "tr_power_multiplier"
local VOLTAGE_DIVISOR = "tr_voltage_divisor"
local VOLTAGE_MULTIPLIER = "tr_voltage_multiplier"
local CURRENT_DIVISOR = "tr_current_divisor"
local CURRENT_MULTIPLIER = "tr_current_multiplier"
local LAST_REPORT_WH = "tr_last_power_consumption_wh"
local PROFILE_APPLIED = "__third_reality_profile_applied"

-- Gen 2 values are fixed (Z2M ignores what the plug reports); Gen 3 values are fallbacks until the
-- plug's own multiplier/divisor attributes are read.
local SCALING = {
  [2] = { energy_div = 3600000, power_div = 10, voltage_div = 10, current_div = 1000 },
  [3] = { energy_div = 1000,    power_div = 10, voltage_div = 10, current_div = 1000 },
}

local function get_fingerprint(device)
  return FINGERPRINTS[device:get_model()]
end

local function get_gen(device)
  local fp = get_fingerprint(device)
  return fp and fp.gen or 3
end

local function log_info(device, fmt, ...)
  device.log.info(string.format("[Third Reality] " .. fmt, ...))
end

local function write_mfg(device, attr_id, data_type, value)
  device:send(cluster_base.write_manufacturer_specific_attribute(device, MFG_CLUSTER, attr_id,
    MFG_CODE[get_gen(device)], data_type, value))
end

-- multiplier/divisor lookup: Gen 2 always uses the fixed table, Gen 3 prefers what the plug reported
local function scale(device, raw, mult_key, div_key, default_div)
  local mult, div = 1, default_div
  if get_gen(device) == 3 then
    mult = device:get_field(mult_key) or 1
    div = device:get_field(div_key) or default_div
  end
  if div == nil or div == 0 then div = 1 end
  return raw * mult / div
end

local function metering_only(device)
  return get_gen(device) == 3 and device.preferences ~= nil and device.preferences.meteringOnlyMode == true
end

----------------------------------------------------------------------------------------------------
-- preferences -> device
----------------------------------------------------------------------------------------------------

local preference_writers = {
  powerOnState = function(device, value)
    local raw = tonumber(value) or 255
    device:send(OnOff.attributes.StartUpOnOff:write(device, data_types.Enum8(raw)))
  end,
  meteringOnlyMode = function(device, value)
    -- Gen 3 only; the plug itself handles keeping the relay on
    if get_gen(device) == 3 then
      write_mfg(device, ATTR_METERING_ONLY, data_types.Uint8, value and 1 or 0)
    end
  end,
  ledBrightness = function(device, value)
    local pct = math.max(0, math.min(100, math.floor(tonumber(value) or 100)))
    if get_gen(device) == 2 then
      write_mfg(device, ATTR_LED_GEN2, data_types.Uint8, pct)
    else
      device:send(cluster_base.write_manufacturer_specific_attribute(device, Basic.ID, ATTR_LED_GEN3,
        MFG_CODE[3], data_types.Uint8, pct))
    end
  end,
  countdownToTurnOff = function(device, value)
    write_mfg(device, ATTR_COUNTDOWN_OFF, data_types.Uint16, math.max(0, math.min(65535, math.floor(tonumber(value) or 0))))
  end,
  countdownToTurnOn = function(device, value)
    write_mfg(device, ATTR_COUNTDOWN_ON, data_types.Uint16, math.max(0, math.min(65535, math.floor(tonumber(value) or 0))))
  end,
  -- 0 = leave the plug's own threshold alone
  powerRiseThreshold = function(device, value)
    local w = math.floor(tonumber(value) or 0)
    if get_gen(device) == 3 and w > 0 then
      write_mfg(device, ATTR_POWER_RISE, data_types.Uint16, math.min(3200, w))
    end
  end,
  powerDropThreshold = function(device, value)
    local w = math.floor(tonumber(value) or 0)
    if get_gen(device) == 3 and w > 0 then
      write_mfg(device, ATTR_POWER_DROP, data_types.Uint16, math.min(3200, w))
    end
  end,
}

local function sync_all_preferences(device)
  for name, writer in pairs(preference_writers) do
    local value = device.preferences and device.preferences[name]
    if value ~= nil then
      writer(device, value)
    end
  end
end

----------------------------------------------------------------------------------------------------
-- reads / reporting
----------------------------------------------------------------------------------------------------

local function read_scaling(device)
  device:send(SimpleMetering.attributes.Divisor:read(device))
  device:send(SimpleMetering.attributes.Multiplier:read(device))
  if get_gen(device) == 3 then
    device:send(ElectricalMeasurement.attributes.ACPowerMultiplier:read(device))
    device:send(ElectricalMeasurement.attributes.ACPowerDivisor:read(device))
    device:send(ElectricalMeasurement.attributes.ACVoltageMultiplier:read(device))
    device:send(ElectricalMeasurement.attributes.ACVoltageDivisor:read(device))
    device:send(ElectricalMeasurement.attributes.ACCurrentMultiplier:read(device))
    device:send(ElectricalMeasurement.attributes.ACCurrentDivisor:read(device))
  end
end

local function read_telemetry(device)
  device:send(OnOff.attributes.OnOff:read(device))
  device:send(ElectricalMeasurement.attributes.ActivePower:read(device))
  device:send(ElectricalMeasurement.attributes.RMSVoltage:read(device))
  device:send(ElectricalMeasurement.attributes.RMSCurrent:read(device))
  device:send(SimpleMetering.attributes.CurrentSummationDelivered:read(device))
end

local function configure_reporting(device)
  local gen = get_gen(device)
  -- reportable changes in raw units: 1 W, 0.5 V, 50 mA (Z2M's Gen 2 values), 1 Wh
  device:send(OnOff.attributes.OnOff:configure_reporting(device, 0, 300))
  device:send(ElectricalMeasurement.attributes.ActivePower:configure_reporting(device, 5, 300, 10))
  device:send(ElectricalMeasurement.attributes.RMSVoltage:configure_reporting(device, 10, 300, 5))
  device:send(ElectricalMeasurement.attributes.RMSCurrent:configure_reporting(device, 5, 300, 50))
  device:send(SimpleMetering.attributes.CurrentSummationDelivered:configure_reporting(device, 10, 300,
    gen == 2 and 3600 or 1))
  -- power factor is not mapped to a capability; slow it down so it doesn't flood the hub
  device:send(ElectricalMeasurement.attributes.PowerFactor:configure_reporting(device, 60, 600, 10))
end

----------------------------------------------------------------------------------------------------
-- capability handlers
----------------------------------------------------------------------------------------------------

local function switch_on_handler(driver, device, command)
  device:send(OnOff.server.commands.On(device))
end

local function switch_off_handler(driver, device, command)
  if metering_only(device) then
    log_info(device, "metering-only mode is on, refusing OFF")
    device:emit_event(capabilities.switch.switch.on())
    return
  end
  device:send(OnOff.server.commands.Off(device))
end

local function refresh_handler(driver, device, command)
  read_scaling(device)
  read_telemetry(device)
end

local function reset_energy_handler(driver, device, command)
  -- native reset on the plug, plus a driver-side baseline in case the plug ignores it
  write_mfg(device, ATTR_RESET_ENERGY, data_types.Uint8, 1)
  local last_raw = device:get_field(LAST_RAW_ENERGY) or 0
  device:set_field(ENERGY_OFFSET, last_raw, { persist = true })
  log_info(device, "energy reset (baseline %d raw)", last_raw)
  device:emit_event(capabilities.energyMeter.energy({ value = 0.0, unit = "kWh" }))
end

----------------------------------------------------------------------------------------------------
-- zigbee attribute handlers
----------------------------------------------------------------------------------------------------

local function on_off_handler(driver, device, value, zb_rx)
  if value.value then
    device:emit_event(capabilities.switch.switch.on())
  else
    device:emit_event(capabilities.switch.switch.off())
  end
end

local function store_positive(key)
  return function(driver, device, value, zb_rx)
    local v = value.value
    if v ~= nil and v > 0 then
      device:set_field(key, v, { persist = true })
    end
  end
end

local function energy_handler(driver, device, value, zb_rx)
  local raw = value.value
  if raw == nil then return end
  device:set_field(LAST_RAW_ENERGY, raw, { persist = true })

  local offset = device:get_field(ENERGY_OFFSET) or 0
  if raw < offset then
    -- the plug's own counter was reset (native reset worked), drop the baseline
    offset = 0
    device:set_field(ENERGY_OFFSET, 0, { persist = true })
  end
  local default_div = SCALING[get_gen(device)].energy_div
  local kwh = scale(device, raw - offset, ENERGY_MULTIPLIER, ENERGY_DIVISOR, default_div)
  device:emit_event(capabilities.energyMeter.energy({ value = kwh, unit = "kWh" }))

  -- SmartThings Energy
  if device:supports_capability(capabilities.powerConsumptionReport) then
    local total_wh = scale(device, raw, ENERGY_MULTIPLIER, ENERGY_DIVISOR, default_div) * 1000
    local last_wh = device:get_field(LAST_REPORT_WH)
    local delta_wh = 0.0
    if last_wh ~= nil then
      delta_wh = math.max(total_wh - last_wh, 0.0) -- plug counter reset -> 0, not negative
    end
    device:set_field(LAST_REPORT_WH, total_wh, { persist = true })
    device:emit_event(capabilities.powerConsumptionReport.powerConsumption({
      energy = total_wh, deltaEnergy = delta_wh,
    }))
  end
end

local function power_handler(driver, device, value, zb_rx)
  if value.value == nil then return end
  local w = scale(device, value.value, POWER_MULTIPLIER, POWER_DIVISOR, SCALING[get_gen(device)].power_div)
  device:emit_event(capabilities.powerMeter.power({ value = w, unit = "W" }))
end

local function voltage_handler(driver, device, value, zb_rx)
  if value.value == nil then return end
  local v = scale(device, value.value, VOLTAGE_MULTIPLIER, VOLTAGE_DIVISOR, SCALING[get_gen(device)].voltage_div)
  device:emit_event(capabilities.voltageMeasurement.voltage({ value = v, unit = "V" }))
end

local function current_handler(driver, device, value, zb_rx)
  if value.value == nil then return end
  local a = scale(device, value.value, CURRENT_MULTIPLIER, CURRENT_DIVISOR, SCALING[get_gen(device)].current_div)
  device:emit_event(capabilities.currentMeasurement.current({ value = a, unit = "A" }))
end

-- these plugs report power through Electrical Measurement; ignore Simple Metering demand so the
-- base driver doesn't emit a second (differently scaled) power value
local function ignore(driver, device, value, zb_rx) end

----------------------------------------------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------------------------------------------

-- Plugs joined to the standalone third-reality driver (or a generic profile) get moved to the
-- profile for their generation.
local function migrate_profile(device)
  local fp = get_fingerprint(device)
  if fp == nil then return end
  if device:get_field(PROFILE_APPLIED) == fp.profile then return end
  device:set_field(PROFILE_APPLIED, fp.profile, { persist = true })
  log_info(device, "switching profile to %s", fp.profile)
  device:try_update_metadata({ profile = fp.profile })
end

local function device_init(driver, device)
  migrate_profile(device)
end

local function device_added(driver, device, event)
  require("lifecycle_handlers.device_added")(driver, device, event)
end

local function do_configure(driver, device)
  -- base: refresh, default reporting, metering divisor/multiplier reads
  require("lifecycle_handlers.do_configure")(driver, device)
  configure_reporting(device)
  read_scaling(device)
  sync_all_preferences(device)
end

local function info_changed(driver, device, event, args)
  local old = (args and args.old_st_store and args.old_st_store.preferences) or {}
  for name, writer in pairs(preference_writers) do
    local value = device.preferences[name]
    if value ~= nil and value ~= old[name] then
      log_info(device, "preference %s -> %s", name, tostring(value))
      writer(device, value)
    end
  end
end

local third_reality = {
  NAME = "Third Reality",
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = switch_on_handler,
      [capabilities.switch.commands.off.NAME] = switch_off_handler,
    },
    [capabilities.energyMeter.ID] = {
      [capabilities.energyMeter.commands.resetEnergyMeter.NAME] = reset_energy_handler,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh_handler,
    },
  },
  zigbee_handlers = {
    attr = {
      [OnOff.ID] = {
        [OnOff.attributes.OnOff.ID] = on_off_handler,
      },
      [SimpleMetering.ID] = {
        [SimpleMetering.attributes.CurrentSummationDelivered.ID] = energy_handler,
        [SimpleMetering.attributes.Divisor.ID] = store_positive(ENERGY_DIVISOR),
        [SimpleMetering.attributes.Multiplier.ID] = store_positive(ENERGY_MULTIPLIER),
        [SimpleMetering.attributes.InstantaneousDemand.ID] = ignore,
      },
      [ElectricalMeasurement.ID] = {
        [ElectricalMeasurement.attributes.ActivePower.ID] = power_handler,
        [ElectricalMeasurement.attributes.RMSVoltage.ID] = voltage_handler,
        [ElectricalMeasurement.attributes.RMSCurrent.ID] = current_handler,
        [ElectricalMeasurement.attributes.ACPowerMultiplier.ID] = store_positive(POWER_MULTIPLIER),
        [ElectricalMeasurement.attributes.ACPowerDivisor.ID] = store_positive(POWER_DIVISOR),
        [ElectricalMeasurement.attributes.ACVoltageMultiplier.ID] = store_positive(VOLTAGE_MULTIPLIER),
        [ElectricalMeasurement.attributes.ACVoltageDivisor.ID] = store_positive(VOLTAGE_DIVISOR),
        [ElectricalMeasurement.attributes.ACCurrentMultiplier.ID] = store_positive(CURRENT_MULTIPLIER),
        [ElectricalMeasurement.attributes.ACCurrentDivisor.ID] = store_positive(CURRENT_DIVISOR),
        [ElectricalMeasurement.attributes.PowerFactor.ID] = ignore,
      },
    },
  },
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    doConfigure = do_configure,
    infoChanged = info_changed,
  },
  can_handle = require("third-reality.can_handle"),
}

return third_reality
