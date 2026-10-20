local Driver = require("st.driver")
local capabilities = require("st.capabilities")
local log = require("log")
local https = require("cosock.ssl.https")
local ltn12 = require("ltn12")
local json = require("st.json")

-- ==========================================================
-- Helper: HTTPS GET → parsed table or nil
-- ==========================================================
local function https_get(ip, path, token)
  local body = {}
  local _, code = https.request({
    url     = "https://" .. ip .. path,
    method  = "GET",
    sink    = ltn12.sink.table(body),
    headers = {
      ["Accept"]        = "application/json",
      ["Authorization"] = "Bearer " .. token
    },
    protocol = "any",
    verify   = "none"
  })

  if code ~= 200 then
    log.error("[ENVOY] HTTP GET " .. path .. " → " .. tostring(code))
    return nil
  end

  local ok, data = pcall(json.decode, table.concat(body))
  if not ok then
    log.error("[ENVOY] JSON parse failed for " .. path)
    return nil
  end

  return data
end

-- ==========================================================
-- Core Poll
-- ==========================================================
local function query_envoy(device)
  local ip = device.preferences.ipAddress
  local t1 = device.preferences.authToken1 or ""
  local t2 = device.preferences.authToken2 or ""
  local token = (t1 .. t2):match("^%s*(.-)%s*$")

  if not ip or ip == "" or token == "" then
    log.warn("[ENVOY] IP or token not set — skipping poll")
    return
  end

  local data = https_get(ip, "/production.json", token)
  if not data then return end

  -- --------------------------------------------------------
  -- PRODUCTION (type=eim)
  -- --------------------------------------------------------
  local prod_w_now    = 0
  local prod_wh_today = 0
  local prod_wh_7day  = 0
  local prod_wh_life  = 0

  for _, entry in ipairs(data.production or {}) do
    if entry.type == "eim" then
      prod_w_now    = math.max(entry.wNow            or 0, 0)
      prod_wh_today = math.max(entry.whToday         or 0, 0)
      prod_wh_7day  = math.max(entry.whLastSevenDays or 0, 0)
      prod_wh_life  = math.max(entry.whLifetime      or 0, 0)
      break
    end
  end

  -- --------------------------------------------------------
  -- CONSUMPTION
  -- --------------------------------------------------------
  local cons_w_now    = 0
  local cons_wh_today = 0
  local net_w_now     = 0   -- negative = exporting, positive = importing

  for _, entry in ipairs(data.consumption or {}) do
    if entry.measurementType == "total-consumption" then
      cons_w_now    = math.max(entry.wNow    or 0, 0)
      cons_wh_today = math.max(entry.whToday or 0, 0)
    elseif entry.measurementType == "net-consumption" then
      net_w_now = entry.wNow or 0
    end
  end

  -- --------------------------------------------------------
  -- GRID DIRECTION
  -- net_w_now < 0 → exporting to grid (solar > home)
  -- net_w_now > 0 → importing from grid (home > solar)
  -- --------------------------------------------------------
  local grid_abs    = math.abs(net_w_now)
  local exporting   = net_w_now < 0
  local grid_label  = exporting and "Exporting to Grid" or "Importing from Grid"

  log.info(string.format(
    "[ENVOY] Solar: %.0fW | Home: %.0fW | %s: %.0fW",
    prod_w_now, cons_w_now, grid_label, grid_abs
  ))
  log.info(string.format(
    "[ENVOY] Today → Solar: %.2f kWh | Home: %.2f kWh | 7-day: %.1f kWh | Lifetime: %.1f kWh",
    prod_wh_today / 1000, cons_wh_today / 1000,
    prod_wh_7day / 1000, prod_wh_life / 1000
  ))

  -- --------------------------------------------------------
  -- EMIT: main → Solar Production
  -- --------------------------------------------------------
  device:emit_event(capabilities.powerMeter.power({
    value = prod_w_now, unit = "W"
  }))
  device:emit_event(capabilities.energyMeter.energy({
    value = prod_wh_today / 1000, unit = "kWh"
  }))

  -- --------------------------------------------------------
  -- EMIT: consumed → Home Consumption
  -- --------------------------------------------------------
  device:emit_component_event(
    device.profile.components.consumed,
    capabilities.powerMeter.power({ value = cons_w_now, unit = "W" })
  )
  device:emit_component_event(
    device.profile.components.consumed,
    capabilities.energyMeter.energy({ value = cons_wh_today / 1000, unit = "kWh" })
  )

  -- --------------------------------------------------------
  -- EMIT: grid → net flow
  -- powerMeter = absolute wattage (always positive, automatable)
  -- switch = on means exporting, off means importing
  --   → use in automations: "when grid switch is ON" = sending to grid
  -- --------------------------------------------------------
  device:emit_component_event(
    device.profile.components.grid,
    capabilities.powerMeter.power({ value = grid_abs, unit = "W" })
  )

  -- switch ON = exporting (solar surplus), OFF = importing (drawing from grid)
  device:emit_component_event(
    device.profile.components.grid,
    exporting and capabilities.switch.switch.on() or capabilities.switch.switch.off()
  )

  -- Label flips in logs — ST doesn't support dynamic component labels natively
  -- but the switch state + powerMeter value together give full automation capability
  log.debug(string.format("[ENVOY] Grid component: %.0fW | switch=%s (%s)",
    grid_abs, exporting and "ON" or "OFF", grid_label))
end

-- ==========================================================
-- Discovery Handler
-- ==========================================================
local function discovery_handler(driver, _, should_continue)
  if not should_continue() then return end
  log.info("[ENVOY] Discovery triggered. Creating Envoy device...")
  driver:try_create_device({
    type              = "LAN",
    device_network_id = "envoy-local-manual-1",
    label             = "Enphase Envoy",
    profile           = "envoy-local-power",
    manufacturer      = "Enphase",
    model             = "IQ Gateway",
    vendor_provided_label = "Envoy Solar Gateway"
  })
end

-- ==========================================================
-- Lifecycle Handlers
-- ==========================================================
local function device_init(driver, device)
  log.info("[ENVOY] Device initialized: " .. device.id)
  query_envoy(device)
  device.thread:call_on_schedule(30, function()
    query_envoy(device)
  end, "EnvoyPollingThread")
end

local function info_changed(driver, device, event, args)
  local old = args.old_st_store.preferences
  if old.ipAddress  ~= device.preferences.ipAddress  or
     old.authToken1 ~= device.preferences.authToken1 or
     old.authToken2 ~= device.preferences.authToken2 then
    log.info("[ENVOY] Preferences updated — triggering immediate poll")
    query_envoy(device)
  end
end

-- ==========================================================
-- Capability Handlers
-- switch commands on grid component are read-only (no physical action)
-- ==========================================================
local function handle_refresh(driver, device, command)
  log.info("[ENVOY] Manual refresh triggered")
  query_envoy(device)
end

local function handle_switch(driver, device, command)
  -- Grid switch is read-only — just re-poll to reflect real state
  log.debug("[ENVOY] Grid switch command ignored (read-only), re-polling")
  query_envoy(device)
end

-- ==========================================================
-- Driver
-- ==========================================================
local envoy_driver = Driver("envoy-local", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init        = device_init,
    infoChanged = info_changed
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
    },
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME]  = handle_switch,
      [capabilities.switch.commands.off.NAME] = handle_switch,
    }
  }
})

log.info("[ENVOY] Starting Envoy Local Edge Driver...")
envoy_driver:run()
