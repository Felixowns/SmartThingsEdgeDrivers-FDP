-- SmartThings Edge driver: Honeywell Home (Resideo) T10 / T10+ Pro thermostat over HomeKit, locally from the hub.
-- The hub pairs with the thermostat as a HomeKit controller, keeps one encrypted HAP session open and
-- receives temperature, setpoints, mode, operating state, humidity, fan and RedLINK room sensor events.
-- No Resideo cloud, no Apple device, no bridge computer.
--
-- Adapted from "Honeywell T6 (HomeKit local)" by Stoeckie
-- (https://github.com/Stoeckie/smartthings-honeywell-t6-homekit-local, Apache 2.0): the HomeKit controller
-- and crypto files are used unchanged; this file and t10_model.lua were changed for the T10 (cooling, auto
-- thresholds, °F, fan, room sensors as child devices; the T6 heat demand feature was removed).
local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local log = require "log"
local cosock = require "cosock"
local json = require "st.json"
local hap = require "hap_client"
local bignum = require "bignum"
local model_lib = require "t10_model"
local emitq = require "emitq"  -- only changed values go to the hub (see emitq.lua)

local BUILD = "2026-11-10c"
local TAG = "[t10]"
local PAIR_MAX_FAILS = 5
local REQUEST_TIMEOUT = 15
local POLL_SECS = 300
local IDLE_POLL = 900   -- only poll when nothing came in for this long (Honeywell drops sessions after polls)
local RECONNECT_MIN, RECONNECT_MAX = 3, 300
local READ_IDLE = 20    -- reader loop wakes up this often to see whether the session is still wanted
local CODE_WAIT = 300   -- seconds the hub waits for the HomeKit code during pairing

local RECORD_DEFAULT_MIN = 5 -- "Record interval": temperature / humidity sent at least this often (0 = only on change)
local MAIN_PROFILE, FAN_PROFILE = "honeywell-t10", "honeywell-t10-fan"
-- T9 and T10 report the same HomeKit model ("T9/T10 (+)"); the T9 has no humidifier control, so a thermostat
-- without a humidity target gets a T9 profile (with a filter section only if it exposes one)
local T9_PROFILE, T9_FILTER_PROFILE = "honeywell-t9", "honeywell-t9-filter"
local CIRC_TICK = 60          -- circulate: check once a minute whether the fan should run
local CIRC_DEFAULT_MIN = 20   -- circulate: default fan minutes per hour (Honeywell runs about a third of the time)

local tempMeas = capabilities.temperatureMeasurement
local heatSp = capabilities.thermostatHeatingSetpoint
local coolSp = capabilities.thermostatCoolingSetpoint
local tMode = capabilities.thermostatMode
local opState = capabilities.thermostatOperatingState
local fanMode = capabilities.thermostatFanMode
local humidity = capabilities.relativeHumidityMeasurement
local motion = capabilities.motionSensor
local battery = capabilities.battery
local level = capabilities.switchLevel
local filterStatus = capabilities.filterStatus
local momentary = capabilities.momentary
local MAX_FILTERS = 2 -- components filter1, filter2 in the profile

hap.json = json
hap.sleep = function(s) cosock.socket.sleep(s) end

local function now()
  local ok, t = pcall(cosock.socket.gettime)
  return ok and t or os.time()
end

math.randomseed(math.floor((now() * 1000000) % 2147483647))
bignum.yield_hook = function() cosock.socket.sleep(0) end -- SRP modpow runs for seconds: let others run

local conns = {}        -- parent device.id -> connection state
local discovered = {}   -- dni -> { ip, port, id, name }
local TREE_LOGGED = false

local function is_child(dev) return dev.parent_assigned_child_key ~= nil end

local function pref_bool(dev, name, default)
  local v = dev.preferences and dev.preferences[name]
  if v == nil then return default end
  return v == true
end

-- display unit: HomeKit is always °C; the user picks what SmartThings shows
local function unit_of(dev)
  local u = dev.preferences and dev.preferences.tempUnit
  return u == "C" and "C" or "F"
end

local function disp(c, unit, decimals)
  local v = tonumber(c)
  if not v then return nil end
  if unit == "F" then v = model_lib.c_to_f(v) end
  local m = 10 ^ (decimals or 0)
  local r = math.floor(v * m + 0.5) / m
  if decimals == 0 then r = math.floor(r) end
  return r
end

-- connection drops are only logged (dev:offline() shows them in the app)
local function note_drop(dev, reason)
  if dev:get_field("conn_drop") then return end
  dev:set_field("conn_drop", { at = os.time(), reason = tostring(reason or "unknown"):sub(1, 120) })
end
local function report_drop(dev)
  local d = dev:get_field("conn_drop")
  if type(d) ~= "table" then return end
  dev:set_field("conn_drop", nil)
  log.info(string.format("%s back after %d s (%s)", TAG, math.max(0, os.time() - d.at), tostring(d.reason)))
end

-- pairing storage -----------------------------------------------------------------------------------
local function tohex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
local function fromhex(h) return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end)) end

local function uuid4()
  local b = { hap.random_bytes(16):byte(1, 16) }
  b[7] = (b[7] & 0x0f) | 0x40
  b[9] = (b[9] & 0x3f) | 0x80
  local h = string.format(string.rep("%02X", 16), table.unpack(b))
  return h:sub(1, 8) .. "-" .. h:sub(9, 12) .. "-" .. h:sub(13, 16) .. "-" .. h:sub(17, 20) .. "-" .. h:sub(21, 32)
end

local function load_pairing(dev)
  local p = dev:get_field("hap_pairing")
  if type(p) ~= "table" or not p.controller_id then return nil end
  return { controller_id = p.controller_id, controller_seed = fromhex(p.controller_seed),
           controller_pub = fromhex(p.controller_pub), accessory_id = p.accessory_id,
           accessory_pub = fromhex(p.accessory_pub) }
end

local function save_pairing(dev, p)
  dev:set_field("hap_pairing", {
    controller_id = p.controller_id, controller_seed = tohex(p.controller_seed),
    controller_pub = tohex(p.controller_pub), accessory_id = p.accessory_id,
    accessory_pub = tohex(p.accessory_pub) }, { persist = true })
end

local function get_pair_fails(dev) return tonumber((dev:get_field("pair_fails"))) or 0 end
local function set_pair_fails(dev, n) dev:set_field("pair_fails", n, { persist = true }) end

-- addressing / mDNS ------------------------------------------------------------------------------------
local function parse_txt(txt)
  local t = {}
  local function take(tbl)
    if type(tbl) ~= "table" then return end
    for k, v in pairs(tbl) do
      if type(k) == "number" then
        if type(v) == "table" then
          local ok, str = pcall(function() return string.char(table.unpack(v)) end)
          v = ok and str or ""
        end
        local kk, vv = tostring(v):match("^([^=]+)=(.*)$")
        if kk then t[kk:lower()] = vv end
      elseif type(k) == "string" and k ~= "text" then
        t[k:lower()] = tostring(v)
      end
    end
  end
  if type(txt) == "table" then
    take(txt.text)
    take(txt)
  end
  return t
end

-- HomeKit category 9 = thermostat. Prefer answers whose name/model looks like Honeywell / Resideo / T10 / T9,
-- else accept any HomeKit thermostat.
local function mdns_scan()
  local ok, mdns = pcall(require, "st.mdns")
  if not ok then
    log.warn(TAG .. " st.mdns not available on this hub firmware; set IP and port in the device settings")
    return {}
  end
  local res, err = mdns.discover("_hap._tcp", "local")
  if not res then
    log.warn(TAG .. " mDNS discover failed: " .. tostring(err))
    return {}
  end
  local named, thermostats = {}, {}
  log.info(string.format("%s mDNS: %d HomeKit device(s) answered", TAG, #(res.found or {})))
  for _, f in ipairs(res.found or {}) do
    local host, svc, txt = f.host_info or {}, f.service_info or {}, parse_txt(f.txt)
    local name = tostring(svc.name or "")
    log.info(string.format("%s   %s at %s:%s ci=%s md=%s sf=%s", TAG, name, tostring(host.address),
      tostring(host.port), tostring(txt.ci), tostring(txt.md), tostring(txt.sf)))
    local hay = (name .. " " .. tostring(txt.md or "")):upper()
    local ip = host.address and tostring(host.address)
    if ip and ip:match("^%d+%.%d+%.%d+%.%d+$") and txt.id then
      local e = { ip = ip, port = tonumber(host.port), id = txt.id, name = name, paired = txt.sf == "0",
                  model = txt.md }
      if hay:find("HONEYWELL", 1, true) or hay:find("RESIDEO", 1, true) or hay:find("T10", 1, true)
         or hay:find("T9", 1, true) or hay:find("THX", 1, true) or hay:find("LYRIC", 1, true) then
        named[#named + 1] = e
      elseif txt.ci == "9" then
        thermostats[#thermostats + 1] = e
      end
    end
  end
  return #named > 0 and named or thermostats
end

local function address(dev)
  local p = dev.preferences or {}
  local ip = p.ipAddress
  if ip == nil or ip == "" or ip == "auto" then ip = dev:get_field("ip") end
  local port = tonumber(p.hapPort)
  if not port or port == 0 then port = dev:get_field("port") end
  return ip, port
end

local function pick_answer(dev, found)
  local id, ip = dev:get_field("hap_id"), dev:get_field("ip")
  for _, f in ipairs(found) do if id and f.id == id then return f end end
  for _, f in ipairs(found) do if ip and f.ip == ip then return f end end
  if not id and not ip and #found == 1 then return found[1] end
  return nil
end

local function refresh_address(dev)
  local f = pick_answer(dev, mdns_scan())
  if not f then return false end
  if dev:get_field("ip") ~= f.ip or dev:get_field("port") ~= f.port then
    log.info(string.format("%s thermostat %s at %s:%s", TAG, f.id, f.ip, tostring(f.port)))
  end
  dev:set_field("ip", f.ip, { persist = true })
  dev:set_field("port", f.port, { persist = true })
  dev:set_field("hap_id", f.id, { persist = true })
  return true
end

local function open_socket(dev, timeout)
  local ip, port = address(dev)
  if not ip or not port then
    refresh_address(dev)
    ip, port = address(dev)
  end
  if not ip or not port then return nil, "thermostat address unknown (not found via mDNS; set IP and port)" end
  local sock = cosock.socket.tcp()
  sock:settimeout(timeout or 15)
  local ok, err = sock:connect(ip, port)
  if not ok then
    sock:close()
    return nil, string.format("connect %s:%s failed: %s", ip, tostring(port), tostring(err))
  end
  return sock, nil, ip
end

-- room sensor child devices -----------------------------------------------------------------------------
local function find_child(driver, parent, key)
  local ok, ch = pcall(parent.get_child_by_parent_assigned_key, parent, key)
  if ok and ch then return ch end
  for _, d in ipairs(driver:get_devices()) do
    if d.parent_device_id == parent.id and d.parent_assigned_child_key == key then return d end
  end
  return nil
end

-- room sensors share the thermostat's HomeKit session: their online state follows it
local function set_children_health(driver, parent, online)
  for _, d in ipairs(driver:get_devices()) do
    if d.parent_device_id == parent.id then
      pcall(function() if online then d:online() else d:offline() end end)
    end
  end
end

local function sensor_profile(s)
  if s.has.battery or s.has.low_battery then return "honeywell-t10-sensor-hmb" end
  if s.has.occupancy or s.has.motion then return "honeywell-t10-sensor-hm" end
  if s.has.humidity then return "honeywell-t10-sensor-h" end
  return "honeywell-t10-sensor"
end

local function emit_sensor(driver, parent, model, key, fields)
  local s = model.sensors[key]
  if not s then return end
  local child = find_child(driver, parent, key)
  if not child then return end
  local v, unit = s.values, unit_of(parent)
  local function t(f) return fields == nil or fields[f] end
  local ok, err = pcall(function()
    if t("temp") and tonumber(v.temp) then
      emitq.emit(child, tempMeas.temperature({ value = disp(v.temp, unit, 1), unit = unit }))
    end
    if t("humidity") and tonumber(v.humidity) and child:supports_capability(humidity) then
      emitq.emit(child, humidity.humidity(math.floor(tonumber(v.humidity) + 0.5)))
    end
    if child:supports_capability(motion) then
      if t("occupancy") and v.occupancy ~= nil then
        local on = tonumber(v.occupancy) == 1 or v.occupancy == true
        emitq.emit(child, on and motion.motion.active() or motion.motion.inactive())
      elseif t("motion") and v.motion ~= nil then
        emitq.emit(child, (v.motion == true or v.motion == 1) and motion.motion.active() or motion.motion.inactive())
      end
    end
    if child:supports_capability(battery) then
      if t("battery") and tonumber(v.battery) then
        emitq.emit(child, battery.battery(math.floor(tonumber(v.battery) + 0.5)))
      elseif t("low_battery") and v.low_battery ~= nil and not s.has.battery then
        emitq.emit(child, battery.battery(tonumber(v.low_battery) == 1 and 10 or 100))
      end
    end
  end)
  if not ok then log.warn(TAG .. " sensor " .. tostring(key) .. ": " .. tostring(err)) end
end

local function ensure_children(driver, dev, model)
  if not pref_bool(dev, "roomSensors", true) then return end
  for _, key in ipairs(model.sensor_keys) do
    local s = model.sensors[key]
    if not find_child(driver, dev, key) then
      log.info(string.format("%s creating room sensor device '%s' (%s)", TAG, s.name, key))
      driver:try_create_device({
        type = "EDGE_CHILD", parent_device_id = dev.id, parent_assigned_child_key = key,
        label = s.name, vendor_provided_label = s.name, profile = sensor_profile(s),
        manufacturer = "Honeywell", model = "Room sensor",
      })
    end
  end
end

-- state -> events ----------------------------------------------------------------------------------------
local function emit_main(dev, model, fields)
  local v, unit = model.main.values, unit_of(dev)
  local all = fields == nil
  local function t(f) return all or fields[f] end
  local sp_change = t("tgt_state") or t("tgt_temp") or t("heat_th") or t("cool_th")
  if t("cur_temp") and tonumber(v.cur_temp) then
    emitq.emit(dev, tempMeas.temperature({ value = disp(v.cur_temp, unit, 1), unit = unit }))
  end
  if sp_change then
    local hf, cf = model_lib.setpoint_field(model, "heat"), model_lib.setpoint_field(model, "cool")
    local dec = unit == "F" and 0 or 1
    if hf and tonumber(v[hf]) then
      emitq.emit(dev, heatSp.heatingSetpoint({ value = disp(v[hf], unit, dec), unit = unit }))
    end
    if cf and tonumber(v[cf]) then
      emitq.emit(dev, coolSp.coolingSetpoint({ value = disp(v[cf], unit, dec), unit = unit }))
    end
  end
  if t("tgt_state") then
    local name = model_lib.MODE_NAME[tonumber(v.tgt_state)]
    if name and tMode.thermostatMode[name] then emitq.emit(dev, tMode.thermostatMode[name]()) end
  end
  if t("cur_state") or t("fan_current") or t("fan_on") then
    local name = model_lib.STATE_NAME[tonumber(v.cur_state)]
    if name == "idle" and (tonumber(v.fan_current) == 2) then name = "fan only" end
    local key = name and name:gsub(" ", "_")
    if key and opState.thermostatOperatingState[key] then
      emitq.emit(dev, opState.thermostatOperatingState[key]())
    end
  end
  if t("humidity") and tonumber(v.humidity) and dev:supports_capability(humidity) then
    emitq.emit(dev, humidity.humidity(math.floor(tonumber(v.humidity) + 0.5)))
  end
  local comps = dev.profile and dev.profile.components or {}
  if t("hum_target") and tonumber(v.hum_target) and comps.humidityTarget then
    emitq.emit(dev, level.level(math.floor(tonumber(v.hum_target) + 0.5)), comps.humidityTarget)
  end
  for i = 1, MAX_FILTERS do
    local f, comp = "f" .. i, comps["filter" .. i]
    if comp and t(f .. "_change") and v[f .. "_change"] ~= nil then
      local replace = tonumber(v[f .. "_change"]) == 1 or v[f .. "_change"] == true
      emitq.emit(dev, replace and filterStatus.filterStatus.replace() or filterStatus.filterStatus.normal(), comp)
    end
  end
  if model.fan_kind and dev:supports_capability(fanMode) and (t("fan_target") or t("fan_active") or t("fan_on")) then
    local on
    if model.fan_kind == "v2" then
      on = tonumber(v.fan_target) ~= 1 and tonumber(v.fan_active) == 1
    else
      on = v.fan_on == true or tonumber(v.fan_on) == 1
    end
    if dev:get_field("fan_sel") == "circulate" then
      emitq.emit(dev, fanMode.thermostatFanMode.circulate())
    else
      emitq.emit(dev, on and fanMode.thermostatFanMode.on() or fanMode.thermostatFanMode.auto())
    end
  end
end

local function emit_static(dev, model)
  local unit = unit_of(dev)
  local modes = model_lib.supported_modes(model)
  pcall(function()
    emitq.emit(dev, tMode.supportedThermostatModes(modes, { visibility = { displayed = false } }))
  end)
  if model.fan_kind and dev:supports_capability(fanMode) then
    pcall(function()
      emitq.emit(dev, fanMode.supportedThermostatFanModes({ "auto", "on", "circulate" }, { visibility = { displayed = false } }))
    end)
  end
  local function range(field)
    local m = model.main.meta[field] or {}
    local lo, hi = m.min or 10, m.max or 35
    if unit == "F" then
      return { minimum = math.ceil(model_lib.c_to_f(lo) - 0.01), maximum = math.floor(model_lib.c_to_f(hi) + 0.01),
               step = 1 }
    end
    return { minimum = lo, maximum = hi, step = (m.step and m.step > 0) and m.step or 0.5 }
  end
  local hf = model.main.chars.heat_th and "heat_th" or "tgt_temp"
  local cf = model.main.chars.cool_th and "cool_th" or "tgt_temp"
  pcall(function()
    emitq.emit(dev, heatSp.heatingSetpointRange({ value = range(hf), unit = unit }, { visibility = { displayed = false } }))
  end)
  pcall(function()
    emitq.emit(dev, coolSp.coolingSetpointRange({ value = range(cf), unit = unit }, { visibility = { displayed = false } }))
  end)
  local comps = dev.profile and dev.profile.components or {}
  local hm = model.main.meta.hum_target
  if hm and comps.humidityTarget then
    pcall(function()
      emitq.emit(dev, level.levelRange({ value = { minimum = hm.min or 0, maximum = hm.max or 100 } },
        { visibility = { displayed = false } }), comps.humidityTarget)
    end)
  end
  log.info(string.format("%s %s %s (fw %s), modes %s, fan %s, %d room sensor(s)", TAG,
    tostring(model.info.manufacturer), tostring(model.info.model), tostring(model.info.firmware),
    table.concat(modes, "/"), tostring(model.fan_kind or "none"), #model.sensor_keys))
end

local function emit_all(driver, dev, model, touched)
  local ok, err = pcall(function()
    if touched == nil then
      emit_main(dev, model, nil)
      for _, key in ipairs(model.sensor_keys) do emit_sensor(driver, dev, model, key, nil) end
      return
    end
    for owner, fields in pairs(touched) do
      if owner == "main" then emit_main(dev, model, fields) else emit_sensor(driver, dev, model, owner, fields) end
    end
  end)
  if not ok then log.error(TAG .. " emit: " .. tostring(err)) end
end

-- log the HomeKit tree once per start: needed to check the mapping on a new model
local function log_tree(accs)
  if TREE_LOGGED then return end
  TREE_LOGGED = true
  for _, acc in ipairs(accs or {}) do
    local parts = {}
    for _, svc in ipairs(acc.services or {}) do
      local cs = {}
      for _, ch in ipairs(svc.characteristics or {}) do
        local val = ch.value
        if type(val) == "string" then val = '"' .. val:sub(1, 24) .. '"' end
        cs[#cs + 1] = model_lib.short(ch.type) .. "#" .. tostring(ch.iid) .. "=" .. tostring(val)
      end
      parts[#parts + 1] = model_lib.short(svc.type) .. "{" .. table.concat(cs, " ") .. "}"
    end
    log.info(string.format("%s tree aid %s: %s", TAG, tostring(acc.aid), table.concat(parts, " ")))
  end
end

local function apply_profile(dev, model)
  local want
  if model.main.chars.hum_target or model.fan_kind then
    want = model.fan_kind and FAN_PROFILE or MAIN_PROFILE
  else
    want = (model.filter_count or 0) > 0 and T9_FILTER_PROFILE or T9_PROFILE
  end
  local have = dev:get_field("profile_name") or MAIN_PROFILE
  if have ~= want then
    local ok, err = pcall(dev.try_update_metadata, dev, { profile = want })
    if ok then
      dev:set_field("profile_name", want, { persist = true })
      log.info(TAG .. " profile -> " .. want)
    else
      log.warn(TAG .. " profile change failed: " .. tostring(err))
    end
  end
end

-- session --------------------------------------------------------------------------------------------------
local function close_conn(c)
  c.alive = false
  if c.sock then pcall(function() c.sock:close() end) end
  c.sock = nil
end

local function make_waiter(c)
  return function()
    local deadline = now() + REQUEST_TIMEOUT
    while #c.responses == 0 do
      if not c.alive then return nil, "connection closed" end
      if now() > deadline then
        log.warn(TAG .. " no response from the thermostat: reconnecting")
        c.close_reason = "no response"
        close_conn(c)
        return nil, "timeout"
      end
      cosock.socket.sleep(0.05)
    end
    return table.remove(c.responses, 1)
  end
end

local function session_once(driver, dev, c, sock, ip, pairing, on_up)
  local drop_reason
  c.sock, c.alive, c.responses = sock, true, {}
  local s = hap.session(sock, { host = ip })
  c.session = s
  local ok, verr = s:pair_verify(pairing)
  local accs, model
  if ok then accs, verr = s:accessories() end
  if accs then
    log_tree(accs)
    model, verr = model_lib.build(accs)
  end
  if model then
    c.model = model
    local _, serr = s:subscribe(model.ev_ids)
    if serr then log.warn(TAG .. " subscribe: " .. tostring(serr)) end
    apply_profile(dev, model)
    dev:online()
    set_children_health(driver, dev, true)
    report_drop(dev)
    emit_static(dev, model)
    ensure_children(driver, dev, model)
    emit_all(driver, dev, model, nil)
    c.last_rx = now()
    c.circ_run = nil -- circulate: re-send the fan state on the next tick
    log.info(TAG .. " session up")
    on_up()
    sock:settimeout(READ_IDLE)
    s.on_event = function(chars)
      local touched = model_lib.apply(model, chars)
      if touched then emit_all(driver, dev, model, touched) end
    end
    s.wait_response = make_waiter(c)
    while c.alive do
      local msg, rerr = s:read_message()
      if msg then
        c.last_rx = now()
        if msg.event then s:_dispatch_event(msg) else c.responses[#c.responses + 1] = msg end
      elseif rerr == "timeout" and c.alive then
        -- idle
      else
        if c.alive then log.warn(TAG .. " session closed: " .. tostring(rerr)) end
        drop_reason = "session closed: " .. tostring(c.alive and rerr or (c.close_reason or rerr))
        break
      end
    end
  else
    log.error(TAG .. " session setup failed: " .. tostring(verr))
    drop_reason = "session setup failed: " .. tostring(verr)
    if tostring(verr):find("unknown accessory id") or tostring(verr):find("authentication") then
      log.error(TAG .. " the thermostat no longer knows this hub; use Remove pairing and pair again")
    end
  end
  return drop_reason
end

local function run_session(driver, dev, c)
  local backoff = RECONNECT_MIN
  while c and not c.stopped do
    local pairing = load_pairing(dev)
    if not pairing then
      log.info(TAG .. " not paired yet")
      return
    end
    local drop_reason
    local sock, err, ip = open_socket(dev, 20)
    if sock and c.stopped then
      pcall(function() sock:close() end)
      return
    end
    if sock then
      local ok, res = pcall(session_once, driver, dev, c, sock, ip, pairing, function() backoff = RECONNECT_MIN end)
      if ok then drop_reason = res else
        log.error(TAG .. " session error: " .. tostring(res))
        drop_reason = "session error: " .. tostring(res)
      end
      close_conn(c)
    else
      log.warn(TAG .. " " .. tostring(err))
      drop_reason = "no connection: " .. tostring(err)
    end
    if c.stopped then return end
    note_drop(dev, drop_reason)
    -- Honeywell thermostats close the HomeKit session now and then; only show offline after a failed retry
    if backoff > RECONNECT_MIN then
      dev:offline()
      set_children_health(driver, dev, false)
    end
    cosock.socket.sleep(backoff)
    backoff = math.min(backoff * 2, RECONNECT_MAX)
    refresh_address(dev)
  end
end

local function start_session(driver, dev)
  local old = conns[dev.id]
  if old then
    old.stopped = true
    close_conn(old)
  end
  local c = { responses = {}, dev = dev }
  conns[dev.id] = c
  cosock.spawn(function() run_session(driver, dev, c) end, "t10-session-" .. dev.id)
end

-- pairing --------------------------------------------------------------------------------------------------
local function normalize_pin(pin)
  local d = tostring(pin or ""):gsub("%D", "")
  if #d ~= 8 then return nil end
  return d:sub(1, 3) .. "-" .. d:sub(4, 5) .. "-" .. d:sub(6, 8)
end

local function pair(driver, dev)
  if not conns[dev.id] or conns[dev.id].stopped then conns[dev.id] = { responses = {}, dev = dev } end
  local c = conns[dev.id]
  if c.pairing then return end
  c.pairing, c.new_pin = true, nil
  local function again(delay)
    local fails = get_pair_fails(dev) + 1
    set_pair_fails(dev, fails)
    if fails >= PAIR_MAX_FAILS then
      log.error(string.format("%s pairing failed %d times: no more automatic attempts. Enter the HomeKit code"
        .. " in the settings again to retry", TAG, fails))
      return
    end
    dev.thread:call_with_delay(delay, function() if not load_pairing(dev) then pair(driver, dev) end end)
  end
  local sock
  local function attempt()
    refresh_address(dev)
    local err, ip
    sock, err, ip = open_socket(dev, 120)
    if not sock then
      log.warn(TAG .. " pairing: " .. tostring(err) .. " (HomeKit not active? retry in 60 s)")
      c.pairing = false
      again(60)
      return
    end
    local t0 = now()
    local s = hap.session(sock, { host = ip })
    -- The code from the settings is used once per value. If the thermostat makes a new code per attempt
    -- (like the T6), or no code was entered yet, the hub waits for the user to type the one on the display.
    local function get_pin()
      local p = normalize_pin(dev.preferences and dev.preferences.homekitCode)
      if p and dev:get_field("tried_pin") ~= p then
        dev:set_field("tried_pin", p, { persist = true })
        return p
      end
      log.info(TAG .. " >>> enter the HomeKit code shown on the thermostat in the device settings within 5 minutes")
      local deadline = now() + CODE_WAIT
      while not c.new_pin and now() < deadline and not c.stopped do cosock.socket.sleep(1) end
      local pin = c.new_pin
      c.new_pin = nil
      if not pin then return nil, "no code entered within 5 minutes" end
      dev:set_field("tried_pin", pin, { persist = true })
      return pin
    end
    log.info(TAG .. " pairing started")
    local p, perr = s:pair_setup(get_pin, uuid4(), { yield = function() cosock.socket.sleep(0) end,
      progress = function(m) log.info(string.format("%s pairing: %s (%.0f s)", TAG, m, now() - t0)) end })
    pcall(function() sock:close() end)
    c.pairing = false
    if not p then
      local e = tostring(perr)
      log.error(TAG .. " pairing failed: " .. e)
      if e:find("HomeKit error 2") then
        log.error(TAG .. " wrong code: check the code on the thermostat screen (Menu > Connect HomeKit)")
        again(10)
      elseif e:find("HomeKit error [56]") then
        log.error(TAG .. " the thermostat refuses pairing (already paired with Apple Home or too many tries):"
          .. " remove it from Apple Home or reset HomeKit on the thermostat; retry in 10 min")
        again(600)
      else
        again(60)
      end
      return
    end
    save_pairing(dev, p)
    set_pair_fails(dev, nil)
    dev:set_field("tried_pin", nil, { persist = true })
    log.info(string.format("%s paired in %.0f s with accessory %s", TAG, now() - t0, tostring(p.accessory_id)))
    start_session(driver, dev)
  end
  cosock.spawn(function()
    local ok, e = pcall(attempt)
    if not ok and c.pairing then
      log.error(TAG .. " pairing error: " .. tostring(e))
      if sock then pcall(function() sock:close() end) end
      c.pairing = false
      again(60)
    end
  end, "t10-pair-" .. dev.id)
end

local function unpair(driver, dev)
  local c = conns[dev.id]
  local p = load_pairing(dev)
  if not p then return end
  cosock.spawn(function()
    local ok, err
    if c and c.session and c.alive then ok, err = c.session:remove_pairing(p.controller_id) end
    if c then
      c.stopped = true
      close_conn(c)
    end
    dev:set_field("hap_pairing", nil, { persist = true })
    log.info(TAG .. " pairing removed" .. (ok and "" or (" locally (thermostat: " .. tostring(err) .. ")")))
  end, "t10-unpair")
end

-- commands ---------------------------------------------------------------------------------------------------
local function parent_of(driver, dev)
  if is_child(dev) then return driver:get_device_info(dev.parent_device_id) end
  return dev
end

-- items: list of { field, value } on the thermostat accessory
local function write(driver, dev, items, what)
  local c = conns[dev.id]
  if not (c and c.alive and c.model) then
    log.warn(TAG .. " " .. what .. ": not connected")
    return false
  end
  local puts, applied = {}, {}
  for _, it in ipairs(items) do
    local ref = c.model.main.chars[it[1]]
    if not ref then
      log.warn(TAG .. " " .. what .. ": the thermostat has no " .. it[1])
      return false
    end
    puts[#puts + 1] = { aid = ref.aid, iid = ref.iid, value = it[2] }
    applied[#applied + 1] = { aid = ref.aid, iid = ref.iid, value = it[2] }
  end
  local _, err = c.session:put(puts)
  if err then
    log.error(TAG .. " " .. what .. " failed: " .. tostring(err))
    return false
  end
  local touched = model_lib.apply(c.model, applied)
  if touched then emit_all(driver, dev, c.model, touched) end
  return true
end

local function set_setpoint(driver, dev, which, raw)
  local c = conns[dev.id]
  if not (c and c.model) then
    log.warn(TAG .. " setpoint: not connected")
    return
  end
  local cval = model_lib.to_celsius(raw)
  if not cval then return end
  local field = model_lib.setpoint_field(c.model, which)
  if not field then
    log.warn(string.format("%s %s setpoint cannot be set in mode %s", TAG, which,
      tostring(model_lib.MODE_NAME[tonumber(c.model.main.values.tgt_state)])))
    return
  end
  local v = model_lib.clamp(c.model.main, field, cval)
  log.info(string.format("%s %s setpoint %s -> %s = %s °C", TAG, which, tostring(raw), field, tostring(v)))
  write(driver, dev, { { field, v } }, which .. " setpoint")
end

local function handle_heat_sp(driver, dev, cmd)
  cosock.spawn(function() set_setpoint(driver, dev, "heat", cmd.args.setpoint) end, "t10-heat-sp")
end

local function handle_cool_sp(driver, dev, cmd)
  cosock.spawn(function() set_setpoint(driver, dev, "cool", cmd.args.setpoint) end, "t10-cool-sp")
end

local function set_mode(driver, dev, name)
  local v = model_lib.MODE_VALUE[name]
  if v == nil then
    log.warn(TAG .. " unsupported mode " .. tostring(name))
    return
  end
  cosock.spawn(function() write(driver, dev, { { "tgt_state", v } }, "mode " .. name) end, "t10-mode")
end

-- HomeKit fan items for "run" (true) or "auto" (false)
local function fan_items(model, run)
  local kind = model.fan_kind
  if kind == "v2" then
    if not model.main.chars.fan_target then return { { "fan_active", run and 1 or 0 } } end
    return run and { { "fan_active", 1 }, { "fan_target", 0 } } or { { "fan_target", 1 } }
  end
  return { { "fan_on", run and true or false } }
end

local function set_fan(driver, dev, name)
  local c = conns[dev.id]
  if not (c and c.model and c.model.fan_kind) then
    log.warn(TAG .. " fan: the thermostat exposes no fan over HomeKit")
    return
  end
  if name ~= "auto" and name ~= "on" and name ~= "circulate" then
    log.warn(TAG .. " unsupported fan mode " .. tostring(name))
    return
  end
  dev:set_field("fan_sel", name, { persist = true })
  c.circ_run = nil
  if name == "circulate" then
    -- start a new cycle now: the fan runs first, then rests for the rest of the hour
    dev:set_field("circ_start", os.time(), { persist = true })
    pcall(function() emitq.emit(dev, fanMode.thermostatFanMode.circulate()) end)
    cosock.spawn(function()
      c.circ_run = true
      if not write(driver, dev, fan_items(c.model, true), "fan circulate (run)") then c.circ_run = nil end
    end, "t10-fan")
    return
  end
  cosock.spawn(function() write(driver, dev, fan_items(c.model, name == "on"), "fan " .. name) end, "t10-fan")
end

-- circulate: HomeKit has no circulate mode, so the hub switches the fan on for circulateMinutes of every
-- hour and back to auto for the rest. Heating or cooling runs the fan anyway, so nothing is forced then.
local function circulate_tick(driver, dev)
  if dev:get_field("fan_sel") ~= "circulate" then return end
  local c = conns[dev.id]
  if not (c and c.alive and c.model and c.model.fan_kind) then return end
  local mins = tonumber(dev.preferences and dev.preferences.circulateMinutes) or CIRC_DEFAULT_MIN
  local start = tonumber((dev:get_field("circ_start"))) or os.time()
  local minute = ((os.time() - start) // 60) % 60
  local run = minute < mins
  if c.circ_run == run then return end
  log.info(string.format("%s circulate: fan %s (minute %d of the hour, %d min on)", TAG, run and "on" or "auto",
    minute, mins))
  if write(driver, dev, fan_items(c.model, run), "fan circulate") then c.circ_run = run end
end

local function handle_set_level(driver, dev, cmd)
  if cmd.component ~= "humidityTarget" then return end
  local c = conns[dev.id]
  if not (c and c.model and c.model.main.chars.hum_target) then
    log.warn(TAG .. " humidity target: not available")
    return
  end
  local m = c.model.main.meta.hum_target or {}
  local v = math.floor((tonumber(cmd.args.level) or 0) + 0.5)
  if m.min and v < m.min then v = math.ceil(m.min) end
  if m.max and v > m.max then v = math.floor(m.max) end
  cosock.spawn(function() write(driver, dev, { { "hum_target", v } }, "humidity target " .. v) end, "t10-hum")
end

local poll -- defined below

local function handle_filter_reset(driver, dev, cmd)
  local n = tostring(cmd.component or ""):match("^filter(%d+)$")
  local c = conns[dev.id]
  local field = n and ("f" .. n .. "_reset")
  if not (n and c and c.model and c.model.main.chars[field]) then
    log.warn(TAG .. " filter reset: not available for " .. tostring(cmd.component))
    return
  end
  cosock.spawn(function()
    if write(driver, dev, { { field, 1 } }, "filter " .. n .. " reset") then
      cosock.socket.sleep(2)
      poll(driver, dev, true) -- the thermostat clears the change indication itself
    end
  end, "t10-filter")
end

poll = function(driver, dev, forced)
  local c = conns[dev.id]
  if not (c and c.alive and c.model) then return end
  if not forced and c.last_rx and now() - c.last_rx < IDLE_POLL then return end
  local chars, err = c.session:get(c.model.ids)
  if chars then
    local touched = model_lib.apply(c.model, chars)
    if touched then emit_all(driver, dev, c.model, touched) end
  else
    log.warn(TAG .. " poll failed: " .. tostring(err))
  end
end

-- record interval ------------------------------------------------------------------------------------------
local function record_secs(dev)
  local m = tonumber(dev.preferences and dev.preferences.recordInterval)
  if m == nil then m = RECORD_DEFAULT_MIN end
  return math.max(0, math.floor(m * 60))
end

-- Send temperature and humidity of the thermostat and every room sensor at least once per interval, so the
-- SmartThings history has a data point even when nothing changed. Values come from the live push session;
-- the thermostat is only polled first when nothing at all came in during the interval.
local function record_tick(driver, dev)
  local secs = record_secs(dev)
  if secs <= 0 then return end
  local c = conns[dev.id]
  if not (c and c.alive and c.model) then return end
  if not c.last_rx or now() - c.last_rx >= secs then poll(driver, dev, true) end
  if not (c.alive and c.model) then return end
  local model, unit = c.model, unit_of(dev)
  local min_age = math.max(0, secs - 30) -- skip what was already sent this interval (a real change)
  local sent = 0
  local function rec(target, values, tfield)
    local ok, err = pcall(function()
      if tonumber(values[tfield]) then
        if emitq.record(target, tempMeas.temperature({ value = disp(values[tfield], unit, 1), unit = unit }), nil, min_age) then
          sent = sent + 1
        end
      end
      if tonumber(values.humidity) and target:supports_capability(humidity) then
        if emitq.record(target, humidity.humidity(math.floor(tonumber(values.humidity) + 0.5)), nil, min_age) then
          sent = sent + 1
        end
      end
    end)
    if not ok then log.warn(TAG .. " record: " .. tostring(err)) end
  end
  rec(dev, model.main.values, "cur_temp")
  for _, key in ipairs(model.sensor_keys) do
    local child = find_child(driver, dev, key)
    if child then rec(child, model.sensors[key].values, "temp") end
  end
  log.debug(string.format("%s record: %d data point(s) sent", TAG, sent))
end

local function schedule_record(driver, dev)
  local old = dev:get_field("rec_timer")
  if old then pcall(dev.thread.cancel_timer, dev.thread, old) end
  dev:set_field("rec_timer", nil)
  local secs = record_secs(dev)
  if secs <= 0 then
    log.info(TAG .. " record interval off: temperature / humidity only sent on change")
    return
  end
  dev:set_field("rec_timer", dev.thread:call_on_schedule(secs, function()
    cosock.spawn(function() record_tick(driver, dev) end, "t10-record")
  end, "t10-record"))
  log.info(string.format("%s record interval %d min", TAG, secs // 60))
end

local function handle_refresh(driver, dev)
  local p = parent_of(driver, dev)
  if not p then return end
  cosock.spawn(function()
    poll(driver, p, true)
    -- a room sensor device the user removed is created again on a refresh of the thermostat
    local c = conns[p.id]
    if c and c.model then ensure_children(driver, p, c.model) end
  end, "t10-refresh")
end

-- lifecycle ----------------------------------------------------------------------------------------------------
local function device_init(driver, dev)
  if is_child(dev) then
    local c = conns[dev.parent_device_id]
    if c and c.alive and c.model and c.dev then
      dev:online()
      emit_sensor(driver, c.dev, c.model, dev.parent_assigned_child_key, nil)
    end
    return
  end
  hap.rng.seed(dev:get_field("rng_pool"))
  hap.rng.save = function(p) dev:set_field("rng_pool", tohex(p), { persist = true }) end
  local old_timer = dev:get_field("poll_timer")
  if old_timer then pcall(dev.thread.cancel_timer, dev.thread, old_timer) end
  dev:set_field("poll_timer", dev.thread:call_on_schedule(POLL_SECS, function()
    cosock.spawn(function() poll(driver, dev) end, "t10-poll")
  end, "t10-poll"))
  schedule_record(driver, dev)
  local old_circ = dev:get_field("circ_timer")
  if old_circ then pcall(dev.thread.cancel_timer, dev.thread, old_circ) end
  dev:set_field("circ_timer", dev.thread:call_on_schedule(CIRC_TICK, function()
    cosock.spawn(function() circulate_tick(driver, dev) end, "t10-circulate")
  end, "t10-circulate"))
  if load_pairing(dev) then start_session(driver, dev) else pair(driver, dev) end
end

local function device_added(driver, dev)
  if not is_child(dev) then
    local d = discovered[dev.device_network_id]
    if d then
      dev:set_field("ip", d.ip, { persist = true })
      dev:set_field("port", d.port, { persist = true })
      dev:set_field("hap_id", d.id, { persist = true })
    end
  end
  device_init(driver, dev)
end

local function info_changed(driver, dev, event, args)
  if is_child(dev) then return end
  local old = (args and args.old_st_store and args.old_st_store.preferences) or {}
  local new = dev.preferences or {}
  if new.resetPairing and not old.resetPairing then
    unpair(driver, dev)
    return
  end
  if old.ipAddress ~= new.ipAddress or old.hapPort ~= new.hapPort then
    if load_pairing(dev) then start_session(driver, dev) end
  end
  local c = conns[dev.id]
  if old.tempUnit ~= new.tempUnit and c and c.model then
    emit_static(dev, c.model)
    emit_all(driver, dev, c.model, nil)
  end
  if old.roomSensors ~= new.roomSensors and c and c.model then ensure_children(driver, dev, c.model) end
  if old.recordInterval ~= new.recordInterval then schedule_record(driver, dev) end
  if old.homekitCode ~= new.homekitCode and not load_pairing(dev) then
    local pin = normalize_pin(new.homekitCode)
    if pin and c and c.pairing then
      c.new_pin = pin
      log.info(TAG .. " code received")
    elseif pin then
      log.info(TAG .. " code received: starting pairing")
      set_pair_fails(dev, nil)
      pair(driver, dev)
    end
  end
end

local function device_removed(driver, dev)
  emitq.forget(dev)
  if is_child(dev) then return end
  local c = conns[dev.id]
  if c then
    c.stopped = true
    close_conn(c)
    conns[dev.id] = nil
  end
end

local function discovery(driver, opts, should_continue)
  local found = mdns_scan()
  log.info(string.format("%s discovery: %d HomeKit thermostat(s)", TAG, #found))
  local existing, by_id, by_ip, any = {}, {}, {}, false
  for _, dev in ipairs(driver:get_devices()) do
    if not is_child(dev) then
      any = true
      existing[dev.device_network_id] = dev
      local hid, hip = dev:get_field("hap_id"), dev:get_field("ip")
      if hid then by_id[hid] = dev end
      if hip then by_ip[hip] = dev end
    end
  end
  for _, f in ipairs(found) do
    local dni = "t10-hap-" .. f.id:gsub(":", ""):lower()
    discovered[dni] = f
    local known = existing[dni] or by_id[f.id] or by_ip[f.ip]
    if known then
      known:set_field("ip", f.ip, { persist = true })
      known:set_field("port", f.port, { persist = true })
      known:set_field("hap_id", f.id, { persist = true })
    else
      log.info(string.format("%s new thermostat %s '%s' at %s:%s (%s)", TAG, f.id, f.name, f.ip, tostring(f.port),
        f.paired and "already paired with another controller" or "ready to pair"))
      driver:try_create_device({
        type = "LAN", device_network_id = dni, label = "Honeywell T10", profile = MAIN_PROFILE,
        manufacturer = "Honeywell", model = f.model or "T10 Pro", vendor_provided_label = "Honeywell T10",
      })
    end
  end
  if #found == 0 and not any then
    driver:try_create_device({
      type = "LAN", device_network_id = "t10-hap-manual", label = "Honeywell T10", profile = MAIN_PROFILE,
      manufacturer = "Honeywell", model = "T10 Pro", vendor_provided_label = "Honeywell T10",
    })
  end
end

local driver = Driver("honeywell-t10-homekit", {
  discovery = discovery,
  lifecycle_handlers = { init = device_init, added = device_added, infoChanged = info_changed,
                         removed = device_removed },
  capability_handlers = {
    [capabilities.refresh.ID] = { [capabilities.refresh.commands.refresh.NAME] = handle_refresh },
    [level.ID] = { [level.commands.setLevel.NAME] = handle_set_level },
    [momentary.ID] = { [momentary.commands.push.NAME] = handle_filter_reset },
    [heatSp.ID] = { [heatSp.commands.setHeatingSetpoint.NAME] = handle_heat_sp },
    [coolSp.ID] = { [coolSp.commands.setCoolingSetpoint.NAME] = handle_cool_sp },
    [tMode.ID] = {
      [tMode.commands.setThermostatMode.NAME] = function(d, dev, cmd) set_mode(d, dev, cmd.args.mode) end,
      [tMode.commands.heat.NAME] = function(d, dev) set_mode(d, dev, "heat") end,
      [tMode.commands.cool.NAME] = function(d, dev) set_mode(d, dev, "cool") end,
      [tMode.commands.auto.NAME] = function(d, dev) set_mode(d, dev, "auto") end,
      [tMode.commands.off.NAME] = function(d, dev) set_mode(d, dev, "off") end,
    },
    [fanMode.ID] = {
      [fanMode.commands.setThermostatFanMode.NAME] = function(d, dev, cmd) set_fan(d, dev, cmd.args.mode) end,
      [fanMode.commands.fanAuto.NAME] = function(d, dev) set_fan(d, dev, "auto") end,
      [fanMode.commands.fanOn.NAME] = function(d, dev) set_fan(d, dev, "on") end,
      [fanMode.commands.fanCirculate.NAME] = function(d, dev) set_fan(d, dev, "circulate") end,
    },
  },
})

log.info(TAG .. " Honeywell T10 (HomeKit local) driver starting, build " .. BUILD)
driver:run()
