-- "<Fan> Light": separate device for a fan's light (own tile, own Alexa device).
-- Commands are carried out by the fan device, using the fan's behavior and settings.
local capabilities = require "st.capabilities"
local fan          = require "fan"

local M = {}

local function fan_of(device)
  local hub = device:get_parent_device()
  if hub == nil then return nil end
  local base = device.parent_assigned_child_key:gsub(":light$", "")
  return hub:get_child_by_parent_assigned_key(base)
end

function M.switch(driver, device, cmd, on)
  local f = fan_of(device)
  if f then fan.set_light(driver, f, on)
  else device:emit_event(on and capabilities.switch.switch.on() or capabilities.switch.switch.off()) end
end

function M.refresh(driver, device)
  local f = fan_of(device)
  if f then fan.refresh(driver, f) end
end

function M.init(driver, device) M.refresh(driver, device) end

return M
