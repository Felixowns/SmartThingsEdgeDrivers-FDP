-- Gledopto sub-driver for the FDP Zigbee Switch driver
--
-- Adds the Zigbee features Gledopto RGB+CCT / RGBW controllers expose beyond basic color control:
--   * configurable transition (fade) time for level, color, color temperature and on/off
--   * power-on behavior        (OnOff 0x0006 / StartUpOnOff 0x4003)
--   * power-on brightness      (Level 0x0008 / StartUpCurrentLevel 0x4000)
--   * power-on color temp      (Color Control 0x0300 / StartUpColorTemperatureMireds 0x4010)
--   * color loop               (Color Control ColorLoopSet, run by the controller) via the `mode` capability
--   * auto-off timer           (OnOff OnWithTimedOff 0x42)
-- Reference: Zigbee2MQTT Gledopto device pages (GL-C-007P / GL-C-007S / GL-C-007-1ID / GL-C-008P)
-- Existing Gledopto devices on a plain rgbw-bulb profile are moved to the matching gledopto-* profile.

local capabilities = require "st.capabilities"
local clusters = require "st.zigbee.zcl.clusters"
local cluster_base = require "st.zigbee.cluster_base"
local data_types = require "st.zigbee.data_types"
local st_utils = require "st.utils"
local configurationMap = require "configurations"
local switch_utils = require "switch_utils"

local OnOff = clusters.OnOff
local Level = clusters.Level
local ColorControl = clusters.ColorControl

-- Standard ZCL attributes written with raw IDs (not every lua lib version defines them)
local ATTR_ONOFF_START_UP_ON_OFF = 0x4003
local ATTR_LEVEL_ON_OFF_TRANSITION_TIME = 0x0010
local ATTR_LEVEL_START_UP_CURRENT_LEVEL = 0x4000
local ATTR_COLOR_START_UP_COLOR_TEMP = 0x4010

local PREVIOUS_LEVEL = 0xFF
local PREVIOUS_COLOR_TEMP = 0xFFFF

local DEFAULT_TRANSITION_SECONDS = 0.5
local PROFILE_APPLIED = "__gledopto_profile_applied"
local WRITE_ATTRIBUTE_RESPONSE_ID = 0x04

local POWER_ON_BEHAVIOR = {
  ["off"] = 0x00,
  ["on"] = 0x01,
  ["toggle"] = 0x02,
  ["previous"] = 0xFF,
}

-- Effects (selected through the `mode` capability). The controller runs the color loop itself
-- (Color Control ColorLoopSet). "None" and "Stop color loop" both stop it.
-- Removed after testing on GL-C-007: the Identify TriggerEffect effects (Blink, Breathe, Okay,
-- Channel change, Finish, Stop), Identify, and the driver-run blink / breathe / color loop.
local EFFECT_NONE = "None"
local EFFECT_COLOR_LOOP = "Color loop"
local DEFAULT_COLOR_LOOP_SECONDS = 30
local EFFECTS = {
  { name = EFFECT_NONE, kind = "none" },
  { name = EFFECT_COLOR_LOOP, kind = "deviceloop" },
  { name = "Stop color loop", kind = "stoploop" },
}

-- Color Control attributes read back after starting the device loop (shown in the hub log for diagnosis)
local ATTR_COLOR_LOOP_ACTIVE = 0x4002
local ATTR_COLOR_CAPABILITIES = 0x400A

local ACTIVE_EFFECT = "__gledopto_active_effect"
local EFFECT_GENERATION = "__gledopto_effect_generation"
local EFFECT_TIMER = "__gledopto_effect_timer"

----------------------------------------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------------------------------------

local function get_fingerprint(device)
  local FINGERPRINTS = require "gledopto.fingerprints"
  return (FINGERPRINTS[device:get_manufacturer()] or {})[device:get_model()]
end

-- attributes the device answered UNSUPPORTED_ATTRIBUTE to are remembered and never written again
local ZCL_STATUS_UNSUPPORTED_ATTRIBUTE = 0x86
local function unsupported_key(cluster_id, attr_id)
  return string.format("__gledopto_unsupported_%04X_%04X", cluster_id, attr_id)
end

local function write_attr(device, cluster_id, attr_id, data_type, value)
  if device:get_field(unsupported_key(cluster_id, attr_id)) then
    return
  end
  device:send(cluster_base.write_attribute(device,
    data_types.ClusterId(cluster_id),
    data_types.AttributeId(attr_id),
    data_types.validate_or_build_type(value, data_type, "payload")))
end

local function read_attr(device, cluster_id, attr_id)
  device:send(cluster_base.read_attribute(device,
    data_types.ClusterId(cluster_id),
    data_types.AttributeId(attr_id)))
end

-- transition time in 1/10 s; an explicit `rate` argument (seconds) on the command wins over the preference
local function get_transition_time(device, cmd)
  local seconds = cmd and cmd.args and tonumber(cmd.args.rate)
  if seconds == nil then
    seconds = tonumber(device.preferences.transitionTime) or DEFAULT_TRANSITION_SECONDS
  end
  return st_utils.clamp_value(math.floor(seconds * 10 + 0.5), 0, 0xFFFE)
end

-- read attributes back once the fade has finished
local function delayed_read(device, transition_time, attributes)
  local delay = math.max(1, math.ceil(transition_time / 10) + 1)
  device.thread:call_with_delay(delay, function()
    for _, attribute in ipairs(attributes) do
      device:send(attribute:read(device))
    end
  end)
end

local function turn_on_if_off(device)
  if device:get_latest_state("main", capabilities.switch.ID, capabilities.switch.switch.NAME) ~= "on" then
    device:send(OnOff.server.commands.On(device))
  end
end

-- kelvin limits: what the device reported (color_temp_range_handlers) or the fingerprint defaults
local function get_kelvin_bounds(device)
  local fp = get_fingerprint(device) or {}
  local min_k, max_k = fp.min_kelvin or 2000, fp.max_kelvin or 6500
  local max_mired = device:get_field(switch_utils.MIRED_MAX_BOUND)
  local min_mired = device:get_field(switch_utils.MIRED_MIN_BOUND)
  if max_mired and min_mired and min_mired < max_mired then
    min_k = switch_utils.convert_mired_to_kelvin(max_mired)
    max_k = switch_utils.convert_mired_to_kelvin(min_mired)
  end
  return min_k, max_k
end

local function emit_supported_effects(device)
  local names = {}
  for _, effect in ipairs(EFFECTS) do
    table.insert(names, effect.name)
  end
  -- skip if the app already has this exact list (avoids history spam on every settings change)
  local current = device:get_latest_state("main", capabilities.mode.ID, capabilities.mode.supportedModes.NAME)
  if type(current) == "table" and table.concat(current, "|") == table.concat(names, "|") then
    return
  end
  device:emit_event(capabilities.mode.supportedModes(names, { visibility = { displayed = false } }))
  pcall(function()
    device:emit_event(capabilities.mode.supportedArguments(names, { visibility = { displayed = false } }))
  end)
  switch_utils.emit_event_if_latest_state_missing(device, "main", capabilities.mode,
    capabilities.mode.mode.NAME, capabilities.mode.mode(EFFECT_NONE))
end

-- Devices joined before this sub-driver existed are on rgbw-bulb-*; move them to the gledopto profile.
-- Also moves devices between gledopto profiles when fingerprints.lua assigns a different one.
local function migrate_profile(device)
  local fp = get_fingerprint(device)
  if fp == nil or fp.profile == nil then return end
  if device:get_field(PROFILE_APPLIED) == fp.profile then return end
  device:set_field(PROFILE_APPLIED, fp.profile, { persist = true })
  device.log.info("Gledopto: switching profile to " .. fp.profile)
  device:try_update_metadata({ profile = fp.profile })
end

-- WriteAttributeResponse: remember attributes this firmware doesn't have
local function write_attr_response_handler(driver, device, zb_rx)
  local cluster_id = zb_rx.address_header.cluster.value
  local body = zb_rx.body and zb_rx.body.zcl_body
  for _, record in ipairs((body and body.attr_records) or {}) do
    local status = record.status and record.status.value
    local attr_id = record.attr_id and record.attr_id.value
    if status == ZCL_STATUS_UNSUPPORTED_ATTRIBUTE and attr_id ~= nil then
      device.log.info(string.format("Gledopto: cluster 0x%04X attribute 0x%04X not supported by this firmware, will stop writing it",
        cluster_id, attr_id))
      device:set_field(unsupported_key(cluster_id, attr_id), true, { persist = true })
    end
  end
end

----------------------------------------------------------------------------------------------------
-- preferences -> device attributes
----------------------------------------------------------------------------------------------------

local preference_writers = {
  transitionTime = function(device, value)
    local tt = st_utils.clamp_value(math.floor((tonumber(value) or 0) * 10 + 0.5), 0, 0xFFFE)
    write_attr(device, Level.ID, ATTR_LEVEL_ON_OFF_TRANSITION_TIME, data_types.Uint16, tt)
  end,
  powerOnBehavior = function(device, value)
    local raw = POWER_ON_BEHAVIOR[value]
    if raw ~= nil then
      write_attr(device, OnOff.ID, ATTR_ONOFF_START_UP_ON_OFF, data_types.Enum8, raw)
    end
  end,
  startupLevel = function(device, value)
    local pct = tonumber(value) or 0
    local raw = PREVIOUS_LEVEL
    if pct > 0 then
      raw = st_utils.clamp_value(math.floor(pct / 100.0 * 254 + 0.5), 1, 254)
    end
    write_attr(device, Level.ID, ATTR_LEVEL_START_UP_CURRENT_LEVEL, data_types.Uint8, raw)
  end,
  startupColorTemp = function(device, value)
    local kelvin = tonumber(value) or 0
    local raw = PREVIOUS_COLOR_TEMP
    if kelvin > 0 then
      local min_k, max_k = get_kelvin_bounds(device)
      kelvin = st_utils.clamp_value(kelvin, min_k, max_k)
      raw = st_utils.round(switch_utils.MIREDS_CONVERSION_CONSTANT / kelvin)
    end
    write_attr(device, ColorControl.ID, ATTR_COLOR_START_UP_COLOR_TEMP, data_types.Uint16, raw)
  end,
}

local function sync_all_preferences(device)
  for name, writer in pairs(preference_writers) do
    local value = device.preferences[name]
    if value ~= nil then
      writer(device, value)
    end
  end
end

----------------------------------------------------------------------------------------------------
-- color loop (run by the controller)
----------------------------------------------------------------------------------------------------

local function to_zigbee_percent(value)
  return st_utils.clamp_value(math.floor((tonumber(value) or 0) / 100.0 * 254 + 0.5), 0, 254)
end

local function color_loop_seconds(device)
  return st_utils.clamp_value(math.floor(tonumber(device.preferences.colorLoopSpeed) or DEFAULT_COLOR_LOOP_SECONDS), 3, 600)
end

-- persisted: the controller keeps looping across hub / driver restarts, so we must remember it
local function set_active_effect(device, value)
  device:set_field(ACTIVE_EFFECT, value, { persist = true })
end

-- cancels a pending delayed loop start
local function new_generation(device)
  local gen = (device:get_field(EFFECT_GENERATION) or 0) + 1
  device:set_field(EFFECT_GENERATION, gen)
  local timer = device:get_field(EFFECT_TIMER)
  if timer ~= nil then
    device.thread:cancel_timer(timer)
    device:set_field(EFFECT_TIMER, nil)
  end
  return gen
end

-- Stop the color loop. force = true sends the stop even if the driver doesn't think a loop is running
-- (e.g. one started from another controller or before a driver reinstall).
local function stop_color_loop(device, force)
  if not force and device:get_field(ACTIVE_EFFECT) == nil then return end
  new_generation(device)
  set_active_effect(device, nil)
  -- update flags 0x01 = action only; action 0x00 = deactivate
  device:send(ColorControl.server.commands.ColorLoopSet(device, 0x01, 0x00, 0x00, 0x0000, 0x0000))
  -- pull the color the light ended on into the app
  delayed_read(device, 0, { ColorControl.attributes.CurrentHue, ColorControl.attributes.CurrentSaturation })
end

local function start_color_loop(device)
  local gen = new_generation(device)
  set_active_effect(device, "deviceloop")
  turn_on_if_off(device)
  local hue = to_zigbee_percent(device:get_latest_state("main", capabilities.colorControl.ID,
    capabilities.colorControl.hue.NAME) or 0)
  -- the loop only runs in hue/saturation mode; full saturation moves the controller out of
  -- white (color temperature) mode, where ColorLoopSet is accepted but nothing visible happens
  device:send(ColorControl.server.commands.MoveToHueAndSaturation(device, hue, 254, 0))
  device:set_field(EFFECT_TIMER, device.thread:call_with_delay(1, function()
    if device:get_field(EFFECT_GENERATION) ~= gen then return end
    device:set_field(EFFECT_TIMER, nil)
    -- update flags 0x07 = action | direction | time
    -- action 0x02 = start from the current hue; direction 0x01 = increment; time = seconds per full loop
    device:send(ColorControl.server.commands.ColorLoopSet(device, 0x07, 0x02, 0x01, color_loop_seconds(device), 0x0000))
    -- diagnostics in the hub log: ColorLoopActive should read 1; ColorCapabilities bit 2 = color loop supported
    read_attr(device, ColorControl.ID, ATTR_COLOR_LOOP_ACTIVE)
    read_attr(device, ColorControl.ID, ATTR_COLOR_CAPABILITIES)
  end))
end

-- change the speed of a running loop without restarting it (update flags 0x04 = time only)
local function update_color_loop_speed(device)
  device:send(ColorControl.server.commands.ColorLoopSet(device, 0x04, 0x00, 0x00, color_loop_seconds(device), 0x0000))
end

----------------------------------------------------------------------------------------------------
-- capability handlers
----------------------------------------------------------------------------------------------------

-- switch on: plain On, or OnWithTimedOff when the auto-off timer preference is set
local function switch_on_handler(driver, device, cmd)
  stop_color_loop(device, false)
  local minutes = tonumber(device.preferences.autoOffMinutes) or 0
  if minutes > 0 then
    local on_time = st_utils.clamp_value(math.floor(minutes * 600), 1, 0xFFFE) -- 1/10 s units
    local ok = pcall(function()
      device:send(OnOff.server.commands.OnWithTimedOff(device, 0x00, on_time, 0x0000))
    end)
    if ok then
      delayed_read(device, 0, { OnOff.attributes.OnOff })
      return
    end
    device.log.warn("Gledopto: OnWithTimedOff unavailable, sending plain On")
  end
  device:send(OnOff.server.commands.On(device))
  delayed_read(device, 0, { OnOff.attributes.OnOff })
end

local function switch_off_handler(driver, device, cmd)
  stop_color_loop(device, false)
  device:send(OnOff.server.commands.Off(device))
  delayed_read(device, 0, { OnOff.attributes.OnOff })
end

local function set_level_handler(driver, device, cmd)
  stop_color_loop(device, false)
  local tt = get_transition_time(device, cmd)
  local level = st_utils.clamp_value(math.floor(cmd.args.level / 100.0 * 254 + 0.5), 0, 254)
  device:send(Level.server.commands.MoveToLevelWithOnOff(device, level, tt))
  delayed_read(device, tt, { Level.attributes.CurrentLevel, OnOff.attributes.OnOff })
end

local function set_color_handler(driver, device, cmd)
  stop_color_loop(device, false)
  local tt = get_transition_time(device, cmd)
  turn_on_if_off(device)
  device:send(ColorControl.server.commands.MoveToHueAndSaturation(device,
    to_zigbee_percent(cmd.args.color.hue), to_zigbee_percent(cmd.args.color.saturation), tt))
  delayed_read(device, tt, { ColorControl.attributes.CurrentHue, ColorControl.attributes.CurrentSaturation, OnOff.attributes.OnOff })
end

local function set_hue_handler(driver, device, cmd)
  stop_color_loop(device, false)
  local tt = get_transition_time(device, cmd)
  turn_on_if_off(device)
  device:send(ColorControl.server.commands.MoveToHue(device, to_zigbee_percent(cmd.args.hue), 0x00, tt))
  delayed_read(device, tt, { ColorControl.attributes.CurrentHue, OnOff.attributes.OnOff })
end

local function set_saturation_handler(driver, device, cmd)
  stop_color_loop(device, false)
  local tt = get_transition_time(device, cmd)
  turn_on_if_off(device)
  device:send(ColorControl.server.commands.MoveToSaturation(device, to_zigbee_percent(cmd.args.saturation), tt))
  delayed_read(device, tt, { ColorControl.attributes.CurrentSaturation, OnOff.attributes.OnOff })
end

local function set_color_temperature_handler(driver, device, cmd)
  stop_color_loop(device, false)
  local tt = get_transition_time(device, cmd)
  local min_k, max_k = get_kelvin_bounds(device)
  local kelvin = st_utils.clamp_value(cmd.args.temperature, min_k, max_k)
  local mireds = st_utils.round(switch_utils.MIREDS_CONVERSION_CONSTANT / kelvin)
  turn_on_if_off(device)
  device:send(ColorControl.server.commands.MoveToColorTemperature(device, mireds, tt))
  delayed_read(device, tt, { ColorControl.attributes.ColorTemperatureMireds, OnOff.attributes.OnOff })
end

local function set_effect_handler(driver, device, cmd)
  local requested = cmd.args.mode
  local kind
  for _, effect in ipairs(EFFECTS) do
    if effect.name == requested then kind = effect.kind end
  end
  if kind == nil then
    device.log.warn("Gledopto: unknown effect " .. tostring(requested))
    return
  end
  device.log.info(string.format("Gledopto effect: %s", requested))

  if kind == "deviceloop" then
    device:emit_event(capabilities.mode.mode(EFFECT_COLOR_LOOP))
    local ok, err = pcall(start_color_loop, device)
    if not ok then
      device.log.warn("Gledopto: color loop failed: " .. tostring(err))
      device:emit_event(capabilities.mode.mode(EFFECT_NONE))
    end
  else
    -- "None" or "Stop color loop"; the explicit stop always sends, even if no loop is known to be running
    stop_color_loop(device, kind == "stoploop")
    device:emit_event(capabilities.mode.mode(EFFECT_NONE))
  end
end

local function do_refresh(driver, device)
  local attributes = {
    OnOff.attributes.OnOff,
    Level.attributes.CurrentLevel,
    ColorControl.attributes.ColorTemperatureMireds,
    ColorControl.attributes.CurrentHue,
    ColorControl.attributes.CurrentSaturation,
  }
  for _, attribute in ipairs(attributes) do
    device:send(attribute:read(device))
  end
end

----------------------------------------------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------------------------------------------

-- Mirrors the base driver's device_init (sub-driver lifecycle handlers replace the base ones)
local function component_to_endpoint(device, component_id)
  local ep_num = component_id:match("switch(%d)")
  return ep_num and tonumber(ep_num) or device.fingerprinted_endpoint_id
end

local function endpoint_to_component(device, ep)
  local switch_comp = string.format("switch%d", ep)
  if device.profile.components[switch_comp] ~= nil then
    return switch_comp
  end
  return "main"
end

local function device_init(driver, device)
  device:set_component_to_endpoint_fn(component_to_endpoint)
  device:set_endpoint_to_component_fn(endpoint_to_component)

  local configuration = configurationMap.get_device_configuration(device)
  if configuration ~= nil then
    for _, attribute in ipairs(configuration) do
      device:add_configured_attribute(attribute)
    end
  end
  device:set_find_child(require "lifecycle_handlers.find_child")

  migrate_profile(device)
  if device:supports_capability(capabilities.mode) then
    emit_supported_effects(device)
  end
end

local function device_added(driver, device, event)
  require("lifecycle_handlers.device_added")(driver, device, event)

  local fp = get_fingerprint(device)
  if fp and fp.min_kelvin and fp.max_kelvin then
    switch_utils.emit_event_if_latest_state_missing(device, "main", capabilities.colorTemperature,
      capabilities.colorTemperature.colorTemperatureRange.NAME,
      capabilities.colorTemperature.colorTemperatureRange({ value = { minimum = fp.min_kelvin, maximum = fp.max_kelvin } }))
  end
  if device:supports_capability(capabilities.mode) then
    emit_supported_effects(device)
  end
end

local function do_configure(driver, device)
  -- base configure: refresh, reporting, physical min/max mireds
  require("lifecycle_handlers.do_configure")(driver, device)
  sync_all_preferences(device)
end

local function info_changed(driver, device, event, args)
  local old = (args and args.old_st_store and args.old_st_store.preferences) or {}
  if device:get_field(ACTIVE_EFFECT) == "deviceloop"
    and device.preferences.colorLoopSpeed ~= old.colorLoopSpeed then
    update_color_loop_speed(device)
  end
  for name, writer in pairs(preference_writers) do
    local value = device.preferences[name]
    if value ~= nil and value ~= old[name] then
      writer(device, value)
    end
  end
  if device:supports_capability(capabilities.mode) then
    emit_supported_effects(device)
  end
end

local gledopto = {
  NAME = "Gledopto",
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = switch_on_handler,
      [capabilities.switch.commands.off.NAME] = switch_off_handler,
    },
    [capabilities.switchLevel.ID] = {
      [capabilities.switchLevel.commands.setLevel.NAME] = set_level_handler,
    },
    [capabilities.colorControl.ID] = {
      [capabilities.colorControl.commands.setColor.NAME] = set_color_handler,
      [capabilities.colorControl.commands.setHue.NAME] = set_hue_handler,
      [capabilities.colorControl.commands.setSaturation.NAME] = set_saturation_handler,
    },
    [capabilities.colorTemperature.ID] = {
      [capabilities.colorTemperature.commands.setColorTemperature.NAME] = set_color_temperature_handler,
    },
    [capabilities.mode.ID] = {
      [capabilities.mode.commands.setMode.NAME] = set_effect_handler,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = do_refresh,
    },
  },
  zigbee_handlers = {
    global = {
      [OnOff.ID] = { [WRITE_ATTRIBUTE_RESPONSE_ID] = write_attr_response_handler },
      [Level.ID] = { [WRITE_ATTRIBUTE_RESPONSE_ID] = write_attr_response_handler },
      [ColorControl.ID] = { [WRITE_ATTRIBUTE_RESPONSE_ID] = write_attr_response_handler },
    },
  },
  lifecycle_handlers = {
    init = configurationMap.reconfig_wrapper(device_init),
    added = device_added,
    doConfigure = do_configure,
    infoChanged = info_changed,
  },
  can_handle = require("gledopto.can_handle"),
}

return gledopto
