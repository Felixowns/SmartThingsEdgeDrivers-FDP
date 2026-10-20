local Driver = require("st.driver")
local capabilities = require("st.capabilities")
local cosock = require("cosock")
local http = cosock.asyncify("socket.http")
local socket = require("cosock.socket") 
local log = require("log")
local ltn12 = require("ltn12")
local json = require("dkjson")

local PROFILE_NAME = "tesla-wall-connector"

-- ==============================================================================
-- 1. HELPER: GET ACTIVE IP OR HOSTNAME
-- ==============================================================================
local function get_active_ip(device)
  -- Safety guard: check if device or preferences exist
  if not device or not device.preferences then
    return nil
  end

  -- 1. Manual preference override
  local pref_ip = device.preferences.ipAddress
  if pref_ip and pref_ip ~= "" and pref_ip ~= "192.168.1.xxx" then
    return pref_ip:gsub("%s+", "")
  end
  
  -- 2. Auto-discovered IP stored in hub flash memory
  local stored_ip = device:get_field("ip_address")
  if stored_ip and stored_ip ~= "" then
    return stored_ip
  end

  return nil
end

-- ==============================================================================
-- 2. CORE NETWORK & TELEMETRY LOGIC
-- ==============================================================================
local function fetch_vitals(driver, device)
  local ip = get_active_ip(device)
  
  if not ip then
    log.warn(string.format("[%s] No IP found in settings or flash memory. Skipping poll.", device and device.label or "Unknown Device"))
    return
  end

  local response_chunks = {}
  local url = string.format("http://%s/api/1/vitals", ip)
  
  log.info(string.format("[%s] Polling vitals over local network: %s", device.label, url))

  local res, code, headers, status = http.request{
    url = url,
    method = "GET",
    sink = ltn12.sink.table(response_chunks),
    timeout = 5
  }

  if code == 200 then
    local response_body = table.concat(response_chunks)
    local data, pos, err = json.decode(response_body)
    
    if data then
      -- 1. Grid Voltage
      if data.grid_v then
        device:emit_event(capabilities.voltageMeasurement.voltage({value = tonumber(data.grid_v), unit = "V"}, {state_change = true}))
      end
      
      -- 2. Session Energy (kWh)
      local raw_energy = data.session_energy_wh or 0
      local energy_kwh = raw_energy / 1000
      device:emit_event(capabilities.energyMeter.energy({value = tonumber(energy_kwh), unit = "kWh"}, {state_change = true}))
      
      -- 3. Power Draw
      if data.grid_v and data.vehicle_current_a then
        local power_w = data.grid_v * data.vehicle_current_a
        device:emit_event(capabilities.powerMeter.power({value = tonumber(power_w), unit = "W"}, {state_change = true}))
      end

      -- 4. Contactor State
      if data.contactor_closed ~= nil then
        local contact_value = data.contactor_closed and "closed" or "open"
        device:emit_event(capabilities.contactSensor.contact(contact_value))
      end

      -- 5. Main Component Board Temp
      if data.pcba_temp_c then
        device:emit_event(capabilities.temperatureMeasurement.temperature({value = tonumber(data.pcba_temp_c), unit = "C"}, {state_change = true}))
      end

      -- 6. Cable Handle Temp
      if data.handle_temp_c then
        local handle_comp = device.profile.components["handle"]
        if handle_comp then
          handle_comp:emit_event(capabilities.temperatureMeasurement.temperature({value = tonumber(data.handle_temp_c), unit = "C"}, {state_change = true}))
        end
      end

      -- 7. Processor MCU Temp
      if data.mcu_temp_c then
        local mcu_comp = device.profile.components["mcu"]
        if mcu_comp then
          mcu_comp:emit_event(capabilities.temperatureMeasurement.temperature({value = tonumber(data.mcu_temp_c), unit = "C"}, {state_change = true}))
        end
      end
      
      device:online()
    else
      log.error("Failed to parse Wall Connector json payload: " .. tostring(err))
    end
  else
    log.error(string.format("[%s] Wall Connector offline/unreachable. Code: %s", device.label, tostring(code)))
    device:offline()
  end
end

-- Background Polling Manager
local function start_polling_timer(driver, device)
  local existing_timer = device:get_field("vitals_timer_handle")
  if existing_timer then
    driver:cancel_timer(existing_timer)
    device:set_field("vitals_timer_handle", nil)
  end

  local interval = device.preferences and device.preferences.pollingInterval or 30
  
  local new_timer = driver:call_on_schedule(
    interval, 
    function() fetch_vitals(driver, device) end, 
    "vitals_poll_" .. device.id
  )
  
  device:set_field("vitals_timer_handle", new_timer)
end

-- ==============================================================================
-- 3. AUTO-DISCOVERY HANDLER (Batched Parallel IP Sweep)
-- ==============================================================================
local function discovery_handler(driver, opts, cons)
  log.info("==================================================")
  log.info("Starting Tesla Wall Connector Subnet Sweep...")
  log.info("==================================================")

  -- Extract subnet prefix from hub IP (e.g., "192.168.1.45" -> "192.168.1")
  local hub_ipv4 = driver.environment_info and driver.environment_info.hub_ipv4 or "192.168.1.45"
  local subnet_prefix = hub_ipv4:match("(%d%+%.%d%+%.%d%+)") or "192.168.1"

  log.info(string.format("[SUBNET SWEEP] Scanning %s.1 through %s.254 (batched)...", subnet_prefix, subnet_prefix))

  local found_devices = {}
  local BATCH_SIZE = 16 -- Max concurrent sockets per batch to prevent hitting hub limits

  for batch_start = 1, 254, BATCH_SIZE do
    local batch_end = math.min(batch_start + BATCH_SIZE - 1, 254)
    local tx, rx = cosock.channel.new()
    local pending_tasks = 0

    for i = batch_start, batch_end do
      local target_ip = string.format("%s.%d", subnet_prefix, i)
      pending_tasks = pending_tasks + 1

      cosock.spawn(function()
        local response_chunks = {}
        local url = string.format("http://%s/api/1/vitals", target_ip)

        local res, code = http.request{
          url = url,
          method = "GET",
          sink = ltn12.sink.table(response_chunks),
          timeout = 1.0
        }

        if code == 200 then
          local body = table.concat(response_chunks)
          local data = json.decode(body)

          -- Verify payload signature for Tesla Wall Connector
          if data and (data.serial_number or data.grid_v or data.handle_temp_c) then
            tx:send({ ip = target_ip, data = data })
          else
            tx:send(false)
          end
        else
          tx:send(false)
        end
      end)
    end

    -- Collect batch results
    for _ = 1, pending_tasks do
      local result = rx:receive()
      if result then
        log.info(string.format("[SUBNET MATCH!] Found Wall Connector at IP: %s", result.ip))
        table.insert(found_devices, result)
      end
    end
  end

  -- Provision Discovered Devices
  log.info(string.format("Provisioning %d discovered Tesla device(s)...", #found_devices))

  for _, dev in ipairs(found_devices) do
    local data = dev.data
    local serial = data.serial_number or "922FD6"
    local dni = "tesla_wc_" .. serial
    local label = "Tesla Wall Connector (" .. serial .. ")"

    log.info(string.format("[CREATE DEVICE] Label: '%s' | DNI: '%s' | IP: %s", label, dni, dev.ip))

    driver:try_create_device({
      type = "LAN",
      device_network_id = dni,
      label = label,
      profile = PROFILE_NAME,
      manufacturer = "Tesla",
      model = "Gen 3 Wall Connector",
      vendor_provided_label = dev.ip
    })
  end

  log.info("==================================================")
  log.info("Tesla Wall Connector discovery scan completed.")
  log.info("==================================================")
end

-- ==============================================================================
-- 4. LIFECYCLE HANDLERS
-- ==============================================================================
local function device_init(driver, device)
  device:online()
  start_polling_timer(driver, device)
end

local function device_added(driver, device)
  if device.vendor_provided_label then
    local discovered_ip = device.vendor_provided_label
    log.info(string.format("[%s] Persisting target IP to hub flash memory: %s", device.label, discovered_ip))
    device:set_field("ip_address", discovered_ip, { persist = true })
  end
  
  fetch_vitals(driver, device)
end

local function device_removed(driver, device)
  log.info(string.format("[%s] Device removed. Cleaning up active timers.", device.label))
  local existing_timer = device:get_field("vitals_timer_handle")
  if existing_timer then
    driver:cancel_timer(existing_timer)
    device:set_field("vitals_timer_handle", nil)
  end
end

local function handler_refresh(driver, device, command)
  fetch_vitals(driver, device)
end

local function device_info_changed(driver, device, event, args)
  if args.old_st_store and args.old_st_store.preferences then
    if args.old_st_store.preferences.pollingInterval ~= device.preferences.pollingInterval or
       args.old_st_store.preferences.ipAddress ~= device.preferences.ipAddress then
      start_polling_timer(driver, device)
      fetch_vitals(driver, device)
    end
  end
end

-- ==============================================================================
-- 5. DRIVER INSTANTIATION
-- ==============================================================================
local tesla_driver = Driver("TeslaWallConnector", {
  discovery = discovery_handler, 
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    removed = device_removed,
    infoChanged = device_info_changed
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handler_refresh
    }
  }
})

tesla_driver:run()