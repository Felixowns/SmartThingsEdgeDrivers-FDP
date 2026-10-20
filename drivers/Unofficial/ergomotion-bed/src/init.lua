local Driver = require("st.driver")
local log = require("log")
local socket = require("cosock.socket") 
local capabilities = require("st.capabilities")

-- Base configuration
local PROFILE_NAME = "ergomotion-bed"

-- 1. COMMANDS
local commands = {
    FLAT = string.char(0xAA, 0x03, 0x00, 0x0A, 0x00, 0x04, 0x01, 0x00, 0x00, 0x00, 0x08, 0xF2, 0xF3, 0x55),
    ZERO_G = string.char(0xAA, 0x03, 0x00, 0x0A, 0x00, 0x04, 0x01, 0x00, 0x10, 0x00, 0x00, 0xEA, 0xF3, 0x55),
    STOP = string.char(0xAA, 0x03, 0x00, 0x0A, 0x00, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, 0xFA, 0xF3, 0x55),
	MEM_A = string.char(0xAA, 0x03, 0x00, 0x0A, 0x00, 0x04, 0x01, 0x00, 0x20, 0x00, 0x00, 0xda, 0xF3, 0x55),
	MEM_B = string.char(0xAA, 0x03, 0x00, 0x0A, 0x00, 0x04, 0x01, 0x00, 0x40, 0x00, 0x00, 0xda, 0xF3, 0x55),
	LUMBAR_UP = string.char(0xAA, 0x03, 0x00, 0x0A, 0x00, 0x04, 0x01, 0x40, 0x00, 0x00, 0x00, 0xba, 0xF3, 0x55),
	LUMBAR_DOWN = string.char(0xAA, 0x03, 0x00, 0x0A, 0x00, 0x04, 0x01, 0x80, 0x00, 0x00, 0x00, 0x7a, 0xF3, 0x55),
	HEAD_UP = string.char(0xAA, 0x03, 0x00, 0x0A, 0x00, 0x04, 0x01, 0x01, 0x00, 0x00, 0x00, 0xf9, 0xF3, 0x55),
	HEAD_DOWN = string.char(0xAA, 0x03, 0x00, 0x0A, 0x00, 0x04, 0x01, 0x02, 0x00, 0x00, 0x00, 0xf8, 0xF3, 0x55),
	FOOT_UP = string.char(0xAA, 0x03, 0x00, 0x0A, 0x00, 0x04, 0x01, 0x04, 0x00, 0x00, 0x00, 0xf6, 0xF3, 0x55),
	FOOT_DOWN = string.char(0xAA, 0x03, 0x00, 0x0A, 0x00, 0x04, 0x01, 0x08, 0x00, 0x00, 0x00, 0xf2, 0xF3, 0x55),
	TIMER = string.char(0xAA, 0x03, 0x00, 0x0A, 0x00, 0x04, 0x01, 0x00, 0x02, 0x00, 0x00, 0xf8, 0xF3, 0x55),
	HEAD_MAS_UP = string.char(0xAA, 0x03, 0x00, 0x0A, 0x00, 0x04, 0x01, 0x00, 0x08, 0x00, 0x00, 0xf2, 0xF3, 0x55),
	HEAD_MAS_DOWN = string.char(0xAA, 0x03, 0x00, 0x0A, 0x00, 0x04, 0x01, 0x00, 0x00, 0x80, 0x00, 0x7a, 0xF3, 0x55),
	FOOT_MAS_UP = string.char(0xAA, 0x03, 0x00, 0x0A, 0x00, 0x04, 0x01, 0x00, 0x04, 0x00, 0x00, 0xf6, 0xF3, 0x55),
	FOOT_MAS_DOWN = string.char(0xAA, 0x03, 0x00, 0x0A, 0x00, 0x04, 0x01, 0x00, 0x00, 0x00, 0x01, 0xf9, 0xF3, 0x55),
	VIBRATION = string.char(0xAA, 0x03, 0x00, 0x0A, 0x00, 0x04, 0x01, 0x00, 0x01, 0x00, 0x00, 0xf9, 0xF3, 0x55),
}

-- 2. NETWORK LOGIC
local function send_command(device, hex_cmd)
  local ip = device.preferences.ipAddress
  if not ip or ip == "" or ip == "192.168.1.xxx" then
    log.warn(string.format("[%s] Skipping command: Please configure an IP in Settings.", device.label))
    return
  end

  local clean_ip = ip:gsub("%s+", "")
  log.info(string.format("[%s] Connecting to bed base at %s:5000", device.label, clean_ip))
  
  local sock = socket.tcp()
  sock:settimeout(2) 
  
  local success, err = sock:connect(clean_ip, 5000)
  if success then
    sock:send(hex_cmd)
    sock:close() -- Fire and forget execution
    log.info(string.format("[%s] Command sent successfully.", device.label))
  else
    log.error(string.format("[%s] Connection failed: %s", device.label, tostring(err)))
  end
end

-- 3. INTERACTION HANDLER
local function handle_push(driver, device, command)
  log.info(string.format("[%s] Button pressed on component: %s", device.label, command.component))
  
  if command.component == "main" then
    send_command(device, commands.FLAT)
  elseif command.component == "zeroG" then
    send_command(device, commands.ZERO_G)
  elseif command.component == "stop" then
    send_command(device, commands.STOP)
  elseif command.component == "mema" then
    send_command(device, commands.MEM_A)
  elseif command.component == "memb" then
    send_command(device, commands.MEM_B)
  elseif command.component == "lumbarup" then
    send_command(device, commands.LUMBAR_UP)
  elseif command.component == "lumbardown" then
    send_command(device, commands.LUMBAR_DOWN)
  elseif command.component == "headup" then
    send_command(device, commands.HEAD_UP)
  elseif command.component == "headdown" then
    send_command(device, commands.HEAD_DOWN)
  elseif command.component == "footup" then
    send_command(device, commands.FOOT_UP)
  elseif command.component == "footdown" then
    send_command(device, commands.FOOT_DOWN)
  elseif command.component == "headmasup" then
    send_command(device, commands.HEAD_MAS_UP)
  elseif command.component == "headmasdown" then
    send_command(device, commands.HEAD_MAS_DOWN)
  elseif command.component == "footmasup" then
    send_command(device, commands.FOOT_MAS_UP)
  elseif command.component == "footmasdown" then
    send_command(device, commands.FOOT_MAS_DOWN)
  elseif command.component == "timer" then
    send_command(device, commands.TIMER)
  elseif command.component == "vibration" then
    send_command(device, commands.VIBRATION)
  end
end

-- 4. DISCOVERY HANDLER (Mirrors the exact Awair pattern)
local function discovery_handler(driver, opts, cons)
  local unique_id = tostring(socket.gettime()):gsub("%.", ""):sub(-6)
  local generated_dni = "ergomotion_instance_" .. unique_id
  local generated_label = "Ergomotion Bed " .. unique_id

  log.info(string.format("Spawning Ergomotion Tile Instance. DNI: %s | Label: %s", generated_dni, generated_label))
  
  local default_device_msg = {
    type = "LAN",
    device_network_id = generated_dni, 
    label = generated_label,
    profile = PROFILE_NAME, 
    manufacturer = "Ergomotion",
    model = "AdjustableBase"
  }
  
  driver:try_create_device(default_device_msg)
end

-- 5. LIFECYCLE HOOKS
local function info_changed(driver, device, event, args)
  log.info(string.format("[%s] Settings update noticed.", device.label))
end

local function device_init(driver, device)
  log.info(string.format("Attaching Ergomotion core handle for: %s", device.label))
end

local function device_removed(driver, device)
  log.info(string.format("Removing device instance: %s", device.label))
end

-- 6. DRIVER INSTANTIATION
local ergomotion_driver = Driver("ergomotion_driver", {
  --discovery = discovery_handler,
  capability_handlers = {
    [capabilities.momentary.ID] = {
      -- This inner command key table matches the Awair script framework logic
      push = handle_push 
    }
  },
  lifecycle_handlers = {
    init = device_init,
    infoChanged = info_changed,
    removed = device_removed
  }
})

ergomotion_driver:run()