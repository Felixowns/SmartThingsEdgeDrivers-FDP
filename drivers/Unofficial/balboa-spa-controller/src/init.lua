-- Balboa Spa Controller
-- SmartThings Edge driver for the ESP32-C6 Matter bridge that talks to a
-- Balboa BP7 over RS485.
--
-- The driver does not hard-code endpoint numbers. On init it walks the
-- device's Matter endpoints and assigns them to spa functions:
--   main  : Thermostat cluster (water temp, heat setpoint, heating/idle)
--           or TemperatureMeasurement as a fallback for the reading
--   pump1 : Fan Control or Mode Select endpoint  -> Off / Low / High mode
--           (falls back to a plain On/Off endpoint -> Off / High)
--   light : On/Off endpoint whose device type is a light
--   pump2, pump3, pump4 : remaining On/Off endpoints, in order
--   range : On/Off endpoint 10 "Temperature range" (on = High, off = Low), shown as a Low/High dropdown
--   heaterA, heaterB : Temperature Sensor endpoints, by endpoint ID. The firmware has three:
--           the lowest is a duplicate of the water temp (hidden), the next two are
--           heater sensors A and B (EP 2 / 8 / 9 in the current sketch)
-- Any of these can be pinned to a specific endpoint in the device settings.
-- The final map is printed to the driver log on every init.

local capabilities = require "st.capabilities"
local clusters     = require "st.matter.clusters"
local MatterDriver = require "st.matter.driver"
local log          = require "log"

local OnOff        = clusters.OnOff
local Thermostat   = clusters.Thermostat
local TempMeas     = clusters.TemperatureMeasurement
local FanControl   = clusters.FanControl
local ModeSelect   = clusters.ModeSelect   -- may be nil on very old hub firmware
local BooleanState = clusters.BooleanState

local MODE_OFF, MODE_LOW, MODE_HIGH = "Off", "Low", "High"
local PUMP1_MODES = { MODE_OFF, MODE_LOW, MODE_HIGH }
-- Heat mode lives on the Thermostat's SystemMode: firmware maps HEAT (4) = Ready, OFF (0) = Rest.
-- The tile itself shows the spa's own heat mode from EP 13, including "Ready in rest".
local HEAT_READY, HEAT_REST = "Ready", "Rest"
local HEAT_READY_IN_REST = "Ready in rest"   -- display only: set to Rest, but heating during a filter cycle
local HEAT_MODES = { HEAT_READY, HEAT_REST, HEAT_READY_IN_REST }
local SYSMODE_OFF, SYSMODE_HEAT = 0, 4

local LIGHT_DEVICE_TYPES = {
  [0x0100] = true, -- On/Off Light
  [0x0101] = true, -- Dimmable Light
  [0x010C] = true, -- Color Temperature Light
  [0x010D] = true, -- Extended Color Light
}

local SWITCH_ROLES_IN_ORDER = { "pump2", "pump3", "pump4" }
local ALL_ROLES = { "thermostat", "pump1", "pump2", "pump3", "pump4", "light", "heaterA", "heaterB", "range",
                    "spaStatus", "circulation", "heatDetail", "filterCycle" }
local PREF_FOR_ROLE = {
  thermostat = "epThermostat", pump1 = "epPump1", pump2 = "epPump2", pump3 = "epPump3",
  pump4 = "epPump4", light = "epLight", heaterA = "epHeaterA", heaterB = "epHeaterB",
  range = "epRange",
  spaStatus = "epSpaStatus", circulation = "epCirculation", heatDetail = "epHeatDetail", filterCycle = "epFilterCycle",
}

local HEATER_DEFAULT_EP = { heaterA = 8, heaterB = 9 }   -- BalboaMatter sketch: heater sensors A / B
local RANGE_DEFAULT_EP = 10                               -- BalboaMatter sketch: temperature range (on = High)

-- Read-only status tiles (BalboaMatter EP 11-14). Shown as standard Mode tiles with a fixed text list.
-- The firmware's Mode Select mode numbers index these lists (0-based); EP 12 is a contact sensor.
local STATUS_TILES = {
  spaStatus   = { ep = 11, comp = "spaStatus",   pref = "epSpaStatus",
                  modes = { "Heating", "Heat waiting", "Idle", "Priming", "Startup cycle", "Settings reset",
                            "Initializing", "Hold", "Test mode", "Unknown" } },
  circulation = { ep = 12, comp = "circulation", pref = "epCirculation", modes = { "Running", "Off" } },
  -- EP 13 feeds the Heat mode tile itself (Ready / Rest / Ready in rest); Heat mode is still set via SystemMode.
  heatDetail  = { ep = 13, comp = "heatMode",    pref = "epHeatDetail",  modes = { "Ready", "Rest", "Ready in rest" } },
  filterCycle = { ep = 14, comp = "filterCycle", pref = "epFilterCycle",
                  modes = { "Off", "Filter 1", "Filter 2", "Filter 1 + 2" } },
}
local FIELD_TILE_VALUE = "tile_value_"   -- + role: last real value, re-emitted when someone picks another
local RANGE_LOW, RANGE_HIGH = "Low", "High"
local RANGE_MODES = { RANGE_LOW, RANGE_HIGH }
local FIELD_LIM_MIN = "limit_min_f"   -- setpoint limits from the firmware (follow the Low/High range)
local FIELD_LIM_MAX = "limit_max_f"

local FIELD_MAP        = "ep_map"         -- role -> endpoint id
local FIELD_PUMP1_KIND = "pump1_kind"     -- "fan" | "modeselect" | "onoff"
local FIELD_TEMP_KIND  = "temp_kind"      -- "thermostat" | "tempmeas"
local FIELD_MS_MODES   = "ms_modes"       -- Mode Select: tostring(mode) -> label

----------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------

local function raw(v)
  if type(v) == "table" and v.value ~= nil then return v.value end
  return v
end

local function f_to_c(f) return (f - 32) * 5 / 9 end
local function c_to_f(c) return c * 9 / 5 + 32 end

local function sorted_copy(t)
  local out = {}
  for _, v in ipairs(t or {}) do table.insert(out, v) end
  table.sort(out)
  return out
end

local function has_cluster(device, cluster)
  return cluster ~= nil and #device:get_endpoints(cluster.ID) > 0
end

local function endpoint_has_cluster(device, ep, cluster)
  if cluster == nil then return false end
  for _, e in ipairs(device:get_endpoints(cluster.ID)) do
    if e == ep then return true end
  end
  return false
end

local function endpoint_is_light(device, ep)
  for _, e in ipairs(device.endpoints or {}) do
    if e.endpoint_id == ep then
      for _, dt in ipairs(e.device_types or {}) do
        if LIGHT_DEVICE_TYPES[dt.device_type_id] then return true end
      end
    end
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

local function component_for_role(device, role)
  if role == "thermostat" then return device.profile.components.main end
  return device.profile.components[role]
end

local function emit(device, role, event)
  local comp = component_for_role(device, role)
  if comp then device:emit_component_event(comp, event) end
end

----------------------------------------------------------------------
-- endpoint discovery
----------------------------------------------------------------------

local function build_endpoint_map(device)
  local map, used = {}, {}
  local prefs = device.preferences or {}

  -- 1. user overrides
  for _, role in ipairs(ALL_ROLES) do
    local v = tonumber(prefs[PREF_FOR_ROLE[role]] or 0) or 0
    if v > 0 then map[role] = v; used[v] = true end
  end

  -- 2. heater / temperature
  if not map.thermostat then
    local ep = sorted_copy(device:get_endpoints(Thermostat.ID))[1]
            or sorted_copy(device:get_endpoints(TempMeas.ID))[1]
    if ep then map.thermostat = ep; used[ep] = true end
  end

  -- 2b. heater sensors A / B (Temperature Sensor endpoints, by endpoint ID)
  if not map.heaterA or not map.heaterB then
    local temps = {}
    for _, ep in ipairs(sorted_copy(device:get_endpoints(TempMeas.ID))) do
      if ep ~= 0 and not used[ep] then table.insert(temps, ep) end
    end
    -- With a real Thermostat endpoint, the lowest Temperature Sensor just repeats the water temp.
    if map.thermostat and endpoint_has_cluster(device, map.thermostat, Thermostat) and #temps > 0 then
      table.remove(temps, 1)
    end
    for _, role in ipairs({ "heaterA", "heaterB" }) do
      if not map[role] and #temps > 0 then map[role] = table.remove(temps, 1); used[map[role]] = true end
    end
  end
  -- SmartThings only knows the endpoints that existed when the spa was paired. If 8 / 9 were added by a
  -- later firmware update they aren't in its list, so fall back to the firmware's fixed IDs and talk to
  -- them directly.
  for role, ep in pairs(HEATER_DEFAULT_EP) do
    if not map[role] and not used[ep] then
      map[role] = ep; used[ep] = true
      log.info(string.format("[balboa] %s not in the paired endpoint list, using firmware default EP %d", role, ep))
    end
  end

  -- 2d. read-only status endpoints 11-14 (fixed IDs; added after pairing like 8/9/10)
  for role, t in pairs(STATUS_TILES) do
    if not map[role] and not used[t.ep] then map[role] = t.ep; used[t.ep] = true end
  end

  -- 2c. temperature range (On/Off plug, EP 10). Reserved before the pumps so it's never taken for a pump.
  -- Like 8/9 it was added after pairing, so it may be missing from SmartThings' endpoint list: use the fixed ID.
  if not map.range and not used[RANGE_DEFAULT_EP] then
    map.range = RANGE_DEFAULT_EP; used[RANGE_DEFAULT_EP] = true
  end

  -- 3. pump 1 (multi-speed)
  if not map.pump1 then
    local ep = sorted_copy(device:get_endpoints(FanControl.ID))[1]
    if not ep and ModeSelect then ep = sorted_copy(device:get_endpoints(ModeSelect.ID))[1] end
    if ep and not used[ep] then map.pump1 = ep; used[ep] = true end
  end

  -- 4. remaining On/Off endpoints
  local onoff = {}
  for _, ep in ipairs(sorted_copy(device:get_endpoints(OnOff.ID))) do
    if ep ~= 0 and not used[ep] then table.insert(onoff, ep) end
  end

  if not map.light then
    for i, ep in ipairs(onoff) do
      if endpoint_is_light(device, ep) then
        map.light = ep; used[ep] = true; table.remove(onoff, i); break
      end
    end
  end

  if not map.pump1 and #onoff > 0 then
    map.pump1 = table.remove(onoff, 1); used[map.pump1] = true
  end

  for _, role in ipairs(SWITCH_ROLES_IN_ORDER) do
    if not map[role] and #onoff > 0 then
      map[role] = table.remove(onoff, 1); used[map[role]] = true
    end
  end
  if not map.light and #onoff > 0 then map.light = table.remove(onoff, 1) end

  -- how pump 1 is driven
  local kind = "onoff"
  if map.pump1 then
    if endpoint_has_cluster(device, map.pump1, FanControl) then kind = "fan"
    elseif endpoint_has_cluster(device, map.pump1, ModeSelect) then kind = "modeselect" end
  end

  local temp_kind = "thermostat"
  if map.thermostat and not endpoint_has_cluster(device, map.thermostat, Thermostat) then
    temp_kind = "tempmeas"
  end

  device:set_field(FIELD_MAP, map, { persist = true })
  device:set_field(FIELD_PUMP1_KIND, kind, { persist = true })
  device:set_field(FIELD_TEMP_KIND, temp_kind, { persist = true })

  local parts = {}
  for _, role in ipairs(ALL_ROLES) do
    table.insert(parts, string.format("%s=%s", role, tostring(map[role] or "-")))
  end
  log.info(string.format("[balboa] endpoint map: %s | pump1 via %s | temp via %s",
    table.concat(parts, " "), kind, temp_kind))
  return map
end

----------------------------------------------------------------------
-- subscribe / refresh
----------------------------------------------------------------------

local function attribute_list(device)
  local map = get_map(device)
  local list = {}
  local function add(ep, attr) if ep and attr then table.insert(list, { ep = ep, attr = attr }) end end

  if map.thermostat then
    if device:get_field(FIELD_TEMP_KIND) == "tempmeas" then
      add(map.thermostat, TempMeas.attributes.MeasuredValue)
    else
      add(map.thermostat, Thermostat.attributes.LocalTemperature)
      add(map.thermostat, Thermostat.attributes.OccupiedHeatingSetpoint)
      add(map.thermostat, Thermostat.attributes.ThermostatRunningState)
      add(map.thermostat, Thermostat.attributes.PIHeatingDemand)
      add(map.thermostat, Thermostat.attributes.SystemMode)
      add(map.thermostat, Thermostat.attributes.MinHeatSetpointLimit)
      add(map.thermostat, Thermostat.attributes.MaxHeatSetpointLimit)
    end
  end

  local kind = device:get_field(FIELD_PUMP1_KIND)
  if map.pump1 then
    if kind == "fan" then
      add(map.pump1, FanControl.attributes.FanMode)
    elseif kind == "modeselect" then
      add(map.pump1, ModeSelect.attributes.SupportedModes)
      add(map.pump1, ModeSelect.attributes.CurrentMode)
    else
      add(map.pump1, OnOff.attributes.OnOff)
    end
  end

  for _, role in ipairs({ "pump2", "pump3", "pump4", "light" }) do
    add(map[role], OnOff.attributes.OnOff)
  end
  add(map.range, OnOff.attributes.OnOff)
  if ModeSelect then
    add(map.spaStatus, ModeSelect.attributes.CurrentMode)
    add(map.heatDetail, ModeSelect.attributes.CurrentMode)
    add(map.filterCycle, ModeSelect.attributes.CurrentMode)
  end
  if BooleanState then add(map.circulation, BooleanState.attributes.StateValue) end
  add(map.heaterA, TempMeas.attributes.MeasuredValue)
  add(map.heaterB, TempMeas.attributes.MeasuredValue)
  return list
end

local function subscribe(device)
  local req
  for _, a in ipairs(attribute_list(device)) do
    local ib = a.attr:subscribe(device, a.ep)
    if req == nil then req = ib else req:merge(ib) end
  end
  if req then device:send(req) end
end

local function refresh(device)
  local req
  for _, a in ipairs(attribute_list(device)) do
    local ib = a.attr:read(device, a.ep)
    if req == nil then req = ib else req:merge(ib) end
  end
  if req then device:send(req) end
end

-- Setpoint limits in °F: the firmware's Min/MaxHeatSetpointLimit (they follow the Low/High range) when
-- known, otherwise the Settings values.
local function setpoint_limits(device)
  local prefs = device.preferences or {}
  local min_f = device:get_field(FIELD_LIM_MIN) or tonumber(prefs.setpointMinF) or 80
  local max_f = device:get_field(FIELD_LIM_MAX) or tonumber(prefs.setpointMaxF) or 104
  if min_f > max_f then min_f, max_f = max_f, min_f end
  return min_f, max_f
end

local function emit_setpoint_range(device)
  local min_f, max_f = setpoint_limits(device)
  device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpointRange(
    { value = { minimum = min_f, maximum = max_f, step = 1 }, unit = "F" },
    { visibility = { displayed = false } }))
end

local function emit_supported_modes(device, comp_id, modes)
  local comp = device.profile.components[comp_id]
  if not comp then return end
  device:emit_component_event(comp, capabilities.mode.supportedModes(modes, { visibility = { displayed = false } }))
  if capabilities.mode.supportedArguments then
    device:emit_component_event(comp, capabilities.mode.supportedArguments(modes, { visibility = { displayed = false } }))
  end
end

local function emit_static(device)
  emit_setpoint_range(device)
  emit_supported_modes(device, "tempRange", RANGE_MODES)
  for _, t in pairs(STATUS_TILES) do emit_supported_modes(device, t.comp, t.modes) end
  -- Only Heating / Idle ever occur; the other spa states are in the Spa status tile.
  if capabilities.thermostatOperatingState.supportedThermostatOperatingStates then
    device:emit_event(capabilities.thermostatOperatingState.supportedThermostatOperatingStates(
      { "heating", "idle" }, { visibility = { displayed = false } }))
  end

  local pump1 = device.profile.components.pump1
  if pump1 then
    local modes = PUMP1_MODES
    if device:get_field(FIELD_PUMP1_KIND) == "onoff" then modes = { MODE_OFF, MODE_HIGH } end
    device:emit_component_event(pump1,
      capabilities.mode.supportedModes(modes, { visibility = { displayed = false } }))
    if capabilities.mode.supportedArguments then
      device:emit_component_event(pump1,
        capabilities.mode.supportedArguments(modes, { visibility = { displayed = false } }))
    end
  end

  emit_supported_modes(device, "heatMode", HEAT_MODES)
end

----------------------------------------------------------------------
-- attribute handlers
----------------------------------------------------------------------

local function onoff_handler(driver, device, ib, response)
  local role = role_for_endpoint(device, ib.endpoint_id)
  if not role then return end
  local on = raw(ib.data.value) == true
  if role == "pump1" then
    emit(device, "pump1", capabilities.mode.mode(on and MODE_HIGH or MODE_OFF))
  elseif role == "range" then
    emit(device, "tempRange", capabilities.mode.mode(on and RANGE_HIGH or RANGE_LOW))
  elseif role ~= "thermostat" then
    emit(device, role, on and capabilities.switch.switch.on() or capabilities.switch.switch.off())
  end
end

local OpState = capabilities.thermostatOperatingState.thermostatOperatingState

local function emit_heating(device, heating)
  emit(device, "thermostat", heating and OpState.heating() or OpState.idle())
end

local function local_temp_handler(driver, device, ib, response)
  local v = raw(ib.data.value)
  if v == nil then return end
  -- Report in °F (the spa's native unit), rounded to 0.1 °F
  local f = math.floor(c_to_f(v / 100.0) * 10 + 0.5) / 10
  emit(device, "thermostat", capabilities.temperatureMeasurement.temperature({ value = f, unit = "F" }, { state_change = true }))
end

-- Min/MaxHeatSetpointLimit (0.01 °C) -> slider limits in whole °F. During a range change the firmware
-- briefly widens them to 50-104 °F and then narrows them; each step just updates the slider.
local function setpoint_limit_handler(field)
  return function(driver, device, ib, response)
    if role_for_endpoint(device, ib.endpoint_id) ~= "thermostat" then return end
    local v = raw(ib.data.value)
    if type(v) ~= "number" then return end
    device:set_field(field, math.floor(c_to_f(v / 100.0) + 0.5), { persist = true })
    emit_setpoint_range(device)
  end
end

-- Thermostat SystemMode -> spa heat mode (HEAT = Ready, OFF = Rest)
local function system_mode_handler(driver, device, ib, response)
  if role_for_endpoint(device, ib.endpoint_id) ~= "thermostat" then return end
  local v = raw(ib.data.value)
  if v == nil then return end
  -- Once the spa's own heat mode (EP 13) has reported, it drives the tile: SystemMode can't tell
  -- Ready from Ready in rest.
  if device:get_field(FIELD_TILE_VALUE .. "heatDetail") then return end
  emit(device, "heatMode", capabilities.mode.mode(v == SYSMODE_OFF and HEAT_REST or HEAT_READY))
end

-- Temperature Sensor endpoints: heater sensors A / B, or the water temp when the device has no Thermostat.
-- MeasuredValue is null while the spa's A/B temps are off (booting, priming): the last known value is kept.
local function temp_sensor_handler(driver, device, ib, response)
  local role = role_for_endpoint(device, ib.endpoint_id)
  if role ~= "heaterA" and role ~= "heaterB" and role ~= "thermostat" then return end
  local v = raw(ib.data.value)
  if type(v) ~= "number" or v == -32768 then
    -- Unknown: send nothing, so the app keeps the last known reading (Routines never see a fake 0).
    log.debug(string.format("[balboa] %s: no reading (A/B temps off)", role))
    return
  end
  local f = math.floor(c_to_f(v / 100.0) * 10 + 0.5) / 10
  emit(device, role, capabilities.temperatureMeasurement.temperature({ value = f, unit = "F" }, { state_change = true }))
end

local function setpoint_handler(driver, device, ib, response)
  local v = raw(ib.data.value)
  if v == nil then return end
  -- Report in whole °F so the app's +/- moves in 1 °F steps
  local f = math.floor(c_to_f(v / 100.0) + 0.5)
  emit(device, "thermostat", capabilities.thermostatHeatingSetpoint.heatingSetpoint({ value = f, unit = "F" }))
end

local function running_state_handler(driver, device, ib, response)
  local v = raw(ib.data.value)
  if v == nil then return end
  device:set_field("has_running_state", true)
  emit_heating(device, (math.floor(v) % 2) == 1) -- bit 0 = Heat
end

local function heating_demand_handler(driver, device, ib, response)
  if device:get_field("has_running_state") then return end
  local v = raw(ib.data.value)
  if v == nil then return end
  device:set_field("has_heating_demand", true)
  emit_heating(device, v > 0)
end

local function fan_mode_handler(driver, device, ib, response)
  if role_for_endpoint(device, ib.endpoint_id) ~= "pump1" then return end
  local v = raw(ib.data.value)
  local mode = MODE_OFF
  if v == 1 or v == 2 then mode = MODE_LOW
  elseif v == 3 or v == 4 then mode = MODE_HIGH end
  emit(device, "pump1", capabilities.mode.mode(mode))
end

local function label_to_mode(label)
  local l = string.lower(label or "")
  if l:find("high") or l:find("hi") == 1 then return MODE_HIGH end
  if l:find("low") or l:find("lo") == 1 then return MODE_LOW end
  if l:find("off") then return MODE_OFF end
  return nil
end

local function supported_modes_handler(driver, device, ib, response)
  if role_for_endpoint(device, ib.endpoint_id) ~= "pump1" then return end
  local modes = {}
  for _, m in ipairs(ib.data.elements or {}) do
    local e = m.elements or {}
    local num = e.mode and raw(e.mode)
    local label = e.label and raw(e.label)
    if num ~= nil then modes[tostring(num)] = label or tostring(num) end
  end
  device:set_field(FIELD_MS_MODES, modes, { persist = true })
  log.info("[balboa] pump1 Mode Select modes: " .. (require "st.utils").stringify_table(modes))
end

local function emit_tile(device, role, value)
  device:set_field(FIELD_TILE_VALUE .. role, value, { persist = true })
  emit(device, STATUS_TILES[role].comp, capabilities.mode.mode(value))
end

local function circulation_handler(driver, device, ib, response)
  if role_for_endpoint(device, ib.endpoint_id) ~= "circulation" then return end
  local v = raw(ib.data.value)
  if type(v) ~= "boolean" then return end
  emit_tile(device, "circulation", v and "Running" or "Off")   -- StateValue true = running
end

local function current_mode_handler(driver, device, ib, response)
  local role = role_for_endpoint(device, ib.endpoint_id)
  if role and STATUS_TILES[role] and role ~= "circulation" then
    local v = raw(ib.data.value)
    if type(v) ~= "number" then return end
    local label = STATUS_TILES[role].modes[v + 1]
    if not label then
      log.warn(string.format("[balboa] %s: unexpected mode %s", role, tostring(v)))
      label = (role == "spaStatus") and "Unknown" or nil
    end
    if label then emit_tile(device, role, label) end
    return
  end
  if role ~= "pump1" then return end
  local v = raw(ib.data.value)
  local modes = device:get_field(FIELD_MS_MODES) or {}
  local mode = label_to_mode(modes[tostring(v)])
  if not mode then
    -- no labels yet: assume 0 = off, 1 = low, 2 = high
    mode = ({ [0] = MODE_OFF, [1] = MODE_LOW, [2] = MODE_HIGH })[v] or MODE_OFF
  end
  emit(device, "pump1", capabilities.mode.mode(mode))
end

----------------------------------------------------------------------
-- capability handlers
----------------------------------------------------------------------

local function endpoint_for_component(device, component)
  local role = (component == "main") and "thermostat" or component
  return get_map(device)[role], role
end

local function switch_cmd(on)
  return function(driver, device, cmd)
    local ep, role = endpoint_for_component(device, cmd.component)
    if not ep then
      log.warn("[balboa] no endpoint mapped for " .. tostring(role))
      return
    end
    if on then
      device:send(OnOff.server.commands.On(device, ep))
    else
      device:send(OnOff.server.commands.Off(device, ep))
    end
  end
end

-- Temperature range dropdown -> EP 10 On/Off (High = on, Low = off)
local function set_temp_range(driver, device, cmd)
  local ep = get_map(device).range
  if not ep then log.warn("[balboa] temperature range endpoint not mapped"); return end
  if cmd.args.mode == RANGE_HIGH then
    device:send(OnOff.server.commands.On(device, ep))
  else
    device:send(OnOff.server.commands.Off(device, ep))
  end
end

local function set_heat_mode(driver, device, cmd)
  if cmd.args.mode == HEAT_READY_IN_REST then
    -- not something you can set (the panel can't either): snap back to the real value
    local cur = device:get_field(FIELD_TILE_VALUE .. "heatDetail")
    if cur then
      device:emit_component_event(device.profile.components.heatMode, capabilities.mode.mode(cur, { state_change = true }))
    end
    return
  end
  local ep = get_map(device).thermostat
  if not ep or device:get_field(FIELD_TEMP_KIND) ~= "thermostat" then
    log.warn("[balboa] no Thermostat endpoint for heat mode"); return
  end
  local v = (cmd.args.mode == HEAT_REST) and SYSMODE_OFF or SYSMODE_HEAT
  device:send(Thermostat.attributes.SystemMode:write(device, ep, v))
end

local function set_pump1_mode(driver, device, cmd)
  local target = cmd.args.mode
  local ep = get_map(device).pump1
  if not ep then log.warn("[balboa] pump1 endpoint not mapped"); return end
  local kind = device:get_field(FIELD_PUMP1_KIND)

  if kind == "fan" then
    local v = ({ [MODE_OFF] = 0, [MODE_LOW] = 1, [MODE_HIGH] = 3 })[target] or 0
    device:send(FanControl.attributes.FanMode:write(device, ep, v))
  elseif kind == "modeselect" then
    local modes = device:get_field(FIELD_MS_MODES) or {}
    local num
    for k, label in pairs(modes) do
      if label_to_mode(label) == target then num = tonumber(k); break end
    end
    if num == nil then num = ({ [MODE_OFF] = 0, [MODE_LOW] = 1, [MODE_HIGH] = 2 })[target] or 0 end
    device:send(ModeSelect.server.commands.ChangeToMode(device, ep, num))
  else
    if target == MODE_OFF then
      device:send(OnOff.server.commands.Off(device, ep))
    else
      device:send(OnOff.server.commands.On(device, ep))
    end
  end
end

local function set_heating_setpoint(driver, device, cmd)
  local ep = get_map(device).thermostat
  if not ep or device:get_field(FIELD_TEMP_KIND) ~= "thermostat" then
    log.warn("[balboa] no Thermostat endpoint for setpoint"); return
  end
  local value = cmd.args.setpoint
  local f
  if value > 45 then f = math.floor(value + 0.5)                -- app sent °F
  else f = math.floor(c_to_f(value) + 0.5) end                    -- app sent °C
  local min_f, max_f = setpoint_limits(device)   -- the firmware clamps too
  if f < min_f then f = min_f elseif f > max_f then f = max_f end
  -- Matter carries the setpoint in 0.01 °C; the firmware rounds back to whole °F for the BP7
  device:send(Thermostat.attributes.OccupiedHeatingSetpoint:write(device, ep, math.floor(f_to_c(f) * 100 + 0.5)))
end

local function handle_refresh(driver, device, cmd) refresh(device) end

----------------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------------

-- Scheduled temperature read (Settings: pollMinutes, default 5, 0 = off). Matter only reports changes,
-- so without this a steady temperature leaves hours-long gaps in the history. Temperature events are
-- sent with state_change = true, so each read is recorded even when the value is the same.
local FIELD_POLL_TIMER = "temp_poll_timer"

local function poll_temperatures(device)
  local map = get_map(device)
  local req
  local function add(attr, ep)
    if not ep then return end
    local ib = attr:read(device, ep)
    if req == nil then req = ib else req:merge(ib) end
  end
  if map.thermostat then
    if device:get_field(FIELD_TEMP_KIND) == "tempmeas" then add(TempMeas.attributes.MeasuredValue, map.thermostat)
    else add(Thermostat.attributes.LocalTemperature, map.thermostat) end
  end
  add(TempMeas.attributes.MeasuredValue, map.heaterA)
  add(TempMeas.attributes.MeasuredValue, map.heaterB)
  if req then device:send(req) end
end

local function schedule_poll(device)
  local old = device:get_field(FIELD_POLL_TIMER)
  if old then device.thread:cancel_timer(old); device:set_field(FIELD_POLL_TIMER, nil) end
  local minutes = tonumber((device.preferences or {}).pollMinutes) or 5
  if minutes <= 0 then log.info("[balboa] scheduled temperature read off"); return end
  local t = device.thread:call_on_schedule(minutes * 60, function() poll_temperatures(device) end,
    "balboa-temp-poll")
  device:set_field(FIELD_POLL_TIMER, t)
  log.info(string.format("[balboa] reading temperatures every %d min", minutes))
end

local function device_init(driver, device)
  -- An earlier build could move the spa to a reduced profile without the heater tiles; move it back.
  if device.profile.components.heaterA == nil then
    log.info("[balboa] restoring full balboa-spa profile")
    device:try_update_metadata({ profile = "balboa-spa" })
  end
  build_endpoint_map(device)
  emit_static(device)
  subscribe(device)
  schedule_poll(device)
end

local function device_added(driver, device)
  refresh(device)
end

local function info_changed(driver, device, event, args)
  local changed = false
  for _, p in pairs(PREF_FOR_ROLE) do
    if args.old_st_store.preferences[p] ~= device.preferences[p] then changed = true end
  end
  if changed then
    build_endpoint_map(device)
    subscribe(device)
    refresh(device)
  end
  if args.old_st_store.preferences.pollMinutes ~= device.preferences.pollMinutes then schedule_poll(device) end
  emit_static(device)
end

----------------------------------------------------------------------
-- driver
----------------------------------------------------------------------

local attr_handlers = {
  [OnOff.ID] = { [OnOff.attributes.OnOff.ID] = onoff_handler },
  [Thermostat.ID] = {
    [Thermostat.attributes.LocalTemperature.ID] = local_temp_handler,
    [Thermostat.attributes.OccupiedHeatingSetpoint.ID] = setpoint_handler,
    [Thermostat.attributes.ThermostatRunningState.ID] = running_state_handler,
    [Thermostat.attributes.PIHeatingDemand.ID] = heating_demand_handler,
    [Thermostat.attributes.SystemMode.ID] = system_mode_handler,
    [Thermostat.attributes.MinHeatSetpointLimit.ID] = setpoint_limit_handler(FIELD_LIM_MIN),
    [Thermostat.attributes.MaxHeatSetpointLimit.ID] = setpoint_limit_handler(FIELD_LIM_MAX),
  },
  [TempMeas.ID] = { [TempMeas.attributes.MeasuredValue.ID] = temp_sensor_handler },
  [FanControl.ID] = { [FanControl.attributes.FanMode.ID] = fan_mode_handler },
}
if BooleanState then
  attr_handlers[BooleanState.ID] = { [BooleanState.attributes.StateValue.ID] = circulation_handler }
end
if ModeSelect then
  attr_handlers[ModeSelect.ID] = {
    [ModeSelect.attributes.SupportedModes.ID] = supported_modes_handler,
    [ModeSelect.attributes.CurrentMode.ID] = current_mode_handler,
  }
end

local driver = MatterDriver("balboa-spa-controller", {
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    infoChanged = info_changed,
    removed = function(driver, device)
      local t = device:get_field(FIELD_POLL_TIMER)
      if t then device.thread:cancel_timer(t) end
    end,
  },
  matter_handlers = { attr = attr_handlers },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = switch_cmd(true),
      [capabilities.switch.commands.off.NAME] = switch_cmd(false),
    },
    [capabilities.mode.ID] = {
      [capabilities.mode.commands.setMode.NAME] = function(driver, device, cmd)
        if cmd.component == "heatMode" then return set_heat_mode(driver, device, cmd) end
        if cmd.component == "tempRange" then return set_temp_range(driver, device, cmd) end
        for role, t in pairs(STATUS_TILES) do
          if cmd.component == t.comp then
            -- read-only: snap the tile back to the real value
            log.info(string.format("[balboa] %s is read-only, ignoring '%s'", t.comp, tostring(cmd.args.mode)))
            local cur = device:get_field(FIELD_TILE_VALUE .. role)
            if cur then
              device:emit_component_event(device.profile.components[t.comp],
                capabilities.mode.mode(cur, { state_change = true }))
            end
            return
          end
        end
        return set_pump1_mode(driver, device, cmd)
      end,
    },
    [capabilities.thermostatHeatingSetpoint.ID] = {
      [capabilities.thermostatHeatingSetpoint.commands.setHeatingSetpoint.NAME] = set_heating_setpoint,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
    },
  },
  supported_capabilities = {
    capabilities.temperatureMeasurement,
    capabilities.thermostatHeatingSetpoint,
    capabilities.thermostatOperatingState,
    capabilities.mode,
    capabilities.switch,
    capabilities.refresh,
  },
})

log.info("[balboa] Balboa Spa Controller driver starting")
driver:run()
