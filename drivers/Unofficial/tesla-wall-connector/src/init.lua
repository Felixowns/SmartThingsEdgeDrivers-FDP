local Driver = require("st.driver")
local capabilities = require("st.capabilities")
local cosock = require("cosock")
local http = cosock.asyncify("socket.http")
local log = require("log")
local ltn12 = require("ltn12")
local json = require("dkjson")

local PROFILE_NAME = "tesla-wall-connector"
local DNI_PREFIX = "tesla_wc_"
local PLACEHOLDER_IP = "192.168.1.xxx"

local POLL_TIMEOUT_S = 5
local SCAN_TIMEOUT_S = 1
local SCAN_BATCH_SIZE = 16              -- concurrent sockets per batch
local FAILURES_BEFORE_OFFLINE = 3       -- consecutive failed polls before marking offline
local FAILURES_BEFORE_RESCAN = 5        -- consecutive failed polls before searching for a new IP
local RESCAN_COOLDOWN_S = 15 * 60       -- don't re-sweep the subnet more often than this
local ENERGY_REPORT_INTERVAL_S = 15 * 60 -- SmartThings Energy expects reports >= 15 min apart
local CHARGING_CURRENT_THRESHOLD_A = 1.0

-- Tesla's (undocumented) evse_state value for an error condition.
local TESLA_EVSE_STATE_ERROR = 7

-- Persisted field names
local FIELD_IP = "ip_address"
local FIELD_SERIAL = "serial_number"
local FIELD_LAST_ENERGY_REPORT = "last_energy_report_ts"
-- Non-persisted field names
local FIELD_FAILURES = "consecutive_failures"
local FIELD_TIMER = "vitals_timer_handle"
local FIELD_RESCANNING = "rescan_in_progress"
local FIELD_LAST_RESCAN = "last_rescan_ts"

-- IPs found during discovery, handed to device_added (keyed by DNI)
local pending_discovery_ips = {}

-- ==============================================================================
-- 1. HELPERS
-- ==============================================================================
local function round(value, decimals)
  local mult = 10 ^ (decimals or 0)
  return math.floor(value * mult + 0.5) / mult
end

local function iso8601(epoch)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", epoch)
end

local function label_of(device)
  return device and device.label or "Tesla Wall Connector"
end

--- GET a JSON endpoint on the Wall Connector.
--- LuaSocket's http.request ignores a `timeout` key in the request table; it uses
--- the module-level http.TIMEOUT, read synchronously when the socket is created.
--- Setting it right before the call (with no yield in between) is coroutine-safe.
local function get_json(ip, path, timeout)
  local chunks = {}
  http.TIMEOUT = timeout or POLL_TIMEOUT_S
  local _, code = http.request{
    url = string.format("http://%s%s", ip, path),
    method = "GET",
    sink = ltn12.sink.table(chunks),
  }
  if code ~= 200 then
    return nil, "HTTP " .. tostring(code)
  end
  local data, _, err = json.decode(table.concat(chunks))
  if type(data) ~= "table" then
    return nil, "JSON parse error: " .. tostring(err)
  end
  return data
end

--- Returns the serial number if `ip` hosts a Tesla Wall Connector, otherwise nil.
local function probe_wall_connector(ip, timeout)
  local version = get_json(ip, "/api/1/version", timeout)
  if version and version.serial_number and version.part_number then
    return version.serial_number, version
  end
  return nil
end

local function get_subnet_prefix(driver)
  local hub_ip = driver.environment_info and driver.environment_info.hub_ipv4
  local prefix = hub_ip and hub_ip:match("^(%d+%.%d+%.%d+)%.%d+$")
  if not prefix then
    log.warn("Could not determine hub IPv4 address; falling back to 192.168.1.x")
    prefix = "192.168.1"
  end
  return prefix
end

--- Sweep the hub's /24 for Wall Connectors.
--- opts.skip_ips: set of IPs not to probe
--- opts.want_serial: stop early once this serial is found
--- opts.should_continue: function returning false to abort between batches
local function sweep_subnet(driver, opts)
  opts = opts or {}
  local skip = opts.skip_ips or {}
  local prefix = get_subnet_prefix(driver)
  local found = {}

  log.info(string.format("Scanning %s.1-254 for Tesla Wall Connectors...", prefix))

  for batch_start = 1, 254, SCAN_BATCH_SIZE do
    if opts.should_continue and not opts.should_continue() then
      log.info("Scan stopped early (discovery ended)")
      break
    end

    local batch_end = math.min(batch_start + SCAN_BATCH_SIZE - 1, 254)
    local tx, rx = cosock.channel.new()
    local pending = 0

    for i = batch_start, batch_end do
      local ip = string.format("%s.%d", prefix, i)
      if not skip[ip] then
        pending = pending + 1
        cosock.spawn(function()
          local ok, serial = pcall(probe_wall_connector, ip, SCAN_TIMEOUT_S)
          tx:send((ok and serial) and { ip = ip, serial = serial } or false)
        end, "twc_probe_" .. ip)
      end
    end

    local done = false
    for _ = 1, pending do
      local result = rx:receive()
      if result then
        log.info(string.format("Found Wall Connector %s at %s", result.serial, result.ip))
        table.insert(found, result)
        if opts.want_serial and result.serial == opts.want_serial then
          done = true
        end
      end
    end
    if done then break end
  end

  return found
end

-- ==============================================================================
-- 2. IP / IDENTITY
-- ==============================================================================
local function get_manual_ip(device)
  local pref_ip = device.preferences and device.preferences.ipAddress
  if pref_ip then
    pref_ip = (pref_ip:gsub("%s+", ""))
    if pref_ip ~= "" and pref_ip ~= PLACEHOLDER_IP and pref_ip:match("^%d+%.%d+%.%d+%.%d+$") then
      return pref_ip
    end
  end
  return nil
end

local function get_active_ip(device)
  local manual = get_manual_ip(device)
  if manual then return manual end
  local stored = device:get_field(FIELD_IP)
  if stored and stored ~= "" then return stored end
  return nil
end

local function get_serial(device)
  local serial = device:get_field(FIELD_SERIAL)
  if serial then return serial end
  local from_dni = device.device_network_id and device.device_network_id:match("^" .. DNI_PREFIX .. "(.+)$")
  return from_dni
end

-- ==============================================================================
-- 3. EVENT EMISSION
-- ==============================================================================
local function emit_component(device, component_id, event)
  local comp = device.profile.components[component_id]
  if comp then
    device:emit_component_event(comp, event)
  end
end

local function compute_power_w(data)
  -- Three-phase installs report current/voltage on phase C; split-phase/single-phase do not.
  local ic, vc = tonumber(data.currentC_a), tonumber(data.voltageC_v)
  if ic and vc and ic > CHARGING_CURRENT_THRESHOLD_A and vc > 50 then
    local total = 0
    for _, phase in ipairs({ "A", "B", "C" }) do
      local i = tonumber(data["current" .. phase .. "_a"]) or 0
      local v = tonumber(data["voltage" .. phase .. "_v"]) or 0
      total = total + i * v
    end
    return total
  end

  local v, i = tonumber(data.grid_v), tonumber(data.vehicle_current_a)
  if v and i then
    return v * i
  end
  return nil
end

local function emit_evse_state(device, data)
  local evse = capabilities.evseState
  local connected = data.vehicle_connected == true
  local contactor = data.contactor_closed == true
  local current = tonumber(data.vehicle_current_a) or 0
  local faulted = tonumber(data.evse_state) == TESLA_EVSE_STATE_ERROR

  local state
  if faulted then
    state = evse.state.fault()
  elseif not connected then
    state = evse.state.notPluggedIn()
  elseif contactor and current >= CHARGING_CURRENT_THRESHOLD_A then
    state = evse.state.pluggedInCharging()
  elseif contactor then
    state = evse.state.pluggedInDemand()
  else
    state = evse.state.pluggedInNoDemand()
  end
  device:emit_event(state)

  if faulted then
    device:emit_event(evse.supplyState.disabledError())
    device:emit_event(evse.faultState.other())
  else
    device:emit_event(contactor and evse.supplyState.chargingEnabled() or evse.supplyState.disabled())
    device:emit_event(evse.faultState.noError())
  end

  if type(data.current_alerts) == "table" and #data.current_alerts > 0 then
    log.warn(string.format("[%s] Active alerts: %s", label_of(device), table.concat(data.current_alerts, ", ")))
  end
end

local function emit_vitals(device, data)
  if data.grid_v then
    device:emit_event(capabilities.voltageMeasurement.voltage({ value = round(tonumber(data.grid_v), 1), unit = "V" }))
  end

  local power = compute_power_w(data)
  if power then
    device:emit_event(capabilities.powerMeter.power({ value = round(power, 0), unit = "W" }))
  end

  if data.session_energy_wh then
    emit_component(device, "session",
      capabilities.energyMeter.energy({ value = round(tonumber(data.session_energy_wh) / 1000, 3), unit = "kWh" }))
  end

  if data.pcba_temp_c then
    device:emit_event(capabilities.temperatureMeasurement.temperature({ value = round(tonumber(data.pcba_temp_c), 1), unit = "C" }))
  end
  if data.handle_temp_c then
    emit_component(device, "handle",
      capabilities.temperatureMeasurement.temperature({ value = round(tonumber(data.handle_temp_c), 1), unit = "C" }))
  end
  if data.mcu_temp_c then
    emit_component(device, "mcu",
      capabilities.temperatureMeasurement.temperature({ value = round(tonumber(data.mcu_temp_c), 1), unit = "C" }))
  end

  emit_evse_state(device, data)
end

--- Lifetime energy drives the cumulative energyMeter and SmartThings Energy reports.
local function emit_lifetime(device, lifetime)
  local total_wh = tonumber(lifetime.energy_wh)
  if not total_wh then return end

  device:emit_event(capabilities.energyMeter.energy({ value = round(total_wh / 1000, 3), unit = "kWh" }))

  local now = os.time()
  local last_ts = device:get_field(FIELD_LAST_ENERGY_REPORT)
  if not last_ts then
    -- First reading: establish a baseline without reporting a bogus lifetime-sized delta.
    device:set_field(FIELD_LAST_ENERGY_REPORT, now, { persist = true })
  elseif now - last_ts >= ENERGY_REPORT_INTERVAL_S then
    local delta = 0
    local prev = device:get_latest_state("main", capabilities.powerConsumptionReport.ID,
      capabilities.powerConsumptionReport.powerConsumption.NAME)
    if prev and prev.energy then
      delta = math.max(total_wh - prev.energy, 0)
    end
    device:emit_event(capabilities.powerConsumptionReport.powerConsumption({
      start = iso8601(last_ts),
      ["end"] = iso8601(now - 1),
      deltaEnergy = delta,
      energy = total_wh,
    }))
    device:set_field(FIELD_LAST_ENERGY_REPORT, now, { persist = true })
  end
end

-- ==============================================================================
-- 4. POLLING
-- ==============================================================================
local fetch_vitals -- forward declaration

local function maybe_rescan_for_new_ip(driver, device)
  if get_manual_ip(device) then return end -- user pinned an IP; respect it
  local serial = get_serial(device)
  if not serial then return end
  if device:get_field(FIELD_RESCANNING) then return end
  local last = device:get_field(FIELD_LAST_RESCAN) or 0
  if os.time() - last < RESCAN_COOLDOWN_S then return end

  device:set_field(FIELD_RESCANNING, true)
  device:set_field(FIELD_LAST_RESCAN, os.time())
  log.info(string.format("[%s] Unreachable; searching subnet for serial %s", label_of(device), serial))

  cosock.spawn(function()
    local skip = {}
    local old_ip = device:get_field(FIELD_IP)
    if old_ip then skip[old_ip] = true end

    local ok, found = pcall(sweep_subnet, driver, { skip_ips = skip, want_serial = serial })
    device:set_field(FIELD_RESCANNING, nil)
    if not ok then
      log.error(string.format("[%s] Rescan failed: %s", label_of(device), tostring(found)))
      return
    end
    for _, hit in ipairs(found) do
      if hit.serial == serial then
        log.info(string.format("[%s] Wall Connector moved to %s", label_of(device), hit.ip))
        device:set_field(FIELD_IP, hit.ip, { persist = true })
        device.thread:queue_event(fetch_vitals, driver, device)
        return
      end
    end
    log.warn(string.format("[%s] Rescan did not find serial %s", label_of(device), serial))
  end, "twc_rescan_" .. device.id)
end

local function record_failure(driver, device, reason)
  local failures = (device:get_field(FIELD_FAILURES) or 0) + 1
  device:set_field(FIELD_FAILURES, failures)
  log.warn(string.format("[%s] Poll failed (%d in a row): %s", label_of(device), failures, reason))

  if failures >= FAILURES_BEFORE_OFFLINE then
    device:offline()
  end
  if failures >= FAILURES_BEFORE_RESCAN then
    maybe_rescan_for_new_ip(driver, device)
  end
end

fetch_vitals = function(driver, device)
  local ip = get_active_ip(device)
  if not ip then
    log.warn(string.format("[%s] No IP configured or discovered; skipping poll", label_of(device)))
    device:offline()
    maybe_rescan_for_new_ip(driver, device)
    return
  end

  log.debug(string.format("[%s] Polling %s", label_of(device), ip))

  local vitals, err = get_json(ip, "/api/1/vitals", POLL_TIMEOUT_S)
  if not vitals then
    record_failure(driver, device, err)
    return
  end

  device:set_field(FIELD_FAILURES, 0)
  emit_vitals(device, vitals)

  local lifetime = get_json(ip, "/api/1/lifetime", POLL_TIMEOUT_S)
  if lifetime then
    emit_lifetime(device, lifetime)
  end

  -- Learn the serial once (needed to find the charger again if its IP changes)
  if not device:get_field(FIELD_SERIAL) then
    local serial = probe_wall_connector(ip, POLL_TIMEOUT_S)
    if serial then
      device:set_field(FIELD_SERIAL, serial, { persist = true })
    end
  end

  device:online()
end

local function start_polling_timer(driver, device)
  local existing = device:get_field(FIELD_TIMER)
  if existing then
    device.thread:cancel_timer(existing)
    device:set_field(FIELD_TIMER, nil)
  end

  local interval = tonumber(device.preferences and device.preferences.pollingInterval) or 30
  local timer = device.thread:call_on_schedule(interval, function()
    fetch_vitals(driver, device)
  end, "vitals_poll_" .. device.id)
  device:set_field(FIELD_TIMER, timer)
end

-- ==============================================================================
-- 5. DISCOVERY
-- ==============================================================================
local function discovery_handler(driver, opts, should_continue)
  local known_serials, known_ips = {}, {}
  for _, dev in ipairs(driver:get_devices()) do
    local serial = get_serial(dev)
    if serial then known_serials[serial] = true end
    local ip = get_active_ip(dev)
    if ip then known_ips[ip] = true end
  end

  local found = sweep_subnet(driver, { skip_ips = known_ips, should_continue = should_continue })

  for _, hit in ipairs(found) do
    if not known_serials[hit.serial] then
      local dni = DNI_PREFIX .. hit.serial
      pending_discovery_ips[dni] = hit.ip
      log.info(string.format("Creating device %s (%s)", dni, hit.ip))
      driver:try_create_device({
        type = "LAN",
        device_network_id = dni,
        label = "Tesla Wall Connector",
        profile = PROFILE_NAME,
        manufacturer = "Tesla",
        model = "Gen 3 Wall Connector",
      })
    end
  end

  log.info(string.format("Discovery finished; %d new Wall Connector(s)", #found))
end

-- ==============================================================================
-- 6. LIFECYCLE HANDLERS
-- ==============================================================================
local function device_init(driver, device)
  -- Legacy: older versions of this driver passed the IP via vendor_provided_label
  if not device:get_field(FIELD_IP) and device.vendor_provided_label
      and device.vendor_provided_label:match("^%d+%.%d+%.%d+%.%d+$") then
    device:set_field(FIELD_IP, device.vendor_provided_label, { persist = true })
  end

  start_polling_timer(driver, device)
  -- Poll right away so online/offline reflects reality instead of assuming online
  device.thread:call_with_delay(1, function() fetch_vitals(driver, device) end)
end

local function device_added(driver, device)
  local ip = pending_discovery_ips[device.device_network_id]
  if ip then
    device:set_field(FIELD_IP, ip, { persist = true })
    pending_discovery_ips[device.device_network_id] = nil
  end
  local serial = device.device_network_id:match("^" .. DNI_PREFIX .. "(.+)$")
  if serial then
    device:set_field(FIELD_SERIAL, serial, { persist = true })
  end
  fetch_vitals(driver, device)
end

local function device_removed(driver, device)
  local existing = device:get_field(FIELD_TIMER)
  if existing then
    device.thread:cancel_timer(existing)
    device:set_field(FIELD_TIMER, nil)
  end
end

local function handler_refresh(driver, device, command)
  fetch_vitals(driver, device)
end

local function device_info_changed(driver, device, event, args)
  local old = args.old_st_store and args.old_st_store.preferences
  if not old then return end
  if old.pollingInterval ~= device.preferences.pollingInterval then
    start_polling_timer(driver, device)
  end
  if old.ipAddress ~= device.preferences.ipAddress then
    device:set_field(FIELD_FAILURES, 0)
    fetch_vitals(driver, device)
  end
end

-- ==============================================================================
-- 7. DRIVER
-- ==============================================================================
local tesla_driver = Driver("TeslaWallConnector", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    removed = device_removed,
    infoChanged = device_info_changed,
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handler_refresh,
    },
  },
})

tesla_driver:run()
