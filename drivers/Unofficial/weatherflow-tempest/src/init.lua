local Driver = require("st.driver")
local capabilities = require("st.capabilities")
local cosock = require("cosock")
local socket = cosock.socket
local json = require("dkjson")

local ANDROID_PHONE_IP = "192.168.1.17" 

-- Helper to track registered devices
local function find_existing_device(driver, serial_number)
  local active_devices = driver:get_devices()
  for _, device in ipairs(active_devices) do
    if device.device_network_id == serial_number then
      return device
    end
  end
  return nil
end

-- Persistent Handshake: Optimized 30-second loop
local function send_handshake(driver, port)
  print(string.format("Attempting handshake to phone at %s:50222", ANDROID_PHONE_IP))
  local handshake_sock = socket.udp()
  handshake_sock:sendto("ST_PORT:" .. tostring(port), ANDROID_PHONE_IP, 50222)
  handshake_sock:close()
  
  driver:call_with_delay(30, function() send_handshake(driver, port) end)
end

local function start_udp_listener(driver)
  cosock.spawn(function()
    local udp = socket.udp()
    udp:setoption('reuseaddr', true)
    local ok, _ = udp:setsockname("0.0.0.0", 0)
    if not ok then return end
    
    local _, assigned_port = udp:getsockname()
    print(string.format("SmartThings assigned local port: %s", assigned_port))
    
    send_handshake(driver, assigned_port)
    
    udp:settimeout(1) 
    while true do
      local data, _, _ = udp:receivefrom()
      if data then
        local payload, _, json_err = json.decode(data)
        
        if not json_err and payload and payload.serial_number and payload.type then
          local device_serial = payload.serial_number
          local device = find_existing_device(driver, device_serial)
          
          if device then
            ---------------------------------------------------------
            -- CASE 1: DEVICE EXISTS -> PROCESS INCOMING DATA
            ---------------------------------------------------------
            if payload.type == "obs_st" and payload.obs and payload.obs[1] then
              local obs = payload.obs[1]
              
              if obs[8] then device:emit_event(capabilities.temperatureMeasurement.temperature({value = obs[8], unit = "C"})) end
              if obs[9] then device:emit_event(capabilities.relativeHumidityMeasurement.humidity({value = obs[9]})) end
              
              -- PRESSURE CONVERSION: Convert from mbar to inHg and round to 2 decimal places
              if obs[7] then 
                local pressure_inhg = obs[7] * 0.02953
                pressure_inhg = math.floor(pressure_inhg * 100 + 0.5) / 100
                device:emit_event(capabilities.atmosphericPressureMeasurement.atmosphericPressure({value = pressure_inhg, unit = "inHg"})) 
              end
              
              -- SAFETY BOUNDARY FILTER: Clamp lux values to SmartThings max limit (100,000)
              if obs[10] then 
                local safe_lux = math.min(obs[10], 100000)
                device:emit_event(capabilities.illuminanceMeasurement.illuminance({value = safe_lux})) 
              end
              
              if obs[11] then device:emit_event(capabilities.ultravioletIndex.ultravioletIndex({value = obs[11]})) end
              
              -- PRECIPITATION SENSOR: Fixed to use precipitationIntensity attribute
              -- obs[13] is rain accumulation in mm for the current minute
              if obs[13] then
                local precip_state = "none"
                if obs[13] > 0 and obs[13] < 0.2 then
                  precip_state = "light"
                elseif obs[13] >= 0.2 and obs[13] < 0.8 then
                  precip_state = "moderate"
                elseif obs[13] >= 0.8 then
                  precip_state = "heavy"
                end
                
                -- Corrected field call to precipitationIntensity
                device:emit_event(capabilities.precipitationSensor.precipitationIntensity({value = precip_state}))
              end

              if obs[16] and type(obs[16]) == "number" and obs[16] > 0 then 
                device:emit_event(capabilities.voltageMeasurement.voltage({value = obs[16], unit = "V"})) 
              end
            
            elseif payload.type == "device_status" and payload.voltage then
              device:emit_event(capabilities.voltageMeasurement.voltage({value = payload.voltage, unit = "V"}))
            end
            
          else
            ---------------------------------------------------------
            -- CASE 2: NEW DEVICE FOUND -> DYNAMIC DISCOVERY ENGINE
            ---------------------------------------------------------
            if driver.discovery_active then
              local serial_prefix = string.sub(device_serial, 1, 3)
              
              if serial_prefix == "ST-" then
                if not driver.provisional_devices[device_serial] then
                  driver.provisional_devices[device_serial] = true
                  
                  print(string.format("[DISCOVERY] Valid sensor found [%s]. Creating device...", device_serial))
                  
                  local short_sn = string.sub(device_serial, -4)
                  local metadata = {
                    type = "LAN",
                    device_network_id = device_serial,
                    label = "WeatherFlow Tempest " .. short_sn,
                    profile = "weatherflow-tempest", 
                    manufacturer = "WeatherFlow",
                    model = "Tempest"
                  }
                  
                  driver:try_create_device(metadata)
                end
              else
                print(string.format("[DISCOVERY FILTER] Ignored non-sensor device: %s", device_serial))
              end
            end
          end
          
        end
      end
    end
  end, "WeatherFlow_UDP_Thread")
end

-- SmartThings Discovery Scan Trigger Handler
local function discovery_handler(driver, opts, cons)
  print("[DISCOVERY] Scan window opened by user in SmartThings App.")
  driver.provisional_devices = {}
  driver.discovery_active = true
  
  driver:call_with_delay(45, function()
    driver.discovery_active = false
    print("[DISCOVERY] Scan window closed automatically.")
  end)
end

-- Driver Definition
local weatherflow_driver = Driver("weatherflow_udp_dynamic", {
  discovery = discovery_handler,
  lifecycle_handlers = { 
    init = function(driver, device)
      print(string.format("Device initialized/synced: %s", device.label))
    end 
  }
})

weatherflow_driver.discovery_active = false
weatherflow_driver.provisional_devices = {}

start_udp_listener(weatherflow_driver)
weatherflow_driver:run()