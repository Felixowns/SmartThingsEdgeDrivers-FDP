-- Other Bond device types (fireplace, generic): power switch via Bridge actions
local capabilities = require "st.capabilities"
local bond         = require "bond"
local U            = require "util"

local M = {}
local sw = capabilities.switch.switch

local function refresh(device)
  local st = bond.state(device)
  device:emit_event((st and st.power == 1) and sw.on() or sw.off())
end

function M.switch(driver, device, cmd, on)
  local info = U.info(device)
  local a = on and "TurnOn" or "TurnOff"
  if U.has_action(info, a) then bond.action(device, a) else bond.action(device, "TogglePower") end
  refresh(device)
end
function M.refresh(driver, device) refresh(device) end
function M.init(driver, device) refresh(device) end

return M
