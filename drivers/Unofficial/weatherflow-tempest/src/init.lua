-- WeatherFlow Tempest (LAN) Edge driver.
--
-- The Tempest hub broadcasts UDP JSON on port 50222. An Android phone relay
-- (tempest_bridge.py) listens for those broadcasts and forwards them to this
-- driver. The driver tells the relay where to send by periodically sending a
-- "ST_PORT:<port>" handshake *from its listening socket*, so the relay can
-- reply to the handshake's source address without any hard-coded hub IP.

local Driver = require("st.driver")
local capabilities = require("st.capabilities")
local log = require("log")
local cosock = require("cosock")
local socket = cosock.socket
local json = require("st.json")
local tempest = require("tempest")

local DEFAULT_BRIDGE_IP = "192.168.1.17"
local BRIDGE_PORT = 50222
local HANDSHAKE_INTERVAL = 30       -- seconds between handshakes to the relay
local OFFLINE_AFTER = 300           -- seconds without data before marking offline
local HEALTH_CHECK_INTERVAL = 60
local SOCKET_RETRY_DELAY = 5
local DISCOVERY_FALLBACK_SECONDS = 60 -- only used if the platform gives no should_continue

local FIELD_LAST_SEEN = "last_seen"
local FIELD_ONLINE = "online"
local FIELD_EMIT_CACHE = "emit_cache"

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function prefs(device)
  return (device and device.preferences) or {}
end

local function bridge_ip_for(device)
  local ip = prefs(device).bridgeIp
  if type(ip) ~= "string" or ip == "" then return DEFAULT_BRIDGE_IP end
  return ip
end

-- Relay IPs to handshake with / accept packets from.
local function bridge_ips(driver)
  local set, list = {}, {}
  for _, device in ipairs(driver:get_devices()) do
    local ip = bridge_ip_for(device)
    if not set[ip] then
      set[ip] = true
      table.insert(list, ip)
    end
  end
  if #list == 0 then
    set[DEFAULT_BRIDGE_IP] = true
    table.insert(list, DEFAULT_BRIDGE_IP)
  end
  return set, list
end

local function find_device(driver, serial)
  for _, device in ipairs(driver:get_devices()) do
    if device.device_network_id == serial then return device end
  end
  return nil
end

local function set_online(device, online)
  if device:get_field(FIELD_ONLINE) == online then return end
  device:set_field(FIELD_ONLINE, online)
  if online then device:online() else device:offline() end
end

-- Emit only when the value (or unit) differs from what was last emitted.
-- The cache is in-memory, so values are re-emitted once after a driver restart.
local function emit_if_changed(device, key, signature, event)
  local cache = device:get_field(FIELD_EMIT_CACHE)
  if cache == nil then
    cache = {}
    device:set_field(FIELD_EMIT_CACHE, cache)
  end
  signature = tostring(signature)
  if cache[key] ~= signature then
    cache[key] = signature
    device:emit_event(event)
  end
end

---------------------------------------------------------------------------
-- Message handlers
---------------------------------------------------------------------------

local function emit_battery(device, volts)
  volts = tempest.num(volts)
  if not volts or volts <= 0 then return end
  volts = tempest.round(volts, 2)
  emit_if_changed(device, "voltage", volts,
    capabilities.voltageMeasurement.voltage({ value = volts, unit = "V" }))
  local pct = tempest.battery_percent(volts)
  emit_if_changed(device, "battery", pct, capabilities.battery.battery({ value = pct }))
end

local function handle_obs_st(device, payload)
  local r = tempest.parse_obs_st(payload)
  if not r then return end
  local p = prefs(device)
  local units = tempest.unit_system(p.unitSystem)

  if r.temperature then
    local t = tempest.round(r.temperature, 1)
    emit_if_changed(device, "temperature", t,
      capabilities.temperatureMeasurement.temperature({ value = t, unit = "C" }))
  end

  if r.humidity then
    local h = tempest.round(tempest.clamp(r.humidity, 0, 100), 0)
    emit_if_changed(device, "humidity", h,
      capabilities.relativeHumidityMeasurement.humidity({ value = h }))
  end

  local dew = tempest.dew_point_c(r.temperature, r.humidity)
  if dew then
    dew = tempest.round(dew, 1)
    emit_if_changed(device, "dewpoint", dew,
      capabilities.dewPoint.dewpoint({ value = dew, unit = "C" }))
  end

  if r.pressure then
    local mbar = tempest.sea_level_pressure(r.pressure, p.elevationM, r.temperature)
    local value = tempest.round(tempest.convert_pressure(mbar, units.pressure), units.pressure_places)
    emit_if_changed(device, "pressure", value .. units.pressure,
      capabilities.atmosphericPressureMeasurement.atmosphericPressure({ value = value, unit = units.pressure }))
  end

  if r.wind_avg then
    local w = tempest.round(tempest.convert_wind(math.max(r.wind_avg, 0), units.wind), 1)
    emit_if_changed(device, "windspeed", w .. units.wind,
      capabilities.windSpeed.windspeed({ value = w, unit = units.wind }))
  end

  if r.illuminance then
    local lux = tempest.round(tempest.clamp(r.illuminance, 0, tempest.MAX_LUX), 0)
    emit_if_changed(device, "illuminance", lux,
      capabilities.illuminanceMeasurement.illuminance({ value = lux }))
  end

  if r.uv then
    local uv = tempest.round(math.max(r.uv, 0), 1)
    emit_if_changed(device, "uv", uv, capabilities.ultravioletIndex.ultravioletIndex({ value = uv }))
  end

  if r.rain_rate then
    local intensity = tempest.precip_intensity(r.rain_rate, r.precip_type)
    emit_if_changed(device, "precip", intensity,
      capabilities.precipitationSensor.precipitationIntensity({ value = intensity }))
    if r.precip_type and r.precip_type >= 2 then
      log.info(string.format("[%s] hail reported (precip type %d)", device.label, r.precip_type))
    end
  end

  emit_battery(device, r.battery)
end

-- Rain just started: show it immediately instead of waiting for the next obs_st.
local function handle_evt_precip(device)
  local current = device:get_latest_state("main", capabilities.precipitationSensor.ID,
    capabilities.precipitationSensor.precipitationIntensity.NAME)
  if current == nil or current == "none" or current == "possiblePrecipitation" then
    emit_if_changed(device, "precip", "light",
      capabilities.precipitationSensor.precipitationIntensity({ value = "light" }))
  end
end

local function handle_evt_strike(device, payload)
  local evt = type(payload.evt) == "table" and payload.evt or {}
  log.info(string.format("[%s] lightning strike, distance %s km", device.label, tostring(evt[2])))
end

local MESSAGE_HANDLERS = {
  obs_st = handle_obs_st,
  evt_precip = handle_evt_precip,
  evt_strike = handle_evt_strike,
  device_status = function(device, payload) emit_battery(device, payload.voltage) end,
  -- rapid_wind arrives every 3 s; it only counts as a liveness signal. Wind
  -- speed comes from obs_st's per-minute average to avoid flooding events.
  rapid_wind = function() end,
}

local function try_discover(driver, serial)
  if not driver.discovery_active then return end
  if not tempest.is_tempest_serial(serial) then return end
  if driver.provisional_devices[serial] then return end
  driver.provisional_devices[serial] = true

  log.info(string.format("[DISCOVERY] Tempest found [%s], creating device", serial))
  local label = "WeatherFlow Tempest " .. serial:sub(-4)
  driver:try_create_device({
    type = "LAN",
    device_network_id = serial,
    label = label,
    profile = "weatherflow-tempest",
    manufacturer = "WeatherFlow",
    model = "Tempest",
    vendor_provided_label = label,
  })
end

local function handle_packet(driver, data, from_ip)
  local allowed = bridge_ips(driver)
  if not allowed[from_ip] then
    log.debug("ignoring UDP packet from unexpected address " .. tostring(from_ip))
    return
  end

  local ok, payload = pcall(json.decode, data)
  if not ok or type(payload) ~= "table" then return end
  local serial, msg_type = payload.serial_number, payload.type
  if type(serial) ~= "string" or type(msg_type) ~= "string" then return end

  local device = find_device(driver, serial)
  if not device then
    try_discover(driver, serial)
    return
  end

  device:set_field(FIELD_LAST_SEEN, os.time())
  set_online(device, true)

  local handler = MESSAGE_HANDLERS[msg_type]
  if handler then handler(device, payload) end
end

---------------------------------------------------------------------------
-- UDP listener (single coroutine; recreates its socket on failure)
---------------------------------------------------------------------------

local function send_handshakes(udp, port, driver)
  local _, ips = bridge_ips(driver)
  for _, ip in ipairs(ips) do
    local sent, err = udp:sendto("ST_PORT:" .. tostring(port), ip, BRIDGE_PORT)
    if not sent then
      log.warn(string.format("handshake to %s:%d failed: %s", ip, BRIDGE_PORT, tostring(err)))
    end
  end
end

local function run_listener_once(driver)
  local udp, err = socket.udp()
  if not udp then
    log.error("could not create UDP socket: " .. tostring(err))
    return
  end

  local ok, bind_err = udp:setsockname("0.0.0.0", 0)
  if not ok then
    log.error("could not bind UDP socket: " .. tostring(bind_err))
    udp:close()
    return
  end

  local _, port = udp:getsockname()
  log.info(string.format("listening for relay on UDP port %s", tostring(port)))
  udp:settimeout(1)

  local last_handshake = 0
  driver.force_handshake = true
  while true do
    local now = os.time()
    if driver.force_handshake or now - last_handshake >= HANDSHAKE_INTERVAL then
      driver.force_handshake = false
      last_handshake = now
      send_handshakes(udp, port, driver)
    end

    local data, ip_or_err = udp:receivefrom()
    if data then
      local handled, handle_err = pcall(handle_packet, driver, data, ip_or_err)
      if not handled then
        log.error("error handling packet: " .. tostring(handle_err))
      end
    elseif ip_or_err ~= "timeout" then
      log.warn("UDP receive error, recreating socket: " .. tostring(ip_or_err))
      break
    end
  end

  udp:close()
end

local function start_listener(driver)
  cosock.spawn(function()
    while true do
      run_listener_once(driver)
      socket.sleep(SOCKET_RETRY_DELAY)
    end
  end, "tempest-udp-listener")
end

local function check_health(driver)
  local now = os.time()
  for _, device in ipairs(driver:get_devices()) do
    local last_seen = device:get_field(FIELD_LAST_SEEN)
    if last_seen and now - last_seen > OFFLINE_AFTER then
      if device:get_field(FIELD_ONLINE) ~= false then
        log.warn(string.format("[%s] no data for %ds, marking offline", device.label, now - last_seen))
      end
      set_online(device, false)
    end
  end
end

---------------------------------------------------------------------------
-- Lifecycle & discovery
---------------------------------------------------------------------------

local function device_init(driver, device)
  log.info(string.format("[%s] initialized", device.label))
  device:set_field(FIELD_ONLINE, nil)
  device:set_field(FIELD_EMIT_CACHE, nil)
  -- Grace period: give the relay OFFLINE_AFTER seconds before declaring offline.
  device:set_field(FIELD_LAST_SEEN, os.time())
  driver.force_handshake = true
end

local function device_info_changed(driver, device, _, args)
  local old = (args and args.old_st_store and args.old_st_store.preferences) or {}
  local new = prefs(device)
  if old.bridgeIp ~= new.bridgeIp then
    driver.force_handshake = true
  end
  if old.unitSystem ~= new.unitSystem or old.elevationM ~= new.elevationM then
    device:set_field(FIELD_EMIT_CACHE, nil) -- re-emit on the next observation
  end
end

local function discovery_handler(driver, _, should_continue)
  log.info("[DISCOVERY] started")
  driver.provisional_devices = {}
  driver.discovery_active = true
  driver.force_handshake = true

  if type(should_continue) == "function" then
    while should_continue() do socket.sleep(1) end
  else
    socket.sleep(DISCOVERY_FALLBACK_SECONDS)
  end

  driver.discovery_active = false
  log.info("[DISCOVERY] finished")
end

local weatherflow_driver = Driver("weatherflow-tempest", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    infoChanged = device_info_changed,
  },
})

weatherflow_driver.discovery_active = false
weatherflow_driver.provisional_devices = {}
weatherflow_driver.force_handshake = true

weatherflow_driver:call_with_delay(0, function(driver) start_listener(driver) end)
weatherflow_driver:call_on_schedule(HEALTH_CHECK_INTERVAL, check_health, "tempest-health-check")

weatherflow_driver:run()
