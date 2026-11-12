-- Ceiling fans. Bond mode: Bridge actions + Bridge state. Custom mode: raw signals,
-- speed-step mapping, tracked light/winter state with fixes, dimmer press length.
local capabilities = require "st.capabilities"
local log          = require "log"
local bond         = require "bond"
local U            = require "util"

local M = {}
local sw = capabilities.switch.switch

local function comp(device, id) return device.profile.components[id] end
local function has_comp(device, id) return device.profile.components[id] ~= nil end
local function on_off(v) return v and sw.on() or sw.off() end

local function max_speed(info)
  local m = tonumber(info.props and info.props.max_speed)
  if m and m > 0 then return m end
  local n = 0
  for _, c in ipairs(info.cmds or {}) do
    if c.action == "SetSpeed" and tonumber(c.argument) and c.argument > n then n = c.argument end
  end
  return n > 0 and n or 3
end

-- SmartThings speed step (1..4) -> real fan speed
local function ui_to_speed(device, ui, max)
  local v = tonumber(device.preferences["speedMap" .. ui]) or 0
  if v > 0 then return math.max(1, math.min(max, v)) end
  return math.max(1, math.min(max, math.floor(ui * max / 4 + 0.5)))
end

local function speed_to_ui(device, speed, max)
  local best, bestd = 1, 999
  for ui = 1, 4 do
    local d = math.abs(ui_to_speed(device, ui, max) - speed)
    if d < bestd then best, bestd = ui, d end
  end
  return best
end

-- The separate "<fan> Light" device, if it exists
local function light_child(device)
  local hub = device:get_parent_device()
  if hub == nil then return nil end
  return hub:get_child_by_parent_assigned_key(device.parent_assigned_child_key .. ":light")
end
M.light_child = light_child

local function emit(device, power, speed, light, winter)
  local max = max_speed(U.info(device))
  speed = math.max(1, math.min(max, speed or 1))
  device:emit_event(on_off(power))
  device:emit_event(capabilities.fanSpeed.fanSpeed(power and speed_to_ui(device, speed, max) or 0))
  device:emit_component_event(comp(device, "light"), on_off(light))
  local lc = light_child(device)
  if lc then lc:emit_event(on_off(light)) end
  if has_comp(device, "winter") then device:emit_component_event(comp(device, "winter"), on_off(winter)) end
end

-- Tracked state (custom mode) lives in fields; Bond mode reads the Bridge
local function tracked(device)
  return device:get_field("power") == true, device:get_field("speed") or 1,
         device:get_field("light") == true, device:get_field("winter") == true
end

local function save(device, power, speed, light, winter)
  if power ~= nil then device:set_field("power", power, { persist = true }) end
  if speed ~= nil then device:set_field("speed", speed, { persist = true }) end
  if light ~= nil then device:set_field("light", light, { persist = true }) end
  if winter ~= nil then device:set_field("winter", winter, { persist = true }) end
  emit(device, tracked(device))
end

local function bond_refresh(device)
  local st = bond.state(device)
  if not st then return emit(device, tracked(device)) end
  save(device, st.power == 1, tonumber(st.speed), st.light == 1, st.direction == -1)
end

-- ---- speed / power ----
local function set_speed(driver, device, speed)
  local info = U.info(device)
  speed = math.max(1, math.min(max_speed(info), speed))
  if U.custom(device) then
    local sig = U.sig(info, "SetSpeed", speed)
    if sig then bond.tx(device, sig) else log.warn("[" .. device.label .. "] no raw signal for speed " .. speed) end
    save(device, true, speed)
  else
    bond.action(device, "SetSpeed", speed)
    bond_refresh(device)
  end
end

local function power(driver, device, on)
  local info = U.info(device)
  if U.custom(device) then
    local is_on, speed = tracked(device)
    if on then return set_speed(driver, device, speed) end
    local sig = U.sig(info, "TurnOff")
    if sig then bond.tx(device, sig)
    elseif is_on and U.sig(info, "TogglePower") then bond.tx(device, U.sig(info, "TogglePower")) end
    save(device, false)
  else
    if on then
      if U.has_action(info, "TurnOn") then bond.action(device, "TurnOn") else bond.action(device, "TogglePower") end
    else
      if U.has_action(info, "TurnOff") then bond.action(device, "TurnOff") else bond.action(device, "TogglePower") end
    end
    bond_refresh(device)
  end
end

-- ---- light / winter (toggle channels) ----
local function channel(driver, device, which, want)
  local info = U.info(device)
  local _, _, light, winter = tracked(device)
  local cur = (which == "light") and light or winter
  if U.custom(device) then
    local sig = U.sig(info, which == "light" and "ToggleLight" or "ToggleDirection")
    if cur ~= want then
      if sig then bond.tx(device, sig) else log.warn("[" .. device.label .. "] no raw signal for " .. which) end
    end
    if which == "light" then save(device, nil, nil, want) else save(device, nil, nil, nil, want) end
  else
    if which == "light" then
      local a = want and "TurnLightOn" or "TurnLightOff"
      if U.has_action(info, a) then bond.action(device, a)
      elseif cur ~= want then bond.action(device, "ToggleLight") end
    else
      if U.has_action(info, "SetDirection") then bond.action(device, "SetDirection", want and -1 or 1)
      elseif cur ~= want then bond.action(device, "ToggleDirection") end
    end
    bond_refresh(device)
  end
end

-- ---- capability entry points ----
function M.set_light(driver, device, on) channel(driver, device, "light", on) end

function M.switch(driver, device, cmd, on)
  if cmd.component == "light" then return channel(driver, device, "light", on) end
  if cmd.component == "winter" then return channel(driver, device, "winter", on) end
  power(driver, device, on)
end

function M.fan_speed(driver, device, cmd)
  local ui = tonumber(cmd.args.speed) or 0
  if ui <= 0 then return power(driver, device, false) end
  set_speed(driver, device, ui_to_speed(device, math.min(ui, 4), max_speed(U.info(device))))
end

local function breeze(device)
  local info = U.info(device)
  if U.custom(device) then
    local sig = U.sig(info, "BreezeOn")
    if sig then bond.tx(device, sig) else log.warn("[" .. device.label .. "] no raw breeze signal") end
  else
    bond.action(device, "BreezeOn")
  end
end

function M.push(driver, device, cmd)   -- momentary buttons: breeze, light dimmer
  if cmd.component == "breeze" then return breeze(device) end
  local info = U.info(device)
  local hold = (tonumber(device.preferences.dimmerHoldMs) or 3000) / 1000
  if U.custom(device) then
    local sig = U.sig(info, "StartDimmer")
    if not sig then return log.warn("[" .. device.label .. "] no raw dimmer signal") end
    bond.tx(device, sig, math.max(1, math.floor(hold / bond.duration(sig) + 0.5)))
  else
    bond.action(device, "StartDimmer")
    device.thread:call_with_delay(hold, function() bond.action(device, "Stop") end)
  end
end

function M.refresh(driver, device)
  if U.custom(device) then emit(device, tracked(device)) else bond_refresh(device) end
end

function M.init(driver, device) M.refresh(driver, device) end

-- Custom-mode fixes: correct tracked light/winter state without transmitting
function M.info_changed(driver, device, old)
  local p, o = device.preferences, old or {}
  for _, f in ipairs({ { "lightFix", "light" }, { "winterFix", "winter" } }) do
    local v = p[f[1]]
    if f[2] == "winter" and not has_comp(device, "winter") then v = nil end
    if v ~= nil and v ~= o[f[1]] and v ~= "none" then
      if not U.custom(device) then
        -- Bond mode: correct the Bridge's own tracked state (no RF is sent)
        local body = (f[2] == "light") and ('{"light":' .. (v == "on" and 1 or 0) .. '}')
                                        or ('{"direction":' .. (v == "on" and -1 or 1) .. '}')
        bond.call(device, "PATCH", "/v2/devices/" .. device.parent_assigned_child_key .. "/state", body)
      end
      if f[2] == "light" then save(device, nil, nil, v == "on") else save(device, nil, nil, nil, v == "on") end
      log.info(string.format("[%s] %s state set to %s", device.label, f[2], v))
    end
  end
  emit(device, tracked(device))
end

return M
