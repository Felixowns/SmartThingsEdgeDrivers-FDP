-- Friedrich Thermostat
-- SmartThings Edge driver for the ESP32-C6 Matter bridge (FriedrichMatter sketch)
-- that sits on the RS485 bus between the Friedrich/Verdant wall thermostat and the
-- Friedrich VRP unit.
--
-- Matter endpoints exposed by the firmware (endpoint numbers are discovered, not
-- hard-coded):
--   Thermostat  : SystemMode Off/Heat/Cool, heat + cool setpoints, LocalTemperature,
--                 ThermostatRunningState
--   Fan         : FanMode = fan speed, Low / High
--   OnOff       : "Fan constant" - on = fan always runs, off = auto (only with heat/cool)
--                 (older firmware without this switch: Low/High = constant, Auto = auto)
--   Humidity    : RelativeHumidityMeasurement (RS485 CMD 0B)
--   Temperature : TemperatureMeasurement (ignored while a Thermostat endpoint exists)
--   OnOff       : "ESP32 control" - on = ESP32 runs the unit, off = wall thermostat
--                 pass-through
--
-- SmartThings layout:
--   main    : room temp, mode, heat/cool setpoints, operating state, humidity,
--             thermostat fan mode (On = constant, Auto = with heat/cool),
--             fan speed (Low / High), refresh
--   control : switch for "ESP32 control"
-- Any endpoint can be pinned in the device settings. The final map is logged on init.

local capabilities = require "st.capabilities"
local clusters     = require "st.matter.clusters"
local MatterDriver = require "st.matter.driver"
local log          = require "log"

local OnOff      = clusters.OnOff
local Thermostat = clusters.Thermostat
local TempMeas   = clusters.TemperatureMeasurement
local Humidity   = clusters.RelativeHumidityMeasurement
local FanControl = clusters.FanControl

local TAG = "[friedrich] "

-- Matter Thermostat SystemMode values
local SYSMODE_OFF, SYSMODE_COOL, SYSMODE_HEAT = 0, 3, 4
local SYSMODE_TO_ST = { [0] = "off", [1] = "auto", [3] = "cool", [4] = "heat", [7] = "fanonly" }
local ST_TO_SYSMODE = { off = SYSMODE_OFF, cool = SYSMODE_COOL, heat = SYSMODE_HEAT }
local SUPPORTED_MODES = { "off", "cool", "heat" }

-- Fan. Matter FanMode values: 0 Off, 1 Low, 2 Medium, 3 High, 4 On, 5 Auto
--   thermostatFanMode    "on" = constant, "auto" = only with heat/cool  <- Fan constant switch
--   airConditionerFanMode "low" / "high"                                <- Fan endpoint FanMode
local FAN_MODES  = { "on", "auto" }
local FAN_SPEEDS = { "low", "high" }

local ROLES = { "thermostat", "fan", "humidity", "temperature", "control", "fanconstant" }
local PREF_FOR_ROLE = {
  thermostat = "epThermostat", fan = "epFan", humidity = "epHumidity",
  temperature = "epTemperature", control = "epControl", fanconstant = "epFanConstant",
}

local FIELD_MAP          = "ep_map"
local FIELD_LOCAL_TEMP   = "has_local_temp"   -- LocalTemperature has reported a value
local FIELD_FAN_SPEED    = "fan_speed"        -- "low" | "high"
local FIELD_FAN_CONSTANT = "fan_constant"     -- true = constant, false = auto

----------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------

local function raw(v)
  if type(v) == "table" and v.value ~= nil then return v.value end
  return v
end

local function f_to_c(f) return (f - 32) * 5 / 9 end
-- The RS485 bus carries setpoints as one byte of whole °F, so setpoints are whole °F here too.
local function centi_c_to_f(v) return math.floor(v / 100.0 * 9 / 5 + 32 + 0.5) end

-- App value (°F, or °C for °C accounts) -> whole °F, clamped, -> Matter centi-°C
local function setpoint_to_centi_c(v, lo_f, hi_f)
  local f = (v > 40) and v or (v * 9 / 5 + 32)
  f = math.floor(f + 0.5)
  if f < lo_f then f = lo_f elseif f > hi_f then f = hi_f end
  return math.floor(f_to_c(f) * 100 + 0.5)
end


local function sorted_endpoints(device, cluster)
  if cluster == nil then return {} end
  local out = {}
  for _, e in ipairs(device:get_endpoints(cluster.ID) or {}) do table.insert(out, e) end
  table.sort(out)
  return out
end

local function endpoint_has_cluster(device, ep, cluster)
  for _, e in ipairs(sorted_endpoints(device, cluster)) do
    if e == ep then return true end
  end
  return false
end

local function get_map(device) return device:get_field(FIELD_MAP) or {} end

local function role_for_endpoint(device, ep)
  for role, e in pairs(get_map(device)) do
    if e == ep then return role end
  end
  return nil
end

local function emit_main(device, event)
  device:emit_event(event)
end

local function emit_control(device, event)
  local comp = device.profile.components.control
  if comp then device:emit_component_event(comp, event) end
end

local function emit_fan_state(device)
  local speed = device:get_field(FIELD_FAN_SPEED)
  local constant = device:get_field(FIELD_FAN_CONSTANT)
  if speed ~= nil then
    emit_main(device, capabilities.airConditionerFanMode.fanMode(speed))
  end
  if constant ~= nil then
    emit_main(device, capabilities.thermostatFanMode.thermostatFanMode(constant and "on" or "auto"))
  end
end

local function pref_range(prefs, lo_name, hi_name, lo_def, hi_def)
  local lo = tonumber(prefs[lo_name]) or lo_def
  local hi = tonumber(prefs[hi_name]) or hi_def
  if lo > hi then lo, hi = hi, lo end
  return lo, hi
end

----------------------------------------------------------------------
-- endpoint discovery
----------------------------------------------------------------------

local function build_endpoint_map(device)
  local map, used = {}, {}
  local prefs = device.preferences or {}

  for _, role in ipairs(ROLES) do
    local v = tonumber(prefs[PREF_FOR_ROLE[role]] or 0) or 0
    if v > 0 then map[role] = v; used[v] = true end
  end

  local function first_free(cluster)
    for _, ep in ipairs(sorted_endpoints(device, cluster)) do
      if ep ~= 0 and not used[ep] then return ep end
    end
    return nil
  end

  if not map.thermostat then map.thermostat = first_free(Thermostat) end
  if map.thermostat then used[map.thermostat] = true end

  -- Fan Control may live on its own endpoint or on the thermostat endpoint itself
  if not map.fan then
    map.fan = first_free(FanControl)
    if not map.fan and map.thermostat and endpoint_has_cluster(device, map.thermostat, FanControl) then
      map.fan = map.thermostat
    end
  end
  if map.fan then used[map.fan] = true end

  if not map.humidity then map.humidity = first_free(Humidity) end
  if map.humidity then used[map.humidity] = true end

  if not map.temperature then map.temperature = first_free(TempMeas) end
  if map.temperature then used[map.temperature] = true end

  -- The Fan endpoint also carries an On/Off cluster, so the firmware's two switches are
  -- the first On/Off endpoints that aren't one of the endpoints above, in creation
  -- order: "ESP32 control", then "Fan constant".
  if not map.control then map.control = first_free(OnOff) end
  if map.control then used[map.control] = true end
  if not map.fanconstant then map.fanconstant = first_free(OnOff) end

  device:set_field(FIELD_MAP, map, { persist = true })

  local parts = {}
  for _, role in ipairs(ROLES) do
    table.insert(parts, string.format("%s=%s", role, tostring(map[role] or "-")))
  end
  log.info(TAG .. "endpoint map: " .. table.concat(parts, " "))
  return map
end

----------------------------------------------------------------------
-- subscribe / refresh
----------------------------------------------------------------------

local function attribute_list(device)
  local map = get_map(device)
  local list = {}
  local function add(ep, attr)
    if ep and attr then table.insert(list, { ep = ep, attr = attr }) end
  end

  if map.thermostat then
    local A = Thermostat.attributes
    add(map.thermostat, A.LocalTemperature)
    add(map.thermostat, A.SystemMode)
    add(map.thermostat, A.OccupiedHeatingSetpoint)
    add(map.thermostat, A.OccupiedCoolingSetpoint)
    add(map.thermostat, A.ThermostatRunningState) -- nil on very old hub libs, add() skips it
  end
  if map.fan then add(map.fan, FanControl.attributes.FanMode) end
  if map.humidity then add(map.humidity, Humidity.attributes.MeasuredValue) end
  if map.temperature and not map.thermostat then add(map.temperature, TempMeas.attributes.MeasuredValue) end
  if map.control then add(map.control, OnOff.attributes.OnOff) end
  if map.fanconstant then add(map.fanconstant, OnOff.attributes.OnOff) end
  return list
end

local function send_all(device, kind)
  local req
  for _, a in ipairs(attribute_list(device)) do
    local ib = (kind == "subscribe") and a.attr:subscribe(device, a.ep) or a.attr:read(device, a.ep)
    if req == nil then req = ib else req:merge(ib) end
  end
  if req then device:send(req) end
end

local function subscribe(device) send_all(device, "subscribe") end
local function refresh(device) send_all(device, "read") end

local function emit_static(device)
  local prefs = device.preferences or {}
  local hide = { visibility = { displayed = false } }

  emit_main(device, capabilities.thermostatMode.supportedThermostatModes(SUPPORTED_MODES, hide))
  emit_main(device, capabilities.thermostatFanMode.supportedThermostatFanModes(FAN_MODES, hide))
  emit_main(device, capabilities.airConditionerFanMode.supportedAcFanModes(FAN_SPEEDS, hide))
  if capabilities.thermostatOperatingState.supportedThermostatOperatingStates then
    emit_main(device, capabilities.thermostatOperatingState.supportedThermostatOperatingStates(
      { "idle", "heating", "cooling", "fan only" }, hide))
  end

  local hlo, hhi = pref_range(prefs, "heatMinF", "heatMaxF", 60, 86)
  local clo, chi = pref_range(prefs, "coolMinF", "coolMaxF", 61, 86)
  if capabilities.thermostatHeatingSetpoint.heatingSetpointRange then
    emit_main(device, capabilities.thermostatHeatingSetpoint.heatingSetpointRange(
      { value = { minimum = hlo, maximum = hhi, step = 1 }, unit = "F" }, hide))
  end
  if capabilities.thermostatCoolingSetpoint.coolingSetpointRange then
    emit_main(device, capabilities.thermostatCoolingSetpoint.coolingSetpointRange(
      { value = { minimum = clo, maximum = chi, step = 1 }, unit = "F" }, hide))
  end
end

----------------------------------------------------------------------
-- attribute handlers
----------------------------------------------------------------------

local function local_temp_handler(driver, device, ib, response)
  local v = raw(ib.data.value)
  if v == nil then return end   -- null = no room temp yet
  device:set_field(FIELD_LOCAL_TEMP, true)
  emit_main(device, capabilities.temperatureMeasurement.temperature({ value = v / 100.0, unit = "C" }))
end

local function temp_sensor_handler(driver, device, ib, response)
  -- The firmware's Temperature Sensor starts at a 70 °F placeholder, so it is only used
  -- when there is no Thermostat endpoint at all.
  if get_map(device).thermostat or device:get_field(FIELD_LOCAL_TEMP) then return end
  local v = raw(ib.data.value)
  if v == nil then return end
  emit_main(device, capabilities.temperatureMeasurement.temperature({ value = v / 100.0, unit = "C" }))
end

local function system_mode_handler(driver, device, ib, response)
  local mode = SYSMODE_TO_ST[raw(ib.data.value)]
  if mode == nil then return end
  emit_main(device, capabilities.thermostatMode.thermostatMode(mode))
end

local function heat_setpoint_handler(driver, device, ib, response)
  local v = raw(ib.data.value)
  if v == nil then return end
  emit_main(device, capabilities.thermostatHeatingSetpoint.heatingSetpoint({ value = centi_c_to_f(v), unit = "F" }))
end

local function cool_setpoint_handler(driver, device, ib, response)
  local v = raw(ib.data.value)
  if v == nil then return end
  emit_main(device, capabilities.thermostatCoolingSetpoint.coolingSetpoint({ value = centi_c_to_f(v), unit = "F" }))
end

-- ThermostatRunningState bitmap: 0x01 heat, 0x02 cool, 0x04 fan,
-- 0x08 heat stage 2, 0x10 cool stage 2, 0x20/0x40 fan stage 2/3
local function running_state_handler(driver, device, ib, response)
  local v = tonumber(raw(ib.data.value)) or 0
  local state = "idle"
  if v & 0x09 ~= 0 then state = "heating"
  elseif v & 0x12 ~= 0 then state = "cooling"
  elseif v & 0x64 ~= 0 then state = "fan only" end
  emit_main(device, capabilities.thermostatOperatingState.thermostatOperatingState(state))
end

local function fan_mode_handler(driver, device, ib, response)
  local v = raw(ib.data.value)
  if v == 1 or v == 2 then
    device:set_field(FIELD_FAN_SPEED, "low", { persist = true })
  elseif v == 3 or v == 4 then
    device:set_field(FIELD_FAN_SPEED, "high", { persist = true })
  end
  -- Older firmware without the "Fan constant" switch: Low/High = constant, Off/Auto = auto
  if not get_map(device).fanconstant then
    if v == 0 or v == 5 then
      device:set_field(FIELD_FAN_CONSTANT, false, { persist = true })
      if device:get_field(FIELD_FAN_SPEED) == nil then
        device:set_field(FIELD_FAN_SPEED, "low", { persist = true })
      end
    elseif v ~= nil then
      device:set_field(FIELD_FAN_CONSTANT, true, { persist = true })
    end
  end
  emit_fan_state(device)
end

local function humidity_handler(driver, device, ib, response)
  local v = raw(ib.data.value)
  if v == nil then return end
  emit_main(device, capabilities.relativeHumidityMeasurement.humidity(math.floor(v / 100.0 + 0.5)))
end

local function onoff_handler(driver, device, ib, response)
  local role = role_for_endpoint(device, ib.endpoint_id)
  local on = raw(ib.data.value) == true
  if role == "control" then
    emit_control(device, on and capabilities.switch.switch.on() or capabilities.switch.switch.off())
  elseif role == "fanconstant" then
    device:set_field(FIELD_FAN_CONSTANT, on, { persist = true })
    emit_fan_state(device)
  end
  -- the Fan endpoint's own On/Off is ignored
end

----------------------------------------------------------------------
-- capability handlers
----------------------------------------------------------------------

local function thermostat_ep(device)
  local ep = get_map(device).thermostat
  if not ep then log.warn(TAG .. "no Thermostat endpoint mapped") end
  return ep
end

local function write_system_mode(device, st_mode)
  local ep = thermostat_ep(device)
  local v = ST_TO_SYSMODE[st_mode]
  if not ep then return end
  if v == nil then
    log.warn(TAG .. "unsupported thermostat mode " .. tostring(st_mode))
    return
  end
  device:send(Thermostat.attributes.SystemMode:write(device, ep, v))
end

local function set_thermostat_mode(driver, device, cmd)
  write_system_mode(device, cmd.args.mode)
end

local function fixed_mode(st_mode)
  return function(driver, device, cmd) write_system_mode(device, st_mode) end
end


local function set_heating_setpoint(driver, device, cmd)
  local ep = thermostat_ep(device)
  if not ep then return end
  local lo, hi = pref_range(device.preferences or {}, "heatMinF", "heatMaxF", 60, 86)
  device:send(Thermostat.attributes.OccupiedHeatingSetpoint:write(device, ep,
    setpoint_to_centi_c(cmd.args.setpoint, lo, hi)))
end

local function set_cooling_setpoint(driver, device, cmd)
  local ep = thermostat_ep(device)
  if not ep then return end
  local lo, hi = pref_range(device.preferences or {}, "coolMinF", "coolMaxF", 61, 86)
  device:send(Thermostat.attributes.OccupiedCoolingSetpoint:write(device, ep,
    setpoint_to_centi_c(cmd.args.setpoint, lo, hi)))
end

local function write_fan_speed(device, speed)
  local ep = get_map(device).fan
  if not ep then log.warn(TAG .. "no Fan endpoint mapped"); return end
  device:send(FanControl.attributes.FanMode:write(device, ep, (speed == "high") and 3 or 1))
end

local function write_fan_constant(device, constant)
  local map = get_map(device)
  if map.fanconstant then
    if constant then
      device:send(OnOff.server.commands.On(device, map.fanconstant))
    else
      device:send(OnOff.server.commands.Off(device, map.fanconstant))
    end
  elseif map.fan then
    -- older firmware without the Fan constant switch: Low/High = constant, Auto = auto
    if constant then
      write_fan_speed(device, device:get_field(FIELD_FAN_SPEED) or "low")
    else
      device:send(FanControl.attributes.FanMode:write(device, map.fan, 5))
    end
  else
    log.warn(TAG .. "no Fan endpoint mapped")
  end
end

local function set_fan_speed(driver, device, cmd)
  local speed = cmd.args.fanMode
  if speed ~= "low" and speed ~= "high" then
    log.warn(TAG .. "unsupported fan speed " .. tostring(speed)); return
  end
  if not get_map(device).fanconstant and device:get_field(FIELD_FAN_CONSTANT) == false then
    log.warn(TAG .. "firmware has no Fan constant switch; setting a speed turns the fan to constant")
  end
  write_fan_speed(device, speed)
end

local function set_thermostat_fan_mode(driver, device, cmd)
  local m = cmd.args.mode
  if m ~= "on" and m ~= "auto" then
    log.warn(TAG .. "unsupported thermostat fan mode " .. tostring(m)); return
  end
  write_fan_constant(device, m == "on")
end

local function fixed_fan_mode(constant)
  return function(driver, device, cmd) write_fan_constant(device, constant) end
end

local function control_switch(on)
  return function(driver, device, cmd)
    local ep = get_map(device).control
    if not ep then log.warn(TAG .. "no ESP32 control endpoint mapped"); return end
    if on then
      device:send(OnOff.server.commands.On(device, ep))
    else
      device:send(OnOff.server.commands.Off(device, ep))
    end
  end
end

local function handle_refresh(driver, device, cmd) refresh(device) end

----------------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------------

local function device_init(driver, device)
  build_endpoint_map(device)
  emit_static(device)
  subscribe(device)
end

local function device_added(driver, device)
  refresh(device)
end

local function info_changed(driver, device, event, args)
  local remap = false
  for _, p in pairs(PREF_FOR_ROLE) do
    if args.old_st_store.preferences[p] ~= device.preferences[p] then remap = true end
  end
  if remap then
    device:set_field(FIELD_LOCAL_TEMP, nil)
    build_endpoint_map(device)
    subscribe(device)
    refresh(device)
  end
  emit_static(device)
end

----------------------------------------------------------------------
-- driver
----------------------------------------------------------------------

local thermostat_attrs = {
  [Thermostat.attributes.LocalTemperature.ID]        = local_temp_handler,
  [Thermostat.attributes.SystemMode.ID]              = system_mode_handler,
  [Thermostat.attributes.OccupiedHeatingSetpoint.ID] = heat_setpoint_handler,
  [Thermostat.attributes.OccupiedCoolingSetpoint.ID] = cool_setpoint_handler,
}
if Thermostat.attributes.ThermostatRunningState then
  thermostat_attrs[Thermostat.attributes.ThermostatRunningState.ID] = running_state_handler
end

local driver = MatterDriver("friedrich-thermostat", {
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    infoChanged = info_changed,
  },
  matter_handlers = {
    attr = {
      [Thermostat.ID] = thermostat_attrs,
      [FanControl.ID] = { [FanControl.attributes.FanMode.ID] = fan_mode_handler },
      [Humidity.ID]   = { [Humidity.attributes.MeasuredValue.ID] = humidity_handler },
      [TempMeas.ID]   = { [TempMeas.attributes.MeasuredValue.ID] = temp_sensor_handler },
      [OnOff.ID]      = { [OnOff.attributes.OnOff.ID] = onoff_handler },
    },
  },
  capability_handlers = {
    [capabilities.thermostatMode.ID] = {
      [capabilities.thermostatMode.commands.setThermostatMode.NAME] = set_thermostat_mode,
      [capabilities.thermostatMode.commands.off.NAME]  = fixed_mode("off"),
      [capabilities.thermostatMode.commands.cool.NAME] = fixed_mode("cool"),
      [capabilities.thermostatMode.commands.heat.NAME] = fixed_mode("heat"),
    },
    [capabilities.thermostatHeatingSetpoint.ID] = {
      [capabilities.thermostatHeatingSetpoint.commands.setHeatingSetpoint.NAME] = set_heating_setpoint,
    },
    [capabilities.thermostatCoolingSetpoint.ID] = {
      [capabilities.thermostatCoolingSetpoint.commands.setCoolingSetpoint.NAME] = set_cooling_setpoint,
    },
    [capabilities.thermostatFanMode.ID] = {
      [capabilities.thermostatFanMode.commands.setThermostatFanMode.NAME] = set_thermostat_fan_mode,
      [capabilities.thermostatFanMode.commands.fanOn.NAME]   = fixed_fan_mode(true),
      [capabilities.thermostatFanMode.commands.fanAuto.NAME] = fixed_fan_mode(false),
    },
    [capabilities.airConditionerFanMode.ID] = {
      [capabilities.airConditionerFanMode.commands.setFanMode.NAME] = set_fan_speed,
    },
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME]  = control_switch(true),
      [capabilities.switch.commands.off.NAME] = control_switch(false),
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
    },
  },
  supported_capabilities = {
    capabilities.temperatureMeasurement,
    capabilities.thermostatMode,
    capabilities.thermostatHeatingSetpoint,
    capabilities.thermostatCoolingSetpoint,
    capabilities.thermostatOperatingState,
    capabilities.thermostatFanMode,
    capabilities.airConditionerFanMode,
    capabilities.relativeHumidityMeasurement,
    capabilities.switch,
    capabilities.refresh,
  },
})

log.info(TAG .. "Friedrich Thermostat driver starting")
driver:run()
