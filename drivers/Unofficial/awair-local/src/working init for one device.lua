local Driver = require("st.driver")
local log = require("log")
local socket = require("cosock.socket") -- The specific asynchronous library wrapper
local json = require("dkjson")
local capabilities = require("st.capabilities")

-- Base configuration
local PROFILE_NAME = "awair_sensor.v1"

-- Helper Function: Validates IP layout syntax and extracts targets
local function validate_address(addr)
  local ip, port = addr:match('http://([^:]+):?(.*)$')
  port = (port == '') and 80 or tonumber(port)
  if ip == nil or type(port) ~= 'number' then
    return nil
  end
  
  local chunks = {ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")}
  if #chunks ~= 4 then return nil end
  for _, v in pairs(chunks) do
    if tonumber(v) > 255 then return nil end
  end
  if (port < 1) or (port > 65535) then
    return nil
  end
  
  return ip, port
end

-- Core Network Parser: Provided HTTP parsing client engine
local http_get = socket.protect(function(url)
  local host, path = string.match(url, "http://([^/]+)(/.*)")
  socket.try(host, 'invalid url: enter valid uri in the config')
  local ip, port = validate_address('http://'..host)
  socket.try(ip, 'invalid url: enter valid uri in the config')
  
  local c = socket.try(socket.connect(ip, port))
  c:settimeout(5) -- Safe execution fallback threshold
  
  local ret, chunked, length
  local try = socket.newtry(function() c:close() end)
  
  -- Combined single-packet request write injection
  try(c:send("GET "..path.." HTTP/1.1\r\nHost: "..host.."\r\nConnection: close\r\n\r\n"))
  
  ret = try(c:receive())
  if ret ~= "HTTP/1.1 200 OK" then
    log.warn("[http] unexpected http response token: "..tostring(ret))
  end
  
  while ret ~= '' do
    ret = try(c:receive())
    ret = string.lower(ret)
    if ret == 'transfer-encoding: chunked' then
      chunked = true
    else
      local _, _, value = ret:find("^content%-length:%s*(.*)")
      if value ~= nil then 
        length = tonumber(value)
      end
    end
  end
  
  if chunked ~= true and length == nil then
    try(nil, 'failed to receive content length from header')
  end
  
  local body = ''
  while true do
    if chunked then
      ret = try(c:receive('*l'))
      length = tonumber(ret, 16)
      if length == 0 or length == nil then break end
    end
    
    ret = try(c:receive(length))
    body = body..ret
    
    if chunked then
      try(c:receive(2)) -- skip trailing carriage line blocks
    else
      break
    end
  end
  
  c:close()
  return body
end)

-- Main Driver Routine: Wraps your network parser data back into SmartThings UI Cards
local function fetch_air_data(driver, device)
  local ip = device.preferences.manualIP
  if not ip or ip == "" then
    log.warn("Skipping refresh iteration: No IP found inside settings UI panel.")
    device:offline()
    return
  end

  -- Sanitize formatting quirks out of string properties
  local clean_ip = ip:gsub("%s+", ""):gsub("^https?://", ""):gsub("/+$", "")
  local targeted_url = "http://" .. clean_ip
  
  log.info(string.format("Querying Awair network node via cosock state machine on: %s", targeted_url .. "/air-data/latest"))

  -- Invoke the parser mechanism safe wrapper block
  local success, air_json = pcall(http_get, targeted_url .. "/air-data/latest")
  
  if success and air_json and string.find(air_json, "{") then
    log.info("RAW PAYLOAD CAUGHT VIA COSOCK MACHINE: " .. tostring(air_json))
    device:online()

    local data, _, parse_err = json.decode(air_json)
    if parse_err then
      log.error("JSON library rejected the parsed data string: " .. tostring(parse_err))
      return
    end

    -- Update SmartThings UI capabilities cards natively
    if data.score then
      device:emit_event(capabilities.airQualitySensor.airQuality({value = 100-data.score}))
    end
    if data.temp then
      device:emit_event(capabilities.temperatureMeasurement.temperature({value = data.temp, unit = "C"}))
    end
    if data.humid then
      device:emit_event(capabilities.relativeHumidityMeasurement.humidity({value = data.humid}))
    end
    if data.co2 then
      device:emit_event(capabilities.carbonDioxideMeasurement.carbonDioxide({value = data.co2}))
    end
    if data.voc then
      device:emit_event(capabilities.tvocMeasurement.tvocLevel({value = data.voc/1000, unit = 'ppm'}))
    end
    if data.pm25 then
      device:emit_event(capabilities.fineDustSensor.fineDustLevel({value = data.pm25}))
    end
    log.info(string.format("Successfully synchronized metrics table updates for [%s]", device.label))
  else
    log.error(string.format("Cosock stack tracking execution anomaly or drop. Details: %s", tostring(air_json)))
    device:offline()
  end
end

-- Discovery Handler: Direct layout builder bypassing mDNS dependencies completely
local function discovery_handler(driver, opts, cons)
  log.info("SmartThings scan invoked. Spawning static local device instance tile...")
  local default_device_msg = {
    type = "LAN",
    device_network_id = "awair_local_fixed_ip_instance", 
    label = "Awair Air Sensor",
    profile = PROFILE_NAME, 
    manufacturer = "Awair",
    model = "Awair Element"
  }
  driver:try_create_device(default_device_msg)
end

-- Lifecycle Hooks Configuration
local function info_changed(driver, device, event, args)
  log.info("Preferences structural change caught. Forcing connection re-eval.")
  fetch_air_data(driver, device)
end

local function device_init(driver, device)
  log.info(string.format("Attaching background async polling thread loop for: %s", device.label))
  fetch_air_data(driver, device)
  
  local timer = device.thread:call_on_schedule(10, function()
    fetch_air_data(driver, device)
  end)
  device:set_field("thread_timer", timer)
end

local function device_removed(driver, device)
  local timer = device:get_field("thread_timer")
  if timer then device.thread:cancel_timer(timer) end
end

-- Instantiate structural definitions mapping hooks
local awair_driver = Driver("awair_local_driver", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    infoChanged = info_changed,
    removed = device_removed
  }
})

awair_driver:run()