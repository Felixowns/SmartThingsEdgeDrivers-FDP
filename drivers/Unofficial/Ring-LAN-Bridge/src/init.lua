local capabilities = require("st.capabilities")
local Driver = require("st.driver")
local log = require("log")
local cosock = require("cosock")
local socket = cosock.socket
local http = cosock.asyncify("socket.http")
local ltn12 = require("ltn12")
local json = require("st.json")

-- socket.http ignores a per-request `timeout` field; this module-level value is what it uses.
http.TIMEOUT = 3

local DEFAULT_BRIDGE_IP = "192.168.1.17"
local DEFAULT_BRIDGE_PORT = 8080
local FALLBACK_POLL_SECONDS = 30   -- safety net only; real-time updates arrive by push
local SUBSCRIBE_MIN_INTERVAL = 60  -- seconds between (non-forced) re-registrations
local EVENT_PATH = "/ring/event"
local MAX_BODY = 64 * 1024

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function get_ring_id(device)
  if device.device_network_id then
    local id = device.device_network_id:match("^ring%-(.+)$")
    if id then return id end
  end
  return device.preferences and device.preferences.deviceId
end

local function get_bridge_config(device)
  local prefs = (device and device.preferences) or {}
  local ip = prefs.bridgeIp
  if ip == nil or ip == "" then ip = DEFAULT_BRIDGE_IP end
  local port = tonumber(prefs.bridgePort) or DEFAULT_BRIDGE_PORT
  return ip, port
end

local function bridge_key(ip, port)
  return ip .. ":" .. tostring(port)
end

-- Returns status code (number) and decoded JSON body (or nil); on transport error returns nil, err.
local function http_json(method, url, payload)
  local chunks = {}
  local body = payload and json.encode(payload) or nil
  local req = {
    url = url,
    method = method,
    sink = ltn12.sink.table(chunks),
  }
  if body then
    req.headers = {
      ["Content-Type"] = "application/json",
      ["Content-Length"] = tostring(#body),
    }
    req.source = ltn12.source.string(body)
  end
  local ok, code = http.request(req)
  if not ok or type(code) ~= "number" then
    return nil, code
  end
  local decoded_ok, decoded = pcall(json.decode, table.concat(chunks))
  return code, decoded_ok and decoded or nil
end

local function set_online(device, online)
  if device:get_field("online") == online then return end
  device:set_field("online", online)
  if online then device:online() else device:offline() end
end

-- Only emit when the value actually changes (avoids an event every poll).
local function emit_if_changed(device, capability, attribute, value)
  if device:get_latest_state("main", capability.ID, attribute.NAME) ~= value then
    device:emit_event(attribute[value]())
  end
end

local function apply_state(device, data)
  if type(data) ~= "table" then return end
  if device:supports_capability(capabilities.contactSensor) then
    if data.state == "open" or data.state == "closed" then
      emit_if_changed(device, capabilities.contactSensor, capabilities.contactSensor.contact, data.state)
    else
      log.warn(string.format("[%s] unexpected contact state: %s", device.label, tostring(data.state)))
    end
  elseif device:supports_capability(capabilities.switch) then
    if data.on ~= nil then
      emit_if_changed(device, capabilities.switch, capabilities.switch.switch, data.on and "on" or "off")
    end
  end
end

local function find_device(driver, ring_id)
  ring_id = tostring(ring_id)
  for _, d in ipairs(driver:get_devices()) do
    if get_ring_id(d) == ring_id then return d end
  end
end

local function devices_by_bridge(driver)
  local groups = {}
  for _, d in ipairs(driver:get_devices()) do
    local ip, port = get_bridge_config(d)
    local key = bridge_key(ip, port)
    groups[key] = groups[key] or { ip = ip, port = port, devices = {} }
    table.insert(groups[key].devices, d)
  end
  return groups
end

-- Find the hub's own IP on the interface that reaches the bridge.
local function local_ip_toward(ip)
  local s = socket.udp()
  if not s then return nil end
  s:setpeername(ip, 9)
  local addr = s:getsockname()
  s:close()
  if addr and addr ~= "0.0.0.0" then return addr end
  return nil
end

---------------------------------------------------------------------------
-- Bridge communication
---------------------------------------------------------------------------

local last_subscribe = {}

-- Tell the bridge where to POST state changes. Repeated periodically so a
-- restarted bridge (or a new hub listener port) re-learns the callback URL.
local function ensure_subscribed(driver, ip, port, force)
  if not driver.listener_port then return end
  local key = bridge_key(ip, port)
  local now = os.time()
  if not force and last_subscribe[key] and now - last_subscribe[key] < SUBSCRIBE_MIN_INTERVAL then
    return
  end
  local hub_ip = local_ip_toward(ip) or (driver.environment_info and driver.environment_info.hub_ipv4)
  if not hub_ip then return end
  local callback = string.format("http://%s:%d%s", hub_ip, driver.listener_port, EVENT_PATH)
  local code, err = http_json("POST", string.format("http://%s:%d/api/subscribe", ip, port), { url = callback })
  if code == 200 then
    last_subscribe[key] = now
  else
    log.debug(string.format("subscribe to %s failed: %s", key, tostring(code or err)))
  end
end

-- One request fetches every device's state from a bridge.
local function refresh_bridge(group)
  local code, states = http_json("GET", string.format("http://%s:%d/api/states", group.ip, group.port))
  if code == 200 and type(states) == "table" then
    for _, d in ipairs(group.devices) do
      local s = states[get_ring_id(d)]
      if s then
        set_online(d, true)
        apply_state(d, s)
      else
        set_online(d, false) -- bridge doesn't know this device (excluded / removed)
      end
    end
  else
    log.warn(string.format("bridge %s unreachable: %s", bridge_key(group.ip, group.port), tostring(code)))
    for _, d in ipairs(group.devices) do set_online(d, false) end
  end
end

local function poll_all(driver)
  for _, group in pairs(devices_by_bridge(driver)) do
    ensure_subscribed(driver, group.ip, group.port, true)
    refresh_bridge(group)
  end
end

local function sync_device_bridge(driver, device)
  local ip, port = get_bridge_config(device)
  ensure_subscribed(driver, ip, port, false)
  local group = devices_by_bridge(driver)[bridge_key(ip, port)] or { ip = ip, port = port, devices = { device } }
  refresh_bridge(group)
end

---------------------------------------------------------------------------
-- Push listener: the bridge POSTs {"id": "...", "state"|"on": ...} here
---------------------------------------------------------------------------

local function handle_client(driver, client)
  client:settimeout(3)
  local line = client:receive("*l")
  if not line then client:close() return end
  local method, path = line:match("^(%u+)%s+(%S+)")

  local length = 0
  while true do
    local h = client:receive("*l")
    if not h or h == "" then break end
    local name, value = h:match("^([^:]+):%s*(.*)$")
    if name and name:lower() == "content-length" then length = tonumber(value) or 0 end
  end

  local status = "404 Not Found"
  if method == "POST" and path == EVENT_PATH and length > 0 and length <= MAX_BODY then
    local body = client:receive(length)
    local ok, msg = pcall(json.decode, body or "")
    if ok and type(msg) == "table" and msg.id ~= nil then
      local device = find_device(driver, msg.id)
      if device then
        set_online(device, true)
        apply_state(device, msg)
      end
      status = "200 OK"
    else
      status = "400 Bad Request"
    end
  end

  client:send("HTTP/1.1 " .. status .. "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
  client:close()
end

local function start_listener(driver)
  local server = socket.tcp()
  local ok, err = server:bind("0.0.0.0", 0)
  if not ok then
    log.error("push listener bind failed: " .. tostring(err))
    return
  end
  server:listen(8)
  local _, port = server:getsockname()
  driver.listener_port = port
  log.info("push listener on port " .. tostring(port))

  cosock.spawn(function()
    while true do
      local client, accept_err = server:accept()
      if client then
        cosock.spawn(function() handle_client(driver, client) end, "ring-event-client")
      else
        log.warn("listener accept error: " .. tostring(accept_err))
        socket.sleep(1)
      end
    end
  end, "ring-event-listener")
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

local function set_light_state(driver, device, turn_on)
  local ring_id = get_ring_id(device)
  local ip, port = get_bridge_config(device)
  if not ring_id then return end

  local code, err = http_json("POST", string.format("http://%s:%d/api/lights/%s/state", ip, port, ring_id), { on = turn_on })
  if code and code >= 200 and code < 300 then
    set_online(device, true)
    -- Always emit after a command so the app's pending state resolves.
    device:emit_event(turn_on and capabilities.switch.switch.on() or capabilities.switch.switch.off())
  else
    log.warn(string.format("[%s] light command failed: %s", device.label, tostring(code or err)))
    if not code then set_online(device, false) end
    local current = device:get_latest_state("main", capabilities.switch.ID, capabilities.switch.switch.NAME) or "off"
    device:emit_event(capabilities.switch.switch[current]())
  end
end

local function handle_switch_on(driver, device, cmd) set_light_state(driver, device, true) end
local function handle_switch_off(driver, device, cmd) set_light_state(driver, device, false) end
local function handle_refresh(driver, device, cmd) sync_device_bridge(driver, device) end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local function device_init(driver, device)
  device:set_field("online", nil)
  sync_device_bridge(driver, device)
end

local function device_added(driver, device)
  sync_device_bridge(driver, device)
end

local function device_info_changed(driver, device, event, args)
  local old = (args and args.old_st_store and args.old_st_store.preferences) or {}
  local prefs = device.preferences or {}
  if old.bridgeIp ~= prefs.bridgeIp or old.bridgePort ~= prefs.bridgePort then
    device:set_field("online", nil)
    local ip, port = get_bridge_config(device)
    ensure_subscribed(driver, ip, port, true)
    sync_device_bridge(driver, device)
  end
end

---------------------------------------------------------------------------
-- Discovery
---------------------------------------------------------------------------

local function discovery_handler(driver, opts, cons)
  -- Reuse the bridge address from an existing device if there is one.
  local ip, port = DEFAULT_BRIDGE_IP, DEFAULT_BRIDGE_PORT
  local existing = driver:get_devices()[1]
  if existing then ip, port = get_bridge_config(existing) end

  local code, devices = http_json("GET", string.format("http://%s:%d/api/devices", ip, port))
  if code ~= 200 or type(devices) ~= "table" then
    log.warn("discovery: bridge not reachable at " .. bridge_key(ip, port))
    return
  end

  for _, dev in ipairs(devices) do
    local dni = "ring-" .. tostring(dev.id)
    if not find_device(driver, dev.id) then
      driver:try_create_device({
        type = "LAN",
        device_network_id = dni,
        label = dev.name,
        profile = (dev.category == "light") and "ring-light" or "ring-contact",
        manufacturer = "Ring",
        model = dev.category,
        vendor_provided_label = dev.name,
      })
    end
  end
end

---------------------------------------------------------------------------

local ring_driver = Driver("ring-lan-bridge", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    infoChanged = device_info_changed,
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = handle_switch_on,
      [capabilities.switch.commands.off.NAME] = handle_switch_off,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
    },
  },
})

ring_driver:call_with_delay(0, function(driver) start_listener(driver) end)
ring_driver:call_on_schedule(FALLBACK_POLL_SECONDS, poll_all, "ring-fallback-poll")

ring_driver:run()
