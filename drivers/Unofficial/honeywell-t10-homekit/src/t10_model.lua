-- Map a HomeKit /accessories tree from a Honeywell Home T10 / T10+ Pro (or T9) to SmartThings:
--   * the Thermostat service (heat / cool / auto with heating and cooling thresholds, humidity)
--   * an optional Fan service (v1 "On" or v2 "Active" + "TargetFanState")
--   * the RedLINK room sensors, which HomeKit shows as extra temperature / humidity / occupancy
--     (and battery) services, normally one bridged accessory per sensor
-- Based on t6_model.lua from Stoeckie/smartthings-honeywell-t6-homekit-local (Apache 2.0), extended for
-- cooling, auto thresholds, fan and room sensors.
local M = {}

local SUFFIX = "-0000-1000-8000-0026BB765291"

--- HomeKit type ("35", "00000035-0000-1000-8000-0026BB765291") -> short upper form "35"
function M.short(t)
  t = tostring(t or ""):upper()
  if t:sub(-#SUFFIX) == SUFFIX then t = t:sub(1, -#SUFFIX - 1) end
  t = t:gsub("^0+", "")
  return t
end

-- services
local S = { info = "3E", thermostat = "4A", hum = "82", temp = "8A", occupancy = "86", motion = "85",
            battery = "96", fan1 = "40", fan2 = "B7", filter = "BA" }
-- characteristics
local C = { name = "23", manufacturer = "20", model = "21", serial = "30", firmware = "52",
            cur_state = "F", tgt_state = "33", cur_temp = "11", tgt_temp = "35", units = "36", hum = "10",
            cool_th = "D", heat_th = "12", on = "25", active = "B0", tgt_fan = "BF", cur_fan = "AF",
            occupancy = "71", motion = "22", battery = "68", low_battery = "79", hum_target = "34",
            filter_change = "AC", filter_life = "AB", filter_reset = "AD" }

-- HomeKit TargetHeatingCoolingState / CurrentHeatingCoolingState values
M.MODE_NAME = { [0] = "off", [1] = "heat", [2] = "cool", [3] = "auto" }
M.MODE_VALUE = { off = 0, heat = 1, cool = 2, auto = 3 }
M.STATE_NAME = { [0] = "idle", [1] = "heating", [2] = "cooling" }

local function chars_by_type(svc)
  local out = {}
  for _, ch in ipairs(svc.characteristics or {}) do out[M.short(ch.type)] = ch end
  return out
end

local function has_perm(ch, p)
  for _, x in ipairs(ch.perms or {}) do if x == p then return true end end
  return false
end

local function new_owner(key, name, aid)
  return { key = key, name = name, aid = aid, chars = {}, values = {}, meta = {}, has = {} }
end

-- owner = M.main or a sensor table; field = our name for the characteristic
local function add(model, owner, aid, ch, field)
  if not ch or owner.chars[field] then return end
  owner.chars[field] = { aid = aid, iid = ch.iid }
  owner.values[field] = ch.value
  owner.meta[field] = { min = tonumber(ch.minValue), max = tonumber(ch.maxValue), step = tonumber(ch.minStep),
                        valid = ch["valid-values"] }
  owner.has[field] = true
  model.index[aid .. "." .. ch.iid] = { owner = owner.key, field = field }
  -- write-only characteristics (filter reset) must not be read or subscribed: the request would fail
  if has_perm(ch, "pr") or ch.perms == nil then model.ids[#model.ids + 1] = { aid, ch.iid } end
  if has_perm(ch, "ev") or ch.perms == nil then model.ev_ids[#model.ev_ids + 1] = { aid, ch.iid } end
end

local function svc_name(chs, fallback)
  local n = chs[C.name] and chs[C.name].value
  if type(n) == "string" and n ~= "" then return n end
  return fallback
end

-- add the sensor characteristics of one service to a sensor owner; true when something was added
local function add_sensor_service(model, owner, aid, st, ch)
  if st == S.temp and ch[C.cur_temp] then add(model, owner, aid, ch[C.cur_temp], "temp"); return true end
  if st == S.hum and ch[C.hum] then add(model, owner, aid, ch[C.hum], "humidity"); return true end
  if st == S.occupancy and ch[C.occupancy] then add(model, owner, aid, ch[C.occupancy], "occupancy"); return true end
  if st == S.motion and ch[C.motion] then add(model, owner, aid, ch[C.motion], "motion"); return true end
  if st == S.battery then
    local any = false
    if ch[C.battery] then add(model, owner, aid, ch[C.battery], "battery"); any = true end
    if ch[C.low_battery] then add(model, owner, aid, ch[C.low_battery], "low_battery"); any = true end
    return any
  end
  return false
end

--- Build the model.
--- model = { aid, name, info, main = owner, fan_kind = nil|"v1"|"v2", sensors = {key -> owner}, sensor_keys = {..},
---           index = {"aid.iid" -> {owner, field}}, ids = {{aid,iid}..}, ev_ids = {..} }
--- owner = { key, name, aid, chars = {field -> {aid,iid}}, values = {field -> v}, meta = {field -> {min,max,step,valid}},
---           has = {field -> true} }
--- Returns nil, err when there is no thermostat.
function M.build(accessories)
  local thermo_acc
  for _, acc in ipairs(accessories or {}) do
    for _, svc in ipairs(acc.services or {}) do
      if M.short(svc.type) == S.thermostat then thermo_acc = thermo_acc or acc end
    end
  end
  if not thermo_acc then return nil, "no thermostat service found" end

  local model = { aid = thermo_acc.aid, name = "Thermostat", info = {}, sensors = {}, sensor_keys = {},
                  index = {}, ids = {}, ev_ids = {} }
  local main = new_owner("main", "Thermostat", thermo_acc.aid)
  model.main = main
  local aid = thermo_acc.aid

  for _, svc in ipairs(thermo_acc.services or {}) do
    local st, ch = M.short(svc.type), chars_by_type(svc)
    if st == S.info then
      for field, ct in pairs({ manufacturer = C.manufacturer, model = C.model, serial = C.serial,
                               firmware = C.firmware }) do
        if ch[ct] then model.info[field] = ch[ct].value end
      end
      model.name = svc_name(ch, model.name)
    elseif st == S.thermostat then
      add(model, main, aid, ch[C.cur_state], "cur_state")
      add(model, main, aid, ch[C.tgt_state], "tgt_state")
      add(model, main, aid, ch[C.cur_temp], "cur_temp")
      add(model, main, aid, ch[C.tgt_temp], "tgt_temp")
      add(model, main, aid, ch[C.heat_th], "heat_th")
      add(model, main, aid, ch[C.cool_th], "cool_th")
      add(model, main, aid, ch[C.hum], "humidity")
      add(model, main, aid, ch[C.units], "units")
      add(model, main, aid, ch[C.hum_target], "hum_target")
    elseif st == S.fan2 and ch[C.active] then
      model.fan_kind = model.fan_kind or "v2"
      add(model, main, aid, ch[C.active], "fan_active")
      add(model, main, aid, ch[C.tgt_fan], "fan_target")
      add(model, main, aid, ch[C.cur_fan], "fan_current")
    elseif st == S.fan1 and ch[C.on] and not model.fan_kind then
      model.fan_kind = "v1"
      add(model, main, aid, ch[C.on], "fan_on")
    elseif st == S.filter and ch[C.filter_change] then
      -- filter maintenance services in order: filter1, filter2, ...
      model.filter_count = (model.filter_count or 0) + 1
      local n = "f" .. model.filter_count
      add(model, main, aid, ch[C.filter_change], n .. "_change")
      add(model, main, aid, ch[C.filter_life], n .. "_life")
      add(model, main, aid, ch[C.filter_reset], n .. "_reset")
    -- the thermostat's own Occupancy service is left out on purpose: it is Honeywell's "room occupied"
    -- state (stays occupied long after movement), not live motion, and showed as "motion detected"
    elseif st == S.hum and not main.chars.humidity then
      add(model, main, aid, ch[C.hum], "humidity")
    elseif st == S.temp then
      -- an extra temperature service inside the thermostat accessory: treat it as its own room sensor
      local key = "a" .. aid .. "s" .. tostring(svc.iid)
      local owner = new_owner(key, svc_name(ch, "Room sensor"), aid)
      if add_sensor_service(model, owner, aid, st, ch) then
        model.sensors[key] = owner
        model.sensor_keys[#model.sensor_keys + 1] = key
      end
    end
  end

  -- every other accessory with sensor services = one room sensor (RedLINK sensors are bridged accessories)
  for _, acc in ipairs(accessories or {}) do
    if acc ~= thermo_acc then
      local key = "a" .. tostring(acc.aid)
      local owner = new_owner(key, "Room sensor " .. tostring(acc.aid), acc.aid)
      local any = false
      for _, svc in ipairs(acc.services or {}) do
        local st, ch = M.short(svc.type), chars_by_type(svc)
        if st == S.info then
          owner.name = svc_name(ch, owner.name)
        elseif add_sensor_service(model, owner, acc.aid, st, ch) then
          any = true
        end
      end
      if any then
        model.sensors[key] = owner
        model.sensor_keys[#model.sensor_keys + 1] = key
      end
    end
  end
  return model
end

--- Apply a list of {aid, iid, value}; returns { owner_key -> {field -> true} } or nil when nothing changed.
function M.apply(model, chars)
  local touched
  for _, c in ipairs(chars or {}) do
    local e = model.index[tostring(c.aid) .. "." .. tostring(c.iid)]
    if e and c.value ~= nil then
      local owner = e.owner == "main" and model.main or model.sensors[e.owner]
      if owner then
        owner.values[e.field] = c.value
        touched = touched or {}
        touched[e.owner] = touched[e.owner] or {}
        touched[e.owner][e.field] = true
      end
    end
  end
  return touched
end

--- Thermostat modes the device accepts (from valid-values, else from maxValue).
function M.supported_modes(model)
  local out, meta = {}, model.main.meta.tgt_state
  local valid = meta and meta.valid
  if type(valid) == "table" and #valid > 0 then
    for _, v in ipairs(valid) do
      local n = M.MODE_NAME[tonumber(v)]
      if n then out[#out + 1] = n end
    end
  end
  if #out == 0 then
    local max = meta and meta.max or 3
    for v = 0, math.min(3, max) do out[#out + 1] = M.MODE_NAME[v] end
  end
  return out
end

--- Which characteristic holds the heating / cooling setpoint in the current mode.
--- heat mode: TargetTemperature; cool mode: TargetTemperature; auto (and off): the thresholds.
function M.setpoint_field(model, which)
  local ch, mode = model.main.chars, tonumber(model.main.values.tgt_state)
  if which == "heat" then
    if mode == 1 and ch.tgt_temp then return "tgt_temp" end
    if ch.heat_th then return "heat_th" end
    if mode ~= 2 and ch.tgt_temp then return "tgt_temp" end
  else
    if mode == 2 and ch.tgt_temp then return "tgt_temp" end
    if ch.cool_th then return "cool_th" end
    if mode ~= 1 and ch.tgt_temp then return "tgt_temp" end
  end
  return nil
end

-- HomeKit always works in Celsius.
function M.c_to_f(c) return c * 9 / 5 + 32 end
function M.f_to_c(f) return (f - 32) * 5 / 9 end

--- A setpoint from SmartThings in °C. unit is the unit of the command ("F"/"C"/nil). Without a unit, a value
--- above 40 is taken as °F (no sensible Celsius setpoint is that high).
function M.to_celsius(value, unit)
  local v = tonumber(value)
  if not v then return nil end
  if unit == "F" or (unit ~= "C" and v > 40) then v = M.f_to_c(v) end
  return v
end

--- Clamp and round a °C value to a characteristic's range and step (defaults 10..35 °C, step 0.5).
function M.clamp(owner, field, value)
  local m = owner.meta[field] or {}
  local lo, hi, step = m.min or 10, m.max or 35, m.step
  if not step or step <= 0 then step = 0.5 end
  local v = tonumber(value) or lo
  v = math.floor(v / step + 0.5) * step
  if v < lo then v = lo end
  if v > hi then v = hi end
  return math.floor(v * 100 + 0.5) / 100
end

return M
