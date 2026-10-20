local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local defaults = require "st.zigbee.defaults"
local clusters = require "st.zigbee.zcl.clusters"
local data_types = require "st.zigbee.data_types"
local log = require "log"

-- Intercept switch.off command when Metering Only Mode is active
local function switch_off_handler(driver, device, command)
  if device.preferences and device.preferences.meteringOnlyMode == true then
    log.info(string.format("[%s] [SWITCH] Metering-Only Mode ACTIVE! Holding relay ON.", device.label))
    device:emit_event(capabilities.switch.switch.on())
    return
  end
  log.info(string.format("[%s] [SWITCH] Standard OFF command executed.", device.label))
  device:send(clusters.OnOff.server.commands.Off(device))
end

-- Write StartUpOnOff preference
local function info_changed_handler(driver, device, event, args)
  if device.preferences and device.preferences.powerOnState then
    local old_val = args.old_st_store.preferences and args.old_st_store.preferences.powerOnState
    local new_val = device.preferences.powerOnState

    if new_val ~= old_val then
      local enum_val = tonumber(new_val) or 255
      log.info(string.format("[%s] [PREFERENCE] StartUpOnOff updated to enum %d", device.label, enum_val))
      device:send(clusters.OnOff.attributes.StartUpOnOff:write(device, data_types.Enum8(enum_val)))
    end
  end
end

--------------------------------------------------------------------------------
-- Custom Telemetry Handlers
--------------------------------------------------------------------------------

-- Force Query All Attributes on App Refresh
local function refresh_handler(driver, device, command)
  log.info(string.format("[%s] [REFRESH] App pull-to-refresh triggered. Querying plug attributes...", device.label))
  
  -- Re-apply reporting intervals to quiet power factor spam
  device:send(clusters.ElectricalMeasurement.attributes.PowerFactor:configure_reporting(device, 60, 600, 10))
  device:send(clusters.SimpleMetering.attributes.CurrentSummationDelivered:configure_reporting(device, 5, 300, 1))

  -- Query scaling factors
  device:send(clusters.SimpleMetering.attributes.Divisor:read(device))
  device:send(clusters.SimpleMetering.attributes.Multiplier:read(device))

  -- Query current telemetry values
  device:send(clusters.OnOff.attributes.OnOff:read(device))
  device:send(clusters.ElectricalMeasurement.attributes.ActivePower:read(device))
  device:send(clusters.ElectricalMeasurement.attributes.RMSVoltage:read(device))
  device:send(clusters.ElectricalMeasurement.attributes.RMSCurrent:read(device))
  device:send(clusters.SimpleMetering.attributes.CurrentSummationDelivered:read(device))
end

--- Reset Energy Baseline
local function reset_energy_handler(driver, device, command)
  local last_raw = device:get_field("last_raw_energy_wh") or 0
  device:set_field("energy_offset_wh", last_raw, { persist = true })
  log.info(string.format("[%s] [ENERGY RESET] Baseline offset set to %d raw ticks", device.label, last_raw))
  device:emit_event(capabilities.energyMeter.energy({ value = 0.0, unit = "kWh" }))
end

--- Divisor Handler
local function divisor_handler(driver, device, value, zb_rx)
  local divisor = value.value
  if divisor and divisor > 0 then
    log.info(string.format("[%s] [METERING] Energy Divisor updated: %d", device.label, divisor))
    device:set_field("energy_divisor", divisor, { persist = true })
  end
end

--- Multiplier Handler
local function multiplier_handler(driver, device, value, zb_rx)
  local multiplier = value.value
  if multiplier and multiplier > 0 then
    log.info(string.format("[%s] [METERING] Energy Multiplier updated: %d", device.label, multiplier))
    device:set_field("energy_multiplier", multiplier, { persist = true })
  end
end

--- Energy Meter Handler
local function energy_meter_handler(driver, device, value, zb_rx)
  local raw_val = value.value
  if raw_val ~= nil then
    device:set_field("last_raw_energy_wh", raw_val, { persist = true })
    
    local offset = device:get_field("energy_offset_wh") or 0
    local net_raw = raw_val - offset
    if net_raw < 0 then net_raw = 0 end

    -- Fetch dynamic scaling factors with fallbacks (Gen 3 defaults to divisor 1000, mult 1)
    local multiplier = device:get_field("energy_multiplier") or 1
    local divisor = device:get_field("energy_divisor") or 1000

    local kwh_value = (net_raw * multiplier) / divisor
    log.info(string.format(
      "[%s] [LIVE TELEMETRY] Energy: %.3f kWh (Raw: %d | Offset: %d | Mult: %d | Div: %d)", 
      device.label, kwh_value, raw_val, offset, multiplier, divisor
    ))
    device:emit_event(capabilities.energyMeter.energy({ value = kwh_value, unit = "kWh" }))
  end
end

--- Active Power Handler (Watts)
local function active_power_handler(driver, device, value, zb_rx)
  local raw_val = value.value
  if raw_val ~= nil then
    local watts = raw_val / 10.0
    log.info(string.format("[%s] [LIVE TELEMETRY] Power: %.1f W", device.label, watts))
    device:emit_event(capabilities.powerMeter.power({ value = watts, unit = "W" }))
  end
end

--- Voltage Handler
local function voltage_handler(driver, device, value, zb_rx)
  local raw_val = value.value
  if raw_val ~= nil then
    local volts = (raw_val > 500) and (raw_val / 10.0) or raw_val
    log.info(string.format("[%s] [LIVE TELEMETRY] Voltage: %.1f V", device.label, volts))
    device:emit_event(capabilities.voltageMeasurement.voltage({ value = volts, unit = "V" }))
  end
end

--- Current Handler
local function current_handler(driver, device, value, zb_rx)
  local raw_val = value.value
  if raw_val ~= nil then
    local amps = raw_val / 1000.0
    log.info(string.format("[%s] [LIVE TELEMETRY] Current: %.3f A", device.label, amps))
    device:emit_event(capabilities.currentMeasurement.current({ value = amps, unit = "A" }))
  end
end

--------------------------------------------------------------------------------
-- Lifecycle & Registration
--------------------------------------------------------------------------------
local function do_configure(driver, device)
  log.info(string.format("[%s] [LIFECYCLE] Executing doConfigure...", device.label))
  device:configure()

  device:send(clusters.ElectricalMeasurement.attributes.ActivePower:configure_reporting(device, 1, 300, 1))
  device:send(clusters.ElectricalMeasurement.attributes.RMSVoltage:configure_reporting(device, 5, 300, 1))
  device:send(clusters.ElectricalMeasurement.attributes.RMSCurrent:configure_reporting(device, 5, 300, 10))
  device:send(clusters.SimpleMetering.attributes.CurrentSummationDelivered:configure_reporting(device, 5, 300, 1))

  -- Query scaling factors
  device:send(clusters.SimpleMetering.attributes.Divisor:read(device))
  device:send(clusters.SimpleMetering.attributes.Multiplier:read(device))

  -- Query initial telemetry
  device:send(clusters.OnOff.attributes.OnOff:read(device))
  device:send(clusters.ElectricalMeasurement.attributes.ActivePower:read(device))
  device:send(clusters.ElectricalMeasurement.attributes.RMSVoltage:read(device))
  device:send(clusters.ElectricalMeasurement.attributes.RMSCurrent:read(device))
  device:send(clusters.SimpleMetering.attributes.CurrentSummationDelivered:read(device))
end

local template = {
  supported_capabilities = {
    capabilities.switch,
    capabilities.powerMeter,
    capabilities.energyMeter,
    capabilities.voltageMeasurement,
    capabilities.currentMeasurement,
    capabilities.refresh
  },
  lifecycle_handlers = {
    infoChanged = info_changed_handler,
    doConfigure = do_configure
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.off.NAME] = switch_off_handler
    },
    [capabilities.energyMeter.ID] = {
      [capabilities.energyMeter.commands.resetEnergyMeter.NAME] = reset_energy_handler
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh_handler
    }
  },
  zigbee_handlers = {
    attr = {
      [clusters.SimpleMetering.ID] = {
        [clusters.SimpleMetering.attributes.CurrentSummationDelivered.ID] = energy_meter_handler,
        [clusters.SimpleMetering.attributes.Divisor.ID] = divisor_handler,
        [clusters.SimpleMetering.attributes.Multiplier.ID] = multiplier_handler
      },
      [clusters.ElectricalMeasurement.ID] = {
        [clusters.ElectricalMeasurement.attributes.ActivePower.ID] = active_power_handler,
        [clusters.ElectricalMeasurement.attributes.RMSVoltage.ID] = voltage_handler,
        [clusters.ElectricalMeasurement.attributes.RMSCurrent.ID] = current_handler
      }
    }
  },
  health_check = false
}

defaults.register_for_default_handlers(template, template.supported_capabilities)
local zigbee_driver = ZigbeeDriver("third-reality-gen3-plug-driver", template)
zigbee_driver:run()