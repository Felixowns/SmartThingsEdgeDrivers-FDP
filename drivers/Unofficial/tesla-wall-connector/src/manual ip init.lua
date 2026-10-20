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
-- 1. CORE NETWORK & TELEMETRY LOGIC
-- ==============================================================================
local function fetch_vitals(driver, device)
  local ip = device.preferences.ipAddress
  if not ip or ip == "192.168.1.xxx" or ip == "" then
    log.warn(string.format("[%s] IP address is default or empty. Skipping API poll.", device.label))
    return
  end

  local response_chunks = {}
  local url = string.format("http://%s/api/1/vitals", ip:gsub("%s+", ""))
  
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
      -- 1. Grid Voltage Measurement (Main Component)
      if data.grid_v then
        device:emit_event(capabilities.voltageMeasurement.voltage({value = data.grid_v, unit = "V"}))
      end
      
      -- 2. Session Energy (Safe fallback if key changes; converts Wh to kWh)
      local raw_energy = data.session_energy_wh or 0
      local energy_kwh = raw_energy / 1000
      device:emit_event(capabilities.energyMeter.energy({value = energy_kwh, unit = "kWh"}))
      
      -- 3. Calculate Power Draw (Watts = Volts * Amps)
      if data.grid_v and data.vehicle_current_a then
        local power_w = data.grid_v * data.vehicle_current_a
        device:emit_event(capabilities.powerMeter.power({value = power_w, unit = "W"}))
      end

      -- 4. Contactor State Mapping (Main Component)
      if data.contactor_closed ~= nil then
        local contact_value = data.contactor_closed and "closed" or "open"
        device:emit_event(capabilities.contactSensor.contact(contact_value))
      end

      -- Main Component: PCBA (Main Circuit Board) Temperature
      if data.pcba_temp_c then
        device:emit_event(capabilities.temperatureMeasurement.temperature({value = data.pcba_temp_c, unit = "C"}))
      end

      -- Handle Component: Physical Charging Cable Handle Temperature
      if data.handle_temp_c then
        local handle_comp = device.profile.components["handle"]
        if handle_comp then
          handle_comp:emit_event(capabilities.temperatureMeasurement.temperature({value = data.handle_temp_c, unit = "C"}))
        end
      end

      -- MCU Component: Microcontroller/Processor Temperature
      if data.mcu_temp_c then
        local mcu_comp = device.profile.components["mcu"]
        if mcu_comp then
          mcu_comp:emit_event(capabilities.temperatureMeasurement.temperature({value = data.mcu_temp_c, unit = "C"}))
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

-- Manages background timers for data polling using Driver context
local function start_polling_timer(driver, device)
  -- 1. Retrieve the existing object handle via get_field
  local existing_timer = device:get_field("vitals_timer_handle")
  if existing_timer then
    log.info(string.format("[%s] Cancelling old polling schedule.", device.label))
    driver:cancel_timer(existing_timer)
    device:set_field("vitals_timer_handle", nil)
  end

  local interval = device.preferences.pollingInterval or 30
  log.info(string.format("[%s] Scheduling automated polling loop every %d seconds.", device.label, interval))
  
  -- 2. Create the schedule on the persistent driver context
  local new_timer = driver:call_on_schedule(
    interval, 
    function()
      fetch_vitals(driver, device)
    end, 
    "vitals_poll_" .. device.id  -- Keeps the timer identifier unique per device instance
  )
  
  -- 3. Save the object handle back to the device fields
  device:set_field("vitals_timer_handle", new_timer)
end

-- ==============================================================================
-- 2. AUTOMATIC SCAN/DISCOVERY HANDLER
-- ==============================================================================
local function discovery_handler(driver, opts, cons)
  local unique_id = tostring(socket.gettime()):gsub("%.", ""):sub(-6)
  local generated_dni = "tesla_wc_instance_" .. unique_id
  local generated_label = "Tesla Wall Connector " .. unique_id

  log.info(string.format("Spawning Tesla Tile Instance. DNI: %s | Label: %s", generated_dni, generated_label))
  
  local default_device_msg = {
    type = "LAN",
    device_network_id = generated_dni, 
    label = generated_label,
    profile = PROFILE_NAME, 
    manufacturer = "Tesla",
    model = "Gen 3 Wall Connector"
  }
  
  driver:try_create_device(default_device_msg)
end

-- ==============================================================================
-- 3. LIFECYCLE & INTERACTION HANDLERS
-- ==============================================================================
local function device_init(driver, device)
  log.info(string.format("Initializing background loops for: %s", device.label))
  start_polling_timer(driver, device)
end

local function device_added(driver, device)
  log.info(string.format("New device added to panel: %s", device.label))
  fetch_vitals(driver, device)
end

local function handler_refresh(driver, device, command)
  log.info(string.format("[%s] Refresh requested manually.", device.label))
  fetch_vitals(driver, device)
end

local function device_info_changed(driver, device, event, args)
  -- Defensive check to protect against blank or uninitialized state stores
  if args.old_st_store and args.old_st_store.preferences then
    if args.old_st_store.preferences.pollingInterval ~= device.preferences.pollingInterval or
       args.old_st_store.preferences.ipAddress ~= device.preferences.ipAddress then
      log.info(string.format("[%s] Network configurations updated. Refreshing loops.", device.label))
      start_polling_timer(driver, device)
      fetch_vitals(driver, device)
    end
  end
end

-- ==============================================================================
-- 4. DRIVER INSTANTIATION
-- ==============================================================================
local tesla_driver = Driver("TeslaWallConnector", {
  --discovery = discovery_handler, 
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    infoChanged = device_info_changed
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handler_refresh
    }
  }
})

tesla_driver:run()