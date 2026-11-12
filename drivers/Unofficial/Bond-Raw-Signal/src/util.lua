-- Helpers for the cached Bond device info stored on each child
local M = {}

function M.info(device) return device:get_field("bond") or { cmds = {}, actions = {}, props = {} } end

-- Stored command with a raw signal for action (and argument, if given)
function M.cmd(info, action, arg)
  for _, c in ipairs(info.cmds or {}) do
    if c.action == action and c.signal ~= nil and (arg == nil or c.argument == arg) then return c end
  end
  return nil
end

function M.sig(info, action, arg)
  local c = M.cmd(info, action, arg)
  return c and c.signal or nil
end

function M.first_sig(info)
  for _, c in ipairs(info.cmds or {}) do
    if c.signal ~= nil then return c.signal end
  end
  return nil
end

function M.has_action(info, action)
  for _, a in ipairs(info.actions or {}) do
    if a == action then return true end
  end
  return false
end

-- "Device behavior" setting: bond = act as configured in Bond, custom = raw-signal customizations
function M.custom(device) return device.preferences.behavior == "custom" end

function M.pref(device, name, default)
  local v = device.preferences[name]
  if v == nil or v == "" then return default end
  return v
end

return M
