local capabilities = require("st.capabilities")
local Driver = require("st.driver")
local cosock = require("cosock")
local http = cosock.asyncify("socket.http")
local ltn12 = require("ltn12")
local json = require("st.json")

-- Extract Ring Device ID from device_network_id
local function get_ring_id(device)
  if device.device_network_id then
    local id = device.device_network_id:match("^ring%-(.+)$")
    if id then return id end
  end
  return device.preferences and device.preferences.deviceId
end

-- Fetch bridge IP and Port from device preferences
local function get_bridge_config(device)
  local ip = (device and device.preferences and device.preferences.bridgeIp) or "192.168.1.17"
  local port = (device and device.preferences and device.preferences.bridgePort) or 8080
  return ip, port
end

-- Poll sensor/light status from bridge
local function poll_device_state(driver, device)
  local ring_id = get_ring_id(device)
  local ip, port = get_bridge_config(device)

  if not ip or ip == "" or not ring_id then return end

  local is_switch = device:supports_capability(capabilities.switch)
  local path = is_switch and "/api/lights/" or "/api/sensors/"
  local url = string.format("http://%s:%d%s%s", ip, port, path, ring_id)

  local response_chunks = {}
  local res, code, headers, status = http.request({
    url = url,
    method = "GET",
    sink = ltn12.sink.table(response_chunks),
    timeout = 2
  })

  if code == 200 then
    local response_body = table.concat(response_chunks)
    local success, body = pcall(json.decode, response_body)
    if success and body then
      if device:supports_capability(capabilities.contactSensor) then
        if body.state == "open" then
          device:emit_event(capabilities.contactSensor.contact.open())
        elseif body.state == "closed" then
          device:emit_event(capabilities.contactSensor.contact.closed())
        end
      elseif is_switch then
        if body.on then
          device:emit_event(capabilities.switch.switch.on())
        else
          device:emit_event(capabilities.switch.switch.off())
        end
      end
    end
  end
end

-- Post light control command
local function set_light_state(device, turn_on)
  local ring_id = get_ring_id(device)
  local ip, port = get_bridge_config(device)

  if not ip or not ring_id then return end

  local url = string.format("http://%s:%d/api/lights/%s/state", ip, port, ring_id)
  local payload = json.encode({ on = turn_on })
  local response_chunks = {}

  local res, code, headers, status = http.request({
    url = url,
    method = "POST",
    headers = {
      ["Content-Type"] = "application/json",
      ["Content-Length"] = tostring(#payload)
    },
    source = ltn12.source.string(payload),
    sink = ltn12.sink.table(response_chunks),
    timeout = 3
  })

  if turn_on then
    device:emit_event(capabilities.switch.switch.on())
  else
    device:emit_event(capabilities.switch.switch.off())
  end
end

-- Auto-Discovery handler for "Scan for nearby devices"
local function discovery_handler(driver, opts, cons)
  local bridge_ip = "192.168.1.17"
  local bridge_port = 8080

  local url = string.format("http://%s:%d/api/devices", bridge_ip, bridge_port)
  local response_chunks = {}

  local res, code, headers, status = http.request({
    url = url,
    method = "GET",
    sink = ltn12.sink.table(response_chunks),
    timeout = 3
  })

  if code == 200 then
    local response_body = table.concat(response_chunks)
    local success, devices = pcall(json.decode, response_body)
    if success and devices then
      for _, dev in ipairs(devices) do
        local profile_name = (dev.category == "light") and "ring-light" or "ring-contact"

        driver:try_create_device({
          type = "LAN",
          device_network_id = "ring-" .. dev.id,
          label = dev.name,
          profile = profile_name,
          manufacturer = "Ring",
          model = dev.category,
          vendor_provided_label = dev.name
        })
      end
    end
  end
end

-- Lifecycle init handler
local function device_init(driver, device)
  device.thread:call_on_schedule(2, function()
    poll_device_state(driver, device)
  end)
end

-- Command Handlers
local function handle_switch_on(driver, device, cmd)
  set_light_state(device, true)
end

local function handle_switch_off(driver, device, cmd)
  set_light_state(device, false)
end

local function handle_refresh(driver, device, cmd)
  poll_device_state(driver, device)
end

local ring_driver = Driver("ring-lan-bridge", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = handle_switch_on,
      [capabilities.switch.commands.off.NAME] = handle_switch_off,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
    }
  }
})

ring_driver:run()