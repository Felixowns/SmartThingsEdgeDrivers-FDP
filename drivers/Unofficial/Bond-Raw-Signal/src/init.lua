-- Bond-Raw-Signal: finds Bond Bridges, creates a hub device, builds child devices from the
-- Bridge's own device list, and lets each child act as Bond configured it ("Bond" behavior)
-- or with raw-signal customizations ("Custom" behavior).
local capabilities = require "st.capabilities"
local Driver       = require "st.driver"
local cosock       = require "cosock"
local log          = require "log"
local bond         = require "bond"
local hub          = require "hub"
local fan          = require "fan"
local shade        = require "shade"
local light        = require "light"
local generic      = require "generic"
local fanlight     = require "fanlight"
local shark        = require "shark"

local MODULES = { fan = fan, shade = shade, light = light, generic = generic, fanlight = fanlight }
local pending_ip = {}   -- hub dni -> ip found by discovery

local function is_child(device) return device.network_type == "DEVICE_EDGE_CHILD" end

local function kind_of(device)
  local k = device:get_field("kind")
  if k then return k end
  if is_child(device) and (device.parent_assigned_child_key or ""):match(":light$") then
    device:set_field("kind", "fanlight", { persist = true })
    return "fanlight"
  end
  local info = device:get_field("bond")
  if info then
    k = hub.kind_for(info)
    device:set_field("kind", k, { persist = true })
    return k
  end
  return "generic"
end

local function mod(device)
  local k = kind_of(device)
  if k == "fan" and device.preferences.behavior == "shark" then return shark end
  return MODULES[k] or generic
end

local function sync(driver, hub_dev)
  cosock.spawn(function()
    hub.sync(driver, hub_dev, function(child) mod(child).init(driver, child) end)
  end, "bond sync " .. hub_dev.id)
end

-- ---------- discovery ----------
local function discovery(driver, _, _)
  local have, any = {}, false
  for _, d in ipairs(driver:get_devices()) do
    if not is_child(d) then have[d.device_network_id] = true; any = true end
  end
  local found = bond.discover()
  if #found == 0 and not any then
    log.warn("no Bond Bridge found by mDNS; creating one to configure manually")
    found = { { ip = nil, id = "manual" } }
  end
  for _, b in ipairs(found) do
    local dni = "bond-hub:" .. b.id
    if not have[dni] then
      pending_ip[dni] = b.ip
      log.info("creating Bond Bridge device " .. dni .. " at " .. tostring(b.ip))
      driver:try_create_device({
        type = "LAN", device_network_id = dni,
        label = (b.id == "manual") and "Bond Bridge" or ("Bond Bridge " .. b.id),
        profile = "bond-bridge", manufacturer = "Olibra", model = "Bond Bridge",
        vendor_provided_label = "Bond Bridge",
      })
    end
  end
end

-- ---------- lifecycle ----------
local function added(driver, device)
  if is_child(device) then
    local info = hub.pending[device.parent_assigned_child_key]
    if info then
      device:set_field("bond", info, { persist = true })
      hub.pending[device.parent_assigned_child_key] = nil
    end
    local k = kind_of(device)
    if k ~= "fanlight" then
      device:set_field("profile", hub.profile_for(k, "bond", device:get_field("bond")), { persist = true })
    end
    mod(device).init(driver, device)
  else
    local ip = pending_ip[device.device_network_id]
    if ip then device:set_field("ip", ip, { persist = true }) end
    sync(driver, device)
  end
end

local function init(driver, device)
  if is_child(device) then
    if device:get_field("bond") or kind_of(device) == "fanlight" then mod(device).init(driver, device) end
  end
end

local function info_changed(driver, device, _, args)
  local old = (args and args.old_st_store and args.old_st_store.preferences) or {}
  local p = device.preferences
  if not is_child(device) then
    if p.bondIp ~= old.bondIp or p.bondToken ~= old.bondToken or p.autoToken ~= old.autoToken then
      sync(driver, device)
    end
    return
  end
  local k = kind_of(device)
  if k == "fanlight" then return end
  if k ~= "generic" and p.behavior ~= nil then
    local target = hub.profile_for(k, p.behavior, device:get_field("bond"))
    if device:get_field("profile") ~= target then
      log.info(string.format("[%s] switching to %s", device.label, target))
      device:set_field("profile", target, { persist = true })
      device:try_update_metadata({ profile = target })
      return
    end
  end
  local m = mod(device)
  if m.info_changed then m.info_changed(driver, device, old) end
  mod(device).refresh(driver, device)
end

-- ---------- capability dispatch ----------
local function on_switch(on)
  return function(driver, device, cmd)
    local m = mod(device)
    if m.switch then m.switch(driver, device, cmd, on) end
  end
end

local function call(name)
  return function(driver, device, cmd)
    local m = mod(device)
    if m[name] then m[name](driver, device, cmd) end
  end
end

local driver = Driver("bond-raw-signal", {
  discovery = discovery,
  lifecycle_handlers = { added = added, init = init, infoChanged = info_changed },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME]  = on_switch(true),
      [capabilities.switch.commands.off.NAME] = on_switch(false),
    },
    [capabilities.fanSpeed.ID] = {
      [capabilities.fanSpeed.commands.setFanSpeed.NAME] = call("fan_speed"),
    },
    [capabilities.momentary.ID] = {
      [capabilities.momentary.commands.push.NAME] = call("push"),
    },
    [capabilities.mode.ID] = {
      [capabilities.mode.commands.setMode.NAME] = call("set_mode"),
    },
    [capabilities.windowShade.ID] = {
      [capabilities.windowShade.commands.open.NAME]  = call("open"),
      [capabilities.windowShade.commands.close.NAME] = call("close"),
      [capabilities.windowShade.commands.pause.NAME] = call("pause"),
    },
    [capabilities.windowShadeLevel.ID] = {
      [capabilities.windowShadeLevel.commands.setShadeLevel.NAME] = call("level"),
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = function(driver, device)
        if is_child(device) then mod(device).refresh(driver, device) else sync(driver, device) end
      end,
    },
  },
})

driver:run()
