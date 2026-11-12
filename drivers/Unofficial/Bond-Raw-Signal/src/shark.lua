-- Shark misting fan (custom). Every remote button toggles or steps through a cycle and the fan
-- cannot report state, so each feature is tracked and reached by counting button presses.
--   Toggle (TogglePower)          power on/off
--   Increase/Decrease Speed       speed 1..5
--   "Speed 8" (SetSpeed 8)        boost on/off
--   "Summer" (SetDirection)       mist cycle:   Off -> High -> Medium -> Low -> Off
--   "Reverse" (ToggleDirection)   swing cycle:  Off -> Narrow -> Medium -> Wide -> Off
--   "Breeze" (BreezeOn)           breeze cycle: off -> 1 -> 2 -> off
local capabilities = require "st.capabilities"
local socket       = require "cosock.socket"
local log          = require "log"
local bond         = require "bond"
local U            = require "util"

local M = {}
local sw = capabilities.switch.switch
local MAX_SPEED = 5

local SIG = {
  power = { "TogglePower" }, boost = { "SetSpeed", 8 }, mist = { "SetDirection" },
  swing = { "ToggleDirection" }, breeze = { "BreezeOn" },
  up = { "IncreaseSpeed" }, down = { "DecreaseSpeed" },
}
-- Dropdown values in button-press order (first entry = off)
local ORDER = {
  mist   = { "Off", "High", "Medium", "Low" },
  swing  = { "Off", "Narrow", "Medium", "Wide" },
  breeze = { "Off", "Breeze 1", "Breeze 2" },
}
-- Dropdown display order
local LIST = {
  mist   = { "Off", "Low", "Medium", "High" },
  swing  = { "Off", "Narrow", "Medium", "Wide" },
  breeze = { "Off", "Breeze 1", "Breeze 2" },
}

local function get(device, f, default)
  local v = device:get_field(f)
  if v == nil then return default end
  if (f == "mist" or f == "swing" or f == "breeze") and type(v) ~= "string" then return "Off" end
  return v
end
local function set(device, f, v) device:set_field(f, v, { persist = true }) end
local function comp(device, id) return device.profile.components[id] end

local function press(device, key, n)
  n = n or 1
  if n <= 0 then return true end
  local s = SIG[key]
  local sig = U.sig(U.info(device), s[1], s[2])
  if not sig then
    log.warn(string.format("[%s] no raw signal for %s", device.label, key))
    return false
  end
  local gap = (tonumber(device.preferences.pressMs) or 900) / 1000
  log.info(string.format("[%s] %s x%d", device.label, key, n))
  for i = 1, n do
    bond.tx(device, sig, 1)
    if i < n then socket.sleep(gap) end
  end
  return true
end

-- ---- speed step mapping (4 SmartThings steps -> 5 speeds) ----
local function ui_to_speed(device, ui)
  local v = tonumber(device.preferences["speedMap" .. ui]) or 0
  if v > 0 then return math.max(1, math.min(MAX_SPEED, v)) end
  return math.max(1, math.min(MAX_SPEED, math.floor(ui * MAX_SPEED / 4 + 0.5)))
end
local function speed_to_ui(device, speed)
  local best, bestd = 1, 99
  for ui = 1, 4 do
    local d = math.abs(ui_to_speed(device, ui) - speed)
    if d < bestd then best, bestd = ui, d end
  end
  return best
end

-- ---- emit tracked state ----
local function emit(device)
  local on = get(device, "power", false)
  device:emit_event(on and sw.on() or sw.off())
  device:emit_event(capabilities.fanSpeed.fanSpeed(on and speed_to_ui(device, get(device, "speed", 1)) or 0))
  if comp(device, "boost") then
    device:emit_component_event(comp(device, "boost"), get(device, "boost", false) and sw.on() or sw.off())
  end
  for _, key in ipairs({ "mist", "swing", "breeze" }) do
    local c = comp(device, key)
    if c then
      device:emit_component_event(c, capabilities.mode.supportedModes(LIST[key], { visibility = { displayed = false } }))
      device:emit_component_event(c, capabilities.mode.mode(get(device, key, "Off")))
    end
  end
end

-- ---- actions ----
-- Powering off resets every feature on the fan, including speed
local function start_speed(device)
  return math.max(1, math.min(MAX_SPEED, tonumber(device.preferences.startSpeed) or 1))
end

local function reset_features(device)
  set(device, "speed", start_speed(device))
  set(device, "boost", false)
  set(device, "mist", "Off")
  set(device, "swing", "Off")
  set(device, "breeze", "Off")
end

local function power(device, want)
  local was = get(device, "power", false)
  if was ~= want then press(device, "power") end
  set(device, "power", want)
  if not want then reset_features(device)
  elseif not was then set(device, "speed", start_speed(device)) end   -- fan always starts at this speed
  emit(device)
end

-- Feature buttons need the fan running
local function ensure_on(device)
  if get(device, "power", false) then return end
  press(device, "power")
  set(device, "power", true)
  set(device, "speed", start_speed(device))
  socket.sleep((tonumber(device.preferences.pressMs) or 900) / 1000)
end

local function set_speed(device, target)
  target = math.max(1, math.min(MAX_SPEED, target))
  ensure_on(device)
  local cur = get(device, "speed", 1)
  if target > cur then press(device, "up", target - cur)
  elseif target < cur then press(device, "down", cur - target) end
  set(device, "speed", target)
  emit(device)
end

local function cycle_to(device, key, target)
  local order, cur = ORDER[key], get(device, key, ORDER[key][1])
  local ci, ti = 1, nil
  for i, v in ipairs(order) do
    if v == cur then ci = i end
    if v == target then ti = i end
  end
  if ti == nil then return emit(device) end
  local n = (ti - ci) % #order
  if n > 0 then ensure_on(device) end
  press(device, key, n)
  set(device, key, target)
  emit(device)
end

local function boost(device, want)
  if get(device, "boost", false) ~= want then
    if want then ensure_on(device) end
    press(device, "boost")
  end
  set(device, "boost", want)
  emit(device)
end

-- ---- capability entry points ----
function M.switch(driver, device, cmd, on)
  if cmd.component == "boost" then return boost(device, on) end
  power(device, on)
end

function M.fan_speed(driver, device, cmd)
  local v = math.floor(tonumber(cmd.args.speed) or 0)
  if v <= 0 then return power(device, false) end
  set_speed(device, ui_to_speed(device, math.min(v, 4)))
end

function M.set_mode(driver, device, cmd)
  if ORDER[cmd.component] then cycle_to(device, cmd.component, cmd.args.mode) end
end

function M.refresh(driver, device) emit(device) end
function M.init(driver, device) emit(device) end

-- "Fix ... state" settings: resync tracked state without sending anything
local FIX = {
  fixPower  = function(d, v) set(d, "power", v == "on"); if v == "off" then reset_features(d) end end,
  fixSpeed  = function(d, v) set(d, "speed", tonumber(v) or 1) end,
  fixBoost  = function(d, v) set(d, "boost", v == "on") end,
  fixMist   = function(d, v) set(d, "mist", ({ off = "Off", low = "Low", medium = "Medium", high = "High" })[v] or "Off") end,
  fixSwing  = function(d, v) set(d, "swing", ({ off = "Off", narrow = "Narrow", medium = "Medium", wide = "Wide" })[v] or "Off") end,
  fixBreeze = function(d, v) set(d, "breeze", ({ off = "Off", b1 = "Breeze 1", b2 = "Breeze 2" })[v] or "Off") end,
}
function M.info_changed(driver, device, old)
  local p, o = device.preferences, old or {}
  for name, apply in pairs(FIX) do
    local v = p[name]
    if v ~= nil and v ~= "none" and v ~= o[name] then
      apply(device, v)
      log.info(string.format("[%s] %s -> %s", device.label, name, tostring(v)))
    end
  end
  emit(device)
end

return M
