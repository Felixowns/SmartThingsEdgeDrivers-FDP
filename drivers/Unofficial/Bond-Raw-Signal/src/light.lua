-- Lights / single-button devices. Bond mode: light switch via Bridge actions.
-- Custom mode: momentary trigger (e.g. doors that close themselves) using the raw signal,
-- exposed as a momentary button plus a self-resetting switch for Alexa voice control.
local capabilities = require "st.capabilities"
local log          = require "log"
local bond         = require "bond"
local U            = require "util"

local M = {}
local sw = capabilities.switch.switch

local function trigger(device)
  local info = U.info(device)
  local sig = U.sig(info, "ToggleLight") or U.sig(info, "TurnLightOn") or U.first_sig(info)
  if not sig then return log.warn("[" .. device.label .. "] no raw signal stored") end
  bond.tx(device, sig)
  device:emit_event(sw.on())
  device.thread:call_with_delay(tonumber(device.preferences.autoOffSec) or 3, function()
    device:emit_event(sw.off())
  end)
end

local function bond_refresh(device)
  local st = bond.state(device)
  device:emit_event((st and st.light == 1) and sw.on() or sw.off())
end

function M.switch(driver, device, cmd, on)
  if U.custom(device) then
    if on then trigger(device) else device:emit_event(sw.off()) end
    return
  end
  local info = U.info(device)
  local a = on and "TurnLightOn" or "TurnLightOff"
  if U.has_action(info, a) then bond.action(device, a)
  else
    local st = bond.state(device)
    if (st and st.light == 1) ~= on then bond.action(device, "ToggleLight") end
  end
  bond_refresh(device)
end

function M.push(driver, device) if U.custom(device) then trigger(device) end end
function M.refresh(driver, device)
  if U.custom(device) then device:emit_event(sw.off()) else bond_refresh(device) end
end
function M.init(driver, device) M.refresh(driver, device) end

return M
