-- Tailwind LAN: local SmartThings Edge driver for Tailwind iQ3 garage door
-- controllers (and the Tailwind Light controller) using the Tailwind Local
-- Control API (fw 9.96+). No Tailwind cloud, no linked service.
--
-- Parent LAN device  = one controller (status LED, identify, reboot, RSSI)
-- EDGE_CHILD devices = one per door (doorControl + contactSensor + lockup)

local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local log = require "log"
local json = require "st.json"

local api = require "tailwind_api"
local push = require "push"
local discovery = require "discovery"

----------------------------------------------------------------------------
-- fields
----------------------------------------------------------------------------
local F = {
  IP = "tw_ip",               -- persisted, from discovery / re-lookup
  ID = "tw_dev_id",           -- persisted, normalized MAC
  PRODUCT = "tw_product",     -- persisted, "iQ3" | "light"
  STATUS = "tw_last_status",  -- last dev_st (transient)
  FAILS = "tw_fails",
  POLL = "tw_poll_timer",
  NOTIFY = "tw_notify_url",   -- url last registered with the controller
  NOTIFY_AT = "tw_notify_at",
  CREATING = "tw_creating",
  PENDING = "tw_pending",     -- child: { target = "open"|"closed", deadline = os.time() }
  LAST_LEVEL = "tw_last_level",
}

local NOTIFY_REFRESH_S = 30 * 60
local DOOR_PROFILE = "tailwind-door"
local IQ3_PROFILE = "tailwind-iq3"
local LIGHT_PROFILE = "tailwind-light"

local is_child = function(device) return device.parent_assigned_child_key ~= nil end

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function token(dev) return trim(dev.preferences.localKey) end

local function ip_of(dev)
  local p = trim(dev.preferences.ipAddress)
  if p ~= "" then return p end
  return dev:get_field(F.IP)
end

local function product_of(dev) return dev:get_field(F.PRODUCT) or "iQ3" end

local function door_index(child)
  local n = tonumber((child.parent_assigned_child_key or ""):match("(%d+)$"))
  return n and (n - 1) or 0
end

local function child_for_door(parent, n)
  return parent:get_child_by_parent_assigned_key("door" .. n)
end

----------------------------------------------------------------------------
-- forward decls
----------------------------------------------------------------------------
local refresh, register_push, schedule_poll

----------------------------------------------------------------------------
-- status -> SmartThings
----------------------------------------------------------------------------
local function apply_door(child, d)
  if type(d) ~= "table" then return end
  local actual = (d.status == "open") and "open" or (d.status == "close" and "closed") or nil

  if tonumber(d.disabled) == 1 then
    child:offline()
  else
    child:online()
  end

  child:emit_event(tonumber(d.lockup) == 1
    and capabilities.tamperAlert.tamper.detected()
    or capabilities.tamperAlert.tamper.clear())

  if not actual then
    child:emit_event(capabilities.doorControl.door.unknown())
    return
  end
  child:emit_event(actual == "open" and capabilities.contactSensor.contact.open()
    or capabilities.contactSensor.contact.closed())

  local pending = child:get_field(F.PENDING)
  if pending then
    if actual == pending.target or os.time() >= pending.deadline then
      child:set_field(F.PENDING, nil)
    else
      return -- still travelling: keep showing opening/closing
    end
  end
  child:emit_event(capabilities.doorControl.door(actual))
end

local function ensure_doors(driver, parent, st)
  local doors = st.data or st.door_data or {}
  local count = tonumber(st.door_num) or 0
  local creating = parent:get_field(F.CREATING) or {}
  if type(doors) == "string" then doors = json.decode(doors) or {} end
  if type(doors) ~= "table" then doors = {} end
  local found_any = false
  for i = 1, math.max(count, 3) do
    -- accept "door1", "Door1", array position, or an entry whose index == i-1
    local d = doors["door" .. i] or doors["Door" .. i] or doors[i]
    if not d then
      for _, v in pairs(doors) do
        if type(v) == "table" and tonumber(v.index) == i - 1 then d = v break end
      end
    end
    if d then found_any = true end
    if d and (i <= count or count == 0) then
      local child = child_for_door(parent, i)
      local last_try = tonumber(creating[i])
      if child then
        creating[i] = nil
        apply_door(child, d)
      elseif tonumber(d.disabled) == 1 then
        log.info(string.format("tailwind: door %d is disabled in the Tailwind app, not creating it", i))
      elseif not last_try or (os.time() - last_try) > 60 then
        creating[i] = os.time()
        log.info(string.format("tailwind: creating door %d for %s", i, parent.label))
        driver:try_create_device {
          type = "EDGE_CHILD",
          label = string.format("%s Door %d", parent.label, i),
          profile = DOOR_PROFILE,
          parent_device_id = parent.id,
          parent_assigned_child_key = "door" .. i,
          vendor_provided_label = "Tailwind Door " .. i,
        }
      end
    end
  end
  if not found_any then
    log.warn(string.format("tailwind: no door data in status (door_num=%s). raw: %s",
      tostring(st.door_num), json.encode(st)))
  end
  parent:set_field(F.CREATING, creating)
end

local function apply_light(parent, st)
  local data = st.data or {}
  local power = tonumber(data.light and data.light.power) or 0
  parent:emit_event(power > 0 and capabilities.switch.switch.on() or capabilities.switch.switch.off())
  if power > 0 then
    parent:set_field(F.LAST_LEVEL, power, { persist = true })
    parent:emit_event(capabilities.switchLevel.level(power))
  end
  if data.mode == "auto" or data.mode == "manual" then
    parent:emit_component_event(parent.profile.components.lightMode or parent.profile.components.main,
      capabilities.mode.mode(data.mode))
  end
end

local function apply_status(driver, parent, st)
  log.debug("tailwind: status " .. json.encode(st))
  parent:set_field(F.STATUS, st)
  parent:set_field(F.FAILS, 0)
  parent:online()

  local id = api.normalize_id(st.dev_id)
  if id and parent:get_field(F.ID) ~= id then parent:set_field(F.ID, id, { persist = true }) end

  local product = (tostring(st.product or "iQ3"):lower() == "light") and "light" or "iQ3"
  if parent:get_field(F.PRODUCT) ~= product then
    parent:set_field(F.PRODUCT, product, { persist = true })
  end
  local want = product == "light" and LIGHT_PROFILE or IQ3_PROFILE
  if parent.profile and parent.profile.components and not parent.profile.components[product == "light" and "lightMode" or "statusLed"] then
    log.info("tailwind: switching " .. parent.label .. " to profile " .. want)
    parent:try_update_metadata({ profile = want })
  end

  if tonumber(st.router_rssi) then
    parent:emit_event(capabilities.signalStrength.rssi({ value = tonumber(st.router_rssi), unit = "dBm" }))
  end

  if product == "light" then
    apply_light(parent, st)
  else
    if tonumber(st.led_brightness) and parent.profile.components.statusLed then
      parent:emit_component_event(parent.profile.components.statusLed,
        capabilities.switchLevel.level(math.max(0, math.min(100, tonumber(st.led_brightness)))))
    end
    ensure_doors(driver, parent, st)
  end

  if type(st.notify) == "table" then
    log.info(string.format("tailwind: %s event %s door_idx %s", parent.label,
      tostring(st.notify.event), tostring(st.notify.door_idx)))
    if st.notify.event == "reboot" then
      -- re-arm push after the controller comes back
      parent:set_field(F.NOTIFY, nil)
      parent.thread:call_with_delay(15, function() register_push(driver, parent) end)
    end
  end
end

----------------------------------------------------------------------------
-- talking to the controller
----------------------------------------------------------------------------
local function call(parent, fn, ...)
  local ip = ip_of(parent)
  if not ip then
    log.warn("tailwind: " .. parent.label .. " has no IP address yet - set it in settings")
    return nil, "no ip"
  end
  if token(parent) == "" then
    log.warn("tailwind: " .. parent.label .. " has no Local Control Key - set it in settings")
  end
  return fn(ip, token(parent), ...)
end

refresh = function(driver, parent)
  local st, err = call(parent, api.get_status)
  if st then
    apply_status(driver, parent, st)
    return true
  end
  local fails = (parent:get_field(F.FAILS) or 0) + 1
  parent:set_field(F.FAILS, fails)
  log.warn(string.format("tailwind: status failed for %s (%d): %s", parent.label, fails, tostring(err)))

  if tostring(err):find("^device:") then
    -- controller answered "Fail" (usually a wrong/expired Local Control Key)
    parent:offline()
    return false
  end
  if fails >= 2 and trim(parent.preferences.ipAddress) == "" and parent:get_field(F.ID) then
    local ip = discovery.lookup(parent:get_field(F.ID))
    if ip and ip ~= parent:get_field(F.IP) then
      log.info("tailwind: " .. parent.label .. " moved to " .. ip)
      parent:set_field(F.IP, ip, { persist = true })
      parent:set_field(F.NOTIFY, nil)
      return refresh(driver, parent)
    end
  end
  if fails >= 3 then
    parent:offline()
    for _, c in ipairs(parent:get_child_list() or {}) do c:offline() end
  end
  return false
end

local function on_push(driver, src_ip, msg)
  local id = api.normalize_id(msg.dev_id)
  for _, dev in ipairs(driver:get_devices()) do
    if not is_child(dev) and (ip_of(dev) == src_ip or (id and dev:get_field(F.ID) == id)) then
      if ip_of(dev) ~= src_ip and trim(dev.preferences.ipAddress) == "" then
        dev:set_field(F.IP, src_ip, { persist = true })
      end
      log.debug("tailwind push from " .. src_ip)
      apply_status(driver, dev, msg)
      return
    end
  end
  log.debug("tailwind push from unknown controller " .. tostring(src_ip))
end

register_push = function(driver, parent)
  local ip = ip_of(parent)
  if not ip or token(parent) == "" then return end
  if parent.preferences.usePush == false then
    if parent:get_field(F.NOTIFY) ~= "off" then
      local ok = call(parent, api.set_notify, product_of(parent), "udp", "0.0.0.0:0", false)
      if ok then parent:set_field(F.NOTIFY, "off") end
    end
    return
  end
  local url = push.ensure(driver, ip, on_push)
  if not url then return end
  local fresh = (os.time() - (parent:get_field(F.NOTIFY_AT) or 0)) < NOTIFY_REFRESH_S
  if parent:get_field(F.NOTIFY) == url and fresh then return end
  local ok, err = call(parent, api.set_notify, product_of(parent), "udp", url, true)
  if ok then
    log.info("tailwind: " .. parent.label .. " reports to " .. url)
    parent:set_field(F.NOTIFY, url)
    parent:set_field(F.NOTIFY_AT, os.time())
  else
    log.warn("tailwind: notify_url failed: " .. tostring(err))
  end
end

schedule_poll = function(driver, parent)
  local old = parent:get_field(F.POLL)
  if old then parent.thread:cancel_timer(old) end
  local secs = tonumber(parent.preferences.pollInterval) or 60
  if secs < 10 then secs = 10 end
  parent:set_field(F.POLL, parent.thread:call_on_schedule(secs, function()
    refresh(driver, parent)
    register_push(driver, parent)
  end, "tailwind poll"))
end

local function start(driver, parent)
  parent.thread:call_with_delay(1, function()
    refresh(driver, parent)
    register_push(driver, parent)
  end)
  schedule_poll(driver, parent)
end

----------------------------------------------------------------------------
-- door commands (children)
----------------------------------------------------------------------------
local function door_command(driver, child, cmd, partial_ms)
  local parent = child:get_parent_device()
  if not parent then return end
  local target = cmd == "open" and "open" or "closed"
  local current = child:get_latest_state("main", capabilities.doorControl.ID,
    capabilities.doorControl.door.NAME)

  if current == target and not partial_ms then
    child:emit_event(capabilities.doorControl.door(target)) -- reset UI spinner
    return
  end

  local ok, err = call(parent, api.door_op, door_index(child), cmd, partial_ms)
  if not ok then
    log.error("tailwind: door_op " .. cmd .. " failed: " .. tostring(err))
    child:emit_event(capabilities.doorControl.door(current or "unknown"))
    refresh(driver, parent)
    return
  end

  local travel = tonumber(child.preferences.travelTime) or 20
  child:set_field(F.PENDING, { target = target, deadline = os.time() + travel })
  child:emit_event(cmd == "open" and capabilities.doorControl.door.opening()
    or capabilities.doorControl.door.closing())
  -- check at the end of travel even if no push arrives
  parent.thread:call_with_delay(travel + 2, function()
    if not refresh(driver, parent) then
      child:set_field(F.PENDING, nil)
    end
  end)
end

----------------------------------------------------------------------------
-- capability handlers
----------------------------------------------------------------------------
local function handle_refresh(driver, device)
  local parent = is_child(device) and device:get_parent_device() or device
  if parent then
    refresh(driver, parent)
    register_push(driver, parent)
  end
end

local function handle_open(driver, device) door_command(driver, device, "open") end
local function handle_close(driver, device) door_command(driver, device, "close") end

local function handle_push(driver, device, command)
  local comp = command.component
  if is_child(device) then
    if comp == "partial" then
      local secs = tonumber(device.preferences.partialTime) or 0
      if secs <= 0 then
        log.warn("tailwind: set 'Partial open time' in the door settings first")
        return
      end
      door_command(driver, device, "open", secs * 1000)
    end
    return
  end
  if comp == "identify" then
    local ok, err = call(device, api.identify, product_of(device))
    if not ok then log.warn("tailwind: identify failed (needs fw 10.10+): " .. tostring(err)) end
  elseif comp == "reboot" then
    local ok, err = call(device, api.reboot, product_of(device))
    if ok then
      device:set_field(F.NOTIFY, nil)
      device.thread:call_with_delay(20, function() handle_refresh(driver, device) end)
    else
      log.warn("tailwind: reboot failed (needs fw 10.10+): " .. tostring(err))
    end
  end
end

local function light_send(driver, device, value)
  local ok, err = call(device, api.light_op, value)
  if not ok then log.warn("tailwind: light dev_op failed: " .. tostring(err)) end
  device.thread:call_with_delay(1, function() refresh(driver, device) end)
  return ok
end

local function handle_set_level(driver, device, command)
  local level = math.max(0, math.min(100, math.floor(tonumber(command.args.level) or 0)))
  if command.component == "statusLed" then
    local ok, err = call(device, api.set_led, level)
    if ok then
      device:emit_component_event(device.profile.components.statusLed, capabilities.switchLevel.level(level))
    else
      log.warn("tailwind: status_led failed: " .. tostring(err))
    end
    return
  end
  -- Tailwind Light
  if level > 0 then device:set_field(F.LAST_LEVEL, level, { persist = true }) end
  light_send(driver, device, { power = level, mode = "manual" })
end

local function handle_on(driver, device)
  light_send(driver, device, { power = device:get_field(F.LAST_LEVEL) or 100, mode = "manual" })
end

local function handle_off(driver, device)
  light_send(driver, device, { power = 0, mode = "manual" })
end

local function handle_set_mode(driver, device, command)
  local m = command.args.mode
  if m ~= "auto" and m ~= "manual" then return end
  light_send(driver, device, { mode = m })
end

----------------------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------------------
local function device_init(driver, device)
  if is_child(device) then
    local parent = device:get_parent_device()
    local st = parent and parent:get_field(F.STATUS)
    local doors = st and (st.data or st.door_data)
    if doors then apply_door(device, doors[device.parent_assigned_child_key]) end
    return
  end

  if not device:get_field(F.IP) then
    local found = driver.tw_found and driver.tw_found[device.device_network_id]
    if found then
      device:set_field(F.IP, found.ip, { persist = true })
      device:set_field(F.ID, found.id, { persist = true })
      device:set_field(F.PRODUCT, (found.product or ""):lower() == "light" and "light" or "iQ3", { persist = true })
    end
  end
  if device.profile.components.lightMode then
    device:emit_component_event(device.profile.components.lightMode,
      capabilities.mode.supportedModes({ "auto", "manual" }, { visibility = { displayed = false } }))
    if capabilities.mode.supportedArguments then
      device:emit_component_event(device.profile.components.lightMode,
        capabilities.mode.supportedArguments({ "auto", "manual" }, { visibility = { displayed = false } }))
    end
  end
  start(driver, device)
end

local function device_added(driver, device)
  device_init(driver, device)
end

local function info_changed(driver, device, event, args)
  if is_child(device) then return end
  local old = (args and args.old_st_store and args.old_st_store.preferences) or {}
  local new = device.preferences

  if old.ipAddress ~= new.ipAddress or old.localKey ~= new.localKey then
    device:set_field(F.FAILS, 0)
    device:set_field(F.NOTIFY, nil)
    start(driver, device)
    return
  end
  if old.pollInterval ~= new.pollInterval then schedule_poll(driver, device) end
  if old.usePush ~= new.usePush then
    device:set_field(F.NOTIFY, nil)
    device.thread:call_with_delay(0, function() register_push(driver, device) end)
  end
  if new.serverMonitor ~= nil and old.serverMonitor ~= new.serverMonitor then
    device.thread:call_with_delay(0, function()
      local ok, err = call(device, api.server_monitor, new.serverMonitor)
      if not ok then log.warn("tailwind: server_monitor failed (needs fw 10.61+): " .. tostring(err)) end
    end)
  end
  if product_of(device) == "light" and (old.radarDelay ~= new.radarDelay
      or old.radarLux ~= new.radarLux or old.radarDistance ~= new.radarDistance) then
    device.thread:call_with_delay(0, function()
      light_send(driver, device, {
        delay = tonumber(new.radarDelay), lux = tonumber(new.radarLux),
        distance = tonumber(new.radarDistance),
      })
    end)
  end
end

local function device_removed(driver, device)
  if is_child(device) then return end
  local t = device:get_field(F.POLL)
  if t then device.thread:cancel_timer(t) end
  -- stop the controller from reporting to us
  if ip_of(device) and token(device) ~= "" then
    api.set_notify(ip_of(device), token(device), product_of(device), "udp", "0.0.0.0:0", false)
  end
end

----------------------------------------------------------------------------
-- discovery
----------------------------------------------------------------------------
local function discovery_handler(driver, _, should_continue)
  log.info("tailwind: scanning for controllers")
  driver.tw_found = driver.tw_found or {}
  local known = {}
  for _, d in ipairs(driver:get_devices()) do known[d.device_network_id] = true end

  local tries, any = 0, false
  while should_continue() and tries < 3 do
    tries = tries + 1
    for _, f in ipairs(discovery.scan()) do
      any = true
      local dni = "tailwind-" .. f.id
      driver.tw_found[dni] = f
      if not known[dni] then
        known[dni] = true
        local light = (f.product or ""):lower() == "light"
        driver:try_create_device {
          type = "LAN",
          device_network_id = dni,
          label = light and "Tailwind Light" or "Tailwind iQ3",
          profile = light and LIGHT_PROFILE or IQ3_PROFILE,
          manufacturer = "Tailwind",
          model = light and "Light" or "iQ3",
          vendor_provided_label = light and "Tailwind Light" or "Tailwind iQ3",
        }
      end
    end
    if any then break end
  end

  -- nothing found and nothing installed: blank controller to configure by IP
  if not any then
    local has_parent = false
    for _, d in ipairs(driver:get_devices()) do
      if not is_child(d) then has_parent = true end
    end
    if not has_parent then
      log.info("tailwind: no controller found via mDNS, creating a manual one (set IP in settings)")
      driver:try_create_device {
        type = "LAN",
        device_network_id = "tailwind-manual-" .. tostring(os.time()),
        label = "Tailwind iQ3",
        profile = IQ3_PROFILE,
        manufacturer = "Tailwind",
        model = "iQ3",
        vendor_provided_label = "Tailwind iQ3",
      }
    end
  end
end

----------------------------------------------------------------------------
local driver = Driver("tailwind-lan", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    infoChanged = info_changed,
    removed = device_removed,
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
    },
    [capabilities.doorControl.ID] = {
      [capabilities.doorControl.commands.open.NAME] = handle_open,
      [capabilities.doorControl.commands.close.NAME] = handle_close,
    },
    [capabilities.momentary.ID] = {
      [capabilities.momentary.commands.push.NAME] = handle_push,
    },
    [capabilities.switchLevel.ID] = {
      [capabilities.switchLevel.commands.setLevel.NAME] = handle_set_level,
    },
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = handle_on,
      [capabilities.switch.commands.off.NAME] = handle_off,
    },
    [capabilities.mode.ID] = {
      [capabilities.mode.commands.setMode.NAME] = handle_set_mode,
    },
  },
})

log.info("tailwind-lan driver starting")
driver:run()
