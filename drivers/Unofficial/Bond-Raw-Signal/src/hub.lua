-- Bond Bridge hub device: token handling and sync of Bond devices into child devices
local log  = require "log"
local bond = require "bond"

local M = {}
M.pending = {}   -- bond device id -> info, waiting for the child's "added" event

local KIND = { CF = "fan", MS = "shade", LT = "light" }

function M.kind_for(info) return KIND[info.type] or "generic" end

local function has(info, actions)
  for _, a in ipairs(actions) do
    for _, x in ipairs(info.actions or {}) do if x == a then return true end end
    for _, c in ipairs(info.cmds or {}) do if c.action == a then return true end end
  end
  return false
end

-- Fan features found on the Bond device decide which fan profile is used
function M.fan_variant(info)
  local v = ""
  if has(info, { "ToggleDirection", "SetDirection" }) then v = v .. "-rev" end
  if has(info, { "BreezeOn", "BreezeOff", "SetBreeze" }) then v = v .. "-breeze" end
  return v
end

function M.fan_has_light(info) return has(info, { "ToggleLight", "TurnLightOn", "TurnLightOff" }) end

function M.profile_for(kind, mode, info)
  if kind == "fan" and mode == "shark" then return "bond-fan-shark-misting-custom" end
  local name = "bond-" .. kind
  if kind == "fan" and info then name = name .. M.fan_variant(info) end
  if kind == "generic" or mode ~= "custom" then return name end
  return name .. "-custom"
end

local function ensure_token(hub, ip)
  if not bond.blank(hub.preferences.bondToken) then return hub.preferences.bondToken end
  local t = hub:get_field("token")
  if not bond.blank(t) then return t end
  if hub.preferences.autoToken == false then return nil end
  t = bond.fetch_token(ip)
  if t then
    hub:set_field("token", t, { persist = true })
    log.info("[" .. hub.label .. "] Bond token read automatically")
  end
  return t
end

local function get(ip, token, path)
  local code, data = bond.request(ip, token, "GET", path, nil)
  if code == 200 then return data end
  return nil
end

local function read_device(ip, token, id)
  local dev = get(ip, token, "/v2/devices/" .. id)
  if not dev then return nil end
  local info = {
    id = id, name = dev.name, type = dev.type, template = dev.template,
    actions = dev.actions or {}, props = get(ip, token, "/v2/devices/" .. id .. "/properties") or {},
    cmds = {},
  }
  local list = get(ip, token, "/v2/devices/" .. id .. "/commands") or {}
  for cid, _ in pairs(list) do
    if cid:sub(1, 1) ~= "_" then
      local c = get(ip, token, "/v2/devices/" .. id .. "/commands/" .. cid)
      if c then
        local entry = { id = cid, name = c.name, action = c.action, argument = c.argument }
        local s = get(ip, token, "/v2/devices/" .. id .. "/commands/" .. cid .. "/signal")
        if type(s) == "table" and not bond.blank(s.data) then
          entry.signal = { freq = s.freq, bps = s.bps, modulation = s.modulation,
                           encoding = s.encoding, data = s.data, reps = s.reps }
        end
        table.insert(info.cmds, entry)
      end
    end
  end
  return info
end

function M.sync(driver, hub, on_updated)
  local ip = bond.creds(hub)
  if bond.blank(ip) then
    log.warn("[" .. hub.label .. "] set the Bond Bridge IP in settings")
    return
  end
  local token = ensure_token(hub, ip)
  if bond.blank(token) then
    log.warn("[" .. hub.label .. "] no token: enter it in settings, or power-cycle the Bridge and press Refresh within 10 minutes")
    return
  end
  local list = get(ip, token, "/v2/devices")
  if type(list) ~= "table" then
    log.warn("[" .. hub.label .. "] could not read devices (check IP/token)")
    return
  end
  local children = {}
  for _, d in ipairs(driver:get_devices()) do
    if d.parent_device_id == hub.id then children[d.parent_assigned_child_key] = d end
  end
  for id, _ in pairs(list) do
    if id:sub(1, 1) ~= "_" then
      local info = read_device(ip, token, id)
      if info then
        if M.kind_for(info) == "fan" and M.fan_has_light(info) and not children[id .. ":light"] then
          local lname = (info.name or ("Bond " .. id)) .. " Light"
          log.info(string.format("[%s] creating %s", hub.label, lname))
          driver:try_create_device({
            type = "EDGE_CHILD", parent_device_id = hub.id, parent_assigned_child_key = id .. ":light",
            label = lname, profile = "bond-fan-light", manufacturer = "Bond", model = "CF-light",
            vendor_provided_label = lname,
          })
        end
        local child = children[id]
        if child then
          child:set_field("bond", info, { persist = true })
          if on_updated then on_updated(child) end
        else
          M.pending[id] = info
          local kind = M.kind_for(info)
          log.info(string.format("[%s] creating %s (%s)", hub.label, info.name or id, kind))
          driver:try_create_device({
            type = "EDGE_CHILD", parent_device_id = hub.id, parent_assigned_child_key = id,
            label = info.name or ("Bond " .. id), profile = M.profile_for(kind, "bond", info),
            manufacturer = "Bond", model = info.type or "GX",
            vendor_provided_label = info.name or ("Bond " .. id),
          })
        end
      end
    end
  end
end

return M
