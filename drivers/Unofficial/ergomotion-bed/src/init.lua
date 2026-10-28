local Driver = require("st.driver")
local log = require("log")
local cosock = require("cosock")
local socket = require("cosock.socket")
local capabilities = require("st.capabilities")

-- Base configuration
local PROFILE_NAME = "ergomotion-bed"
local PORT = 5000
local RX_WAIT_S = 0.13          -- wait for a status reply after each frame (also paces repeats)
local MAX_MOVE_S = 50           -- safety cutoff for any movement loop (head full travel is ~45-50 s)
local OVERRUN = 1.15            -- when driving to 100%, stop at this multiple of the learned max
local STALL_S = 1.0             -- no position change for this long = end of travel
local DEFAULT_MAX = { head = 4000, foot = 4000 } -- used until the real maximum is learned
local EMIT_INTERVAL_S = 1.0     -- throttle slider updates while moving

-- 1. COMMANDS (4 button bytes; frames are built with checksums by build_frame)
local BTN = {
  STOP          = { 0x00, 0x00, 0x00, 0x00 },
  HEAD_UP       = { 0x01, 0x00, 0x00, 0x00 },
  HEAD_DOWN     = { 0x02, 0x00, 0x00, 0x00 },
  FOOT_UP       = { 0x04, 0x00, 0x00, 0x00 },
  FOOT_DOWN     = { 0x08, 0x00, 0x00, 0x00 },
  LUMBAR_UP     = { 0x40, 0x00, 0x00, 0x00 },
  LUMBAR_DOWN   = { 0x80, 0x00, 0x00, 0x00 },
  VIBRATION     = { 0x00, 0x01, 0x00, 0x00 },
  TIMER         = { 0x00, 0x02, 0x00, 0x00 },
  FOOT_MAS_UP   = { 0x00, 0x04, 0x00, 0x00 },
  HEAD_MAS_UP   = { 0x00, 0x08, 0x00, 0x00 },
  ZERO_G        = { 0x00, 0x10, 0x00, 0x00 },
  MEM_A         = { 0x00, 0x20, 0x00, 0x00 },
  MEM_B         = { 0x00, 0x40, 0x00, 0x00 },
  HEAD_MAS_DOWN = { 0x00, 0x00, 0x80, 0x00 },
  FLAT          = { 0x00, 0x00, 0x00, 0x08 },
  FOOT_MAS_DOWN = { 0x00, 0x00, 0x00, 0x01 },
}

-- Frame: AA 03 00 0A 00 | 04 01 b1 b2 b3 b4 crc | outer_crc 55
-- crc       = ~(sum of 04 01 b1..b4)        & 0xFF
-- outer_crc = ~(sum of bytes after AA, before outer_crc) & 0xFF
local function build_frame(btn)
  local bytes = { 0xAA, 0x03, 0x00, 0x0A, 0x00, 0x04, 0x01, btn[1], btn[2], btn[3], btn[4] }
  local s = 0
  for i = 6, 11 do s = s + bytes[i] end
  bytes[12] = (~s) & 0xFF
  s = 0
  for i = 2, 12 do s = s + bytes[i] end
  bytes[13] = (~s) & 0xFF
  bytes[14] = 0x55
  return string.char(table.unpack(bytes))
end

local FRAMES = {}
for name, btn in pairs(BTN) do FRAMES[name] = build_frame(btn) end

-- Momentary tiles: component -> { command, kind }
--   (head/foot/lumbar movement is done with the position sliders)
--   kind "preset" = single press, bed moves on its own; position read after it settles
--   kind "tap"    = single press (massage/timer etc.)
local BUTTONS = {
  main        = { "FLAT", "preset" },
  zeroG       = { "ZERO_G", "preset" },
  mema        = { "MEM_A", "preset" },
  memb        = { "MEM_B", "preset" },
  stop        = { "STOP", "stop" },
}

-- Massage intensity is reported as 0/1/3/6; the dropdowns use Off/Low/Medium/High.
local MASSAGE_MODES = { "Off", "Low", "Medium", "High" }
local TIMER_MODES = { "Off", "10 min", "20 min", "30 min" }
local MASSAGE = {
  headMassage = { field = "head_mas", up = "HEAD_MAS_UP", down = "HEAD_MAS_DOWN" },
  footMassage = { field = "foot_mas", up = "FOOT_MAS_UP", down = "FOOT_MAS_DOWN" },
}

-- Vibration pattern (raw 1-4, cycles on each press) <-> fan slider step.
-- raw 2/3/4 = pulses slow -> fast, raw 1 = continuous (bed default). No "off" exists.
local WAVE_TO_SPEED = { [2] = 1, [3] = 2, [4] = 3, [1] = 4 }
local SPEED_TO_WAVE = { [0] = 1, [1] = 2, [2] = 3, [3] = 4, [4] = 1 }

local function mas_index(raw)
  if raw <= 0 then return 0 elseif raw <= 2 then return 1 elseif raw <= 4 then return 2 else return 3 end
end

local function index_of(list, value)
  for i, v in ipairs(list) do if v == value then return i - 1 end end
  return nil
end

local PARTS = {
  head = { up = "HEAD_UP", down = "HEAD_DOWN" },
  foot = { up = "FOOT_UP", down = "FOOT_DOWN" },
}

-- 2. STATUS PARSING
-- Reply: AA 83 00 17 xx | 0C 01 [head lo hi] [foot lo hi] ... crc | 00.. outer_crc 55  (27 bytes)
local function hex(s)
  return (s:gsub(".", function(c) return string.format("%02X ", c:byte()) end))
end

local function parse_frames(conn)
  local latest
  while true do
    local start = conn.buf:find("\xAA\x83", 1, true)
    if not start then
      conn.buf = conn.buf:sub(-1) -- keep a possible half header
      break
    end
    if #conn.buf < start + 3 then conn.buf = conn.buf:sub(start); break end
    local flen = conn.buf:byte(start + 3) + 4
    if #conn.buf < start + flen - 1 then conn.buf = conn.buf:sub(start); break end
    local f = conn.buf:sub(start, start + flen - 1)
    conn.buf = conn.buf:sub(start + flen)

    -- outer checksum + terminator
    local s = 0
    for i = 2, flen - 2 do s = s + f:byte(i) end
    if f:byte(flen) == 0x55 and ((~s) & 0xFF) == f:byte(flen - 1) and flen >= 13 then
      -- f:byte(k+1) is byte index k from the logs (0-based)
      latest = {
        head = f:byte(8) | (f:byte(9) << 8),
        foot = f:byte(10) | (f:byte(11) << 8),
        wave = f:byte(12) >> 4,                                         -- byte 11 high nibble: vibration pattern 1-4
        head_mas = f:byte(12) & 0x0F,                                   -- byte 11 low nibble: 0/1/3/6
        foot_mas = f:byte(13),                                          -- byte 12: 0/1/3/6
        remaining = f:byte(14) | (f:byte(15) << 8) | (f:byte(16) << 16), -- bytes 13-15, 1/100 s
        timer = f:byte(19),                                             -- byte 18: 1/2/3 = 10/20/30 min
        raw = f,
      }
    else
      log.debug("Ignoring bad frame: " .. hex(f))
    end
  end
  return latest
end

-- 3. NETWORK LOGIC
local function get_ip(device)
  local ip = device.preferences.ipAddress
  if not ip or ip == "" or ip == "192.168.1.xxx" then return nil end
  return (ip:gsub("%s+", ""))
end

local function open_conn(device)
  local ip = get_ip(device)
  if not ip then
    log.warn(string.format("[%s] Skipping: please configure an IP in Settings.", device.label))
    return nil
  end
  local sock = socket.tcp()
  sock:settimeout(2)
  local ok, err = sock:connect(ip, PORT)
  if not ok then
    log.error(string.format("[%s] Connection to %s:%d failed: %s", device.label, ip, PORT, tostring(err)))
    sock:close()
    return nil
  end
  sock:settimeout(RX_WAIT_S)
  return { sock = sock, buf = "" }
end

-- Send one frame and collect whatever status arrives within RX_WAIT_S.
local function exchange(conn, frame_name)
  local ok, err = conn.sock:send(FRAMES[frame_name])
  if not ok then
    conn.closed = true
    log.error("Send failed: " .. tostring(err))
    return nil
  end
  local data, rerr, partial = conn.sock:receive(256)
  local chunk = data or partial
  if chunk and #chunk > 0 then conn.buf = conn.buf .. chunk end
  if rerr == "closed" then conn.closed = true end
  return parse_frames(conn)
end

-- 4. POSITION STATE
local function get_max(device, part)
  local pref = tonumber(device.preferences[part .. "Max"]) or 0
  if pref > 0 then return pref end
  return device:get_field(part .. "_max") or DEFAULT_MAX[part]
end

local function learn_max(device, part, pos, force)
  local pref = tonumber(device.preferences[part .. "Max"]) or 0
  if pref > 0 or pos <= 0 then return end
  local current = device:get_field(part .. "_max") or DEFAULT_MAX[part]
  if force or pos > current then
    log.info(string.format("[%s] Learned %s max travel: %d (was %d)", device.label, part, pos, current))
    device:set_field(part .. "_max", pos, { persist = true })
  end
end

local function emit_level(device, part, level, force)
  level = math.max(0, math.min(100, math.floor(level + 0.5)))
  local now = socket.gettime()
  local last = device:get_field(part .. "_level")
  local last_t = device:get_field(part .. "_emit_t") or 0
  if force or (level ~= last and now - last_t >= EMIT_INTERVAL_S) then
    device:emit_component_event(device.profile.components[part], capabilities.switchLevel.level(level))
    device:set_field(part .. "_level", level)
    device:set_field(part .. "_emit_t", now)
  end
end

local function report(device, st, force)
  if not st then return end
  for part, _ in pairs(PARTS) do
    local pos = st[part]
    if pos > get_max(device, part) then learn_max(device, part, pos) end
    emit_level(device, part, pos * 100 / get_max(device, part), force)
  end
  -- lumbar is not in the status frame; republish the estimate on every full report
  if force then emit_level(device, "lumbar", device:get_field("lumbar_pos") or 0, true) end

  -- massage + timer
  local function emit_mode(comp, value)
    if force or device:get_field(comp .. "_mode") ~= value then
      device:emit_component_event(device.profile.components[comp], capabilities.mode.mode(value))
      device:set_field(comp .. "_mode", value)
    end
  end
  local running = st.head_mas > 0 or st.foot_mas > 0
  for comp, m in pairs(MASSAGE) do
    local speed = mas_index(st[m.field])
    if force or device:get_field(comp .. "_speed") ~= speed then
      device:emit_component_event(device.profile.components[comp], capabilities.fanSpeed.fanSpeed(speed))
      device:set_field(comp .. "_speed", speed)
    end
  end
  local vib = WAVE_TO_SPEED[st.wave]
  if vib and (force or device:get_field("vibration_speed") ~= vib) then
    device:emit_component_event(device.profile.components.vibration, capabilities.fanSpeed.fanSpeed(vib))
    device:set_field("vibration_speed", vib)
  end
  emit_mode("massageTimer", running and (TIMER_MODES[st.timer + 1] or "Off") or "Off")
  device:set_field("massage_on", running)

  log.debug(string.format("[%s] head=%d foot=%d headMas=%d footMas=%d timer=%d remaining=%ds",
    device.label, st.head, st.foot, st.head_mas, st.foot_mas, st.timer, st.remaining // 100))
end

-- 5. OPERATION RUNNER
-- Only one operation runs at a time; starting a new one cancels the old one.
local function run_op(device, name, fn)
  local id = (device:get_field("op_id") or 0) + 1
  device:set_field("op_id", id)
  cosock.spawn(function()
    -- let a cancelled operation close its socket first
    local waited = 0
    while device:get_field("op_busy") and waited < 2 do socket.sleep(0.05); waited = waited + 0.05 end
    if device:get_field("op_id") ~= id then return end

    device:set_field("op_busy", true)
    local conn = open_conn(device)
    if conn then
      local function cancelled() return conn.closed or device:get_field("op_id") ~= id end
      local ok, err = pcall(fn, conn, cancelled)
      if not ok then log.error(string.format("[%s] %s failed: %s", device.label, name, tostring(err))) end
      conn.sock:close()
    end
    device:set_field("op_busy", false)
  end, "ergomotion-" .. name)
end

-- STOP, give the motors a moment to coast, then read the final position.
local function stop_and_settle(device, conn)
  exchange(conn, "STOP")
  socket.sleep(0.6)
  local st = exchange(conn, "STOP") or exchange(conn, "STOP")
  report(device, st, true)
end

-- Lumbar: the bed reports no lumbar position, so it is estimated from motor run time.
-- 0% / 100% drive a little past full travel to re-sync the estimate.
local function move_lumbar(device, conn, cancelled, target_pct)
  local travel = tonumber(device.preferences.lumbarSeconds) or 15
  local cur = device:get_field("lumbar_pos")
  local unknown = (cur == nil)
  if unknown then cur = 100 end -- treat as top so a move down covers full travel

  local function run(frame_name, secs, from, dir)
    local start = socket.gettime()
    local pos = from
    while not cancelled() do
      local el = socket.gettime() - start
      if el >= secs then break end
      report(device, exchange(conn, frame_name))
      pos = math.max(0, math.min(100, from + dir * (el / travel) * 100))
      emit_level(device, "lumbar", pos)
    end
    local el = socket.gettime() - start
    pos = math.max(0, math.min(100, from + dir * (math.min(el, secs) / travel) * 100))
    device:set_field("lumbar_pos", pos, { persist = true })
    return pos
  end

  if unknown and target_pct > 0 then
    -- re-sync at the bottom first
    log.info(string.format("[%s] Lumbar position unknown; lowering fully first", device.label))
    run("LUMBAR_DOWN", travel + 2, 100, -1)
    if cancelled() then stop_and_settle(device, conn); return end
    cur = 0
    device:set_field("lumbar_pos", 0, { persist = true })
  end

  local pos
  if target_pct == 0 or target_pct == 100 then
    local dir = target_pct == 100 and 1 or -1
    local secs = math.abs(target_pct - cur) / 100 * travel + 2
    pos = run(dir > 0 and "LUMBAR_UP" or "LUMBAR_DOWN", secs, cur, dir)
    if not cancelled() then pos = target_pct; device:set_field("lumbar_pos", pos, { persist = true }) end
  else
    local delta = target_pct - cur
    if math.abs(delta) < 1 then return end
    local dir = delta > 0 and 1 or -1
    pos = run(dir > 0 and "LUMBAR_UP" or "LUMBAR_DOWN", math.abs(delta) / 100 * travel, cur, dir)
  end
  if not conn.closed then stop_and_settle(device, conn) end
  emit_level(device, "lumbar", pos, true)
  log.info(string.format("[%s] Lumbar estimated at %d%%", device.label, math.floor(pos + 0.5)))
end

-- Drive head or foot to a target percentage.
local function move_to(device, conn, cancelled, part, target_pct)
  local st = exchange(conn, "STOP") or exchange(conn, "STOP")
  if not st then
    log.warn(string.format("[%s] No status from bed; cannot move %s to %d%%", device.label, part, target_pct))
    return
  end
  report(device, st, true)

  local max = get_max(device, part)
  local target = target_pct * max / 100
  local pos = st[part]
  if math.abs(target - pos) <= max * 0.01 and target_pct > 0 and target_pct < 100 then return end
  if target_pct == 0 and pos == 0 then return end

  local dir = (target > pos or target_pct == 100) and 1 or -1
  local frame_name = dir > 0 and PARTS[part].up or PARTS[part].down
  local to_end = (target_pct == 0 or target_pct == 100) -- drive to the stop; recalibrates max/zero
  local start, last_pos, speed, stall_t = socket.gettime(), pos, 0, nil

  log.info(string.format("[%s] Moving %s %s: %d -> %d (max %d)", device.label, part,
    dir > 0 and "up" or "down", pos, math.floor(target), max))

  while not cancelled() do
    local now = socket.gettime()
    if now - start > MAX_MOVE_S then log.warn("Move timed out"); break end
    local s = exchange(conn, frame_name)
    if s then
      pos = s[part]
      local d = math.abs(pos - last_pos)
      if d > 0 then speed, stall_t = d, nil else stall_t = stall_t or now end
      last_pos = pos
      report(device, s)

      -- stop early: the bed coasts ~1.5-2 status frames after STOP
      local lead = speed * 1.7
      if not to_end and ((dir > 0 and pos + lead >= target) or (dir < 0 and pos - lead <= target)) then
        break
      end
      -- driving to 100%: don't run forever if the counter keeps climbing past the top
      if to_end and dir > 0 and device:get_field(part .. "_max") and pos >= max * OVERRUN then
        learn_max(device, part, pos, true)
        break
      end
      -- end of travel: position stopped changing after the motor got going
      if stall_t and now - stall_t >= STALL_S and now - start > 1.5 then
        if dir > 0 then learn_max(device, part, pos, true) end
        break
      end
    end
  end
  if not conn.closed then stop_and_settle(device, conn) end
end

-- Massage / timer: press a button once, then poll (all-zero frames do not stop massage)
-- until the status changes or ~1.5 s passes.
local function read_status(conn)
  return exchange(conn, "STOP") or exchange(conn, "STOP") or exchange(conn, "STOP")
end

local function tap_and_wait(device, conn, frame_name, before)
  local st = exchange(conn, frame_name) or before
  local start = socket.gettime()
  while socket.gettime() - start < 1.5 do
    local s = exchange(conn, "STOP")
    if s then
      st = s
      if before and (s.head_mas ~= before.head_mas or s.foot_mas ~= before.foot_mas or s.timer ~= before.timer or s.wave ~= before.wave) then
        break
      end
    end
  end
  report(device, st, true)
  return st
end

local function set_massage(device, conn, cancelled, comp, target)
  local m = MASSAGE[comp]
  local st = read_status(conn)
  if not st then log.warn("No status from bed"); return end
  for _ = 1, 6 do
    if cancelled() then return end
    local cur = mas_index(st[m.field])
    if cur == target then break end
    st = tap_and_wait(device, conn, cur < target and m.up or m.down, st)
  end
  report(device, st, true)
end

local function set_vibration(device, conn, cancelled, target_wave)
  local st = read_status(conn)
  if not st then log.warn("No status from bed"); return end
  for _ = 1, 5 do
    if st.wave == target_wave or cancelled() then break end
    st = tap_and_wait(device, conn, "VIBRATION", st)
  end
  report(device, st, true)
end

local function set_timer(device, conn, cancelled, target)
  local st = read_status(conn)
  if not st then log.warn("No status from bed"); return end
  local head, foot = mas_index(st.head_mas), mas_index(st.foot_mas)
  local running = head > 0 or foot > 0

  -- Timer/All Off: the first press while massage runs turns everything off
  if running then st = tap_and_wait(device, conn, "TIMER", st) end
  if target == 0 or cancelled() then return end

  -- with massage off, each press cycles 10 -> 20 -> 30 min
  for _ = 1, 4 do
    if st.timer == target or cancelled() then break end
    st = tap_and_wait(device, conn, "TIMER", st)
  end

  -- restart the massage that was running (or say nothing if it was off)
  if running then
    for _ = 1, head do if cancelled() then return end; st = tap_and_wait(device, conn, "HEAD_MAS_UP", st) end
    for _ = 1, foot do if cancelled() then return end; st = tap_and_wait(device, conn, "FOOT_MAS_UP", st) end
  end
  report(device, st, true)
end

-- 6. CAPABILITY HANDLERS
-- Massage intensity as a fan-speed slider: 0 Off, 1 Low, 2 Medium, 3 High (4 is treated as High)
local function handle_set_fan_speed(driver, device, command)
  local comp = command.component
  if comp == "vibration" then
    local speed = math.max(0, math.min(4, math.floor(tonumber(command.args.speed) or 0)))
    log.info(string.format("[%s] Set vibration pattern to step %d", device.label, speed))
    device:set_field("vibration_speed", nil) -- force the real pattern to be re-emitted
    run_op(device, "vibration", function(conn, cancelled)
      set_vibration(device, conn, cancelled, SPEED_TO_WAVE[speed])
    end)
    return
  end
  if not MASSAGE[comp] then return end
  local target = math.max(0, math.min(3, math.floor(tonumber(command.args.speed) or 0)))
  log.info(string.format("[%s] Set %s to %s", device.label, comp, MASSAGE_MODES[target + 1]))
  device:set_field(comp .. "_speed", nil) -- force the real level to be re-emitted
  run_op(device, "massage-" .. comp, function(conn, cancelled)
    set_massage(device, conn, cancelled, comp, target)
  end)
end

local function handle_set_mode(driver, device, command)
  local comp, value = command.component, command.args.mode
  log.info(string.format("[%s] Set %s to %s", device.label, comp, tostring(value)))
  if comp == "massageTimer" then
    local target = index_of(TIMER_MODES, value)
    if not target then return end
    run_op(device, "timer", function(conn, cancelled)
      set_timer(device, conn, cancelled, target)
    end)
  end
end

local function handle_push(driver, device, command)
  local entry = BUTTONS[command.component]
  if not entry then return end
  local frame_name, kind = entry[1], entry[2]
  log.info(string.format("[%s] %s pressed (%s)", device.label, command.component, frame_name))

  if kind == "stop" then
    run_op(device, "stop", function(conn) stop_and_settle(device, conn) end)
  elseif kind == "preset" then
    local settle = tonumber(device.preferences.presetSeconds) or 25
    run_op(device, frame_name, function(conn, cancelled)
      report(device, exchange(conn, frame_name))
      -- Polling sends STOP, which would interrupt the preset, so wait for it to finish first.
      local start = socket.gettime()
      while not cancelled() and socket.gettime() - start < settle do socket.sleep(0.25) end
      if not cancelled() then
        report(device, exchange(conn, "STOP") or exchange(conn, "STOP"), true)
      end
    end)
  else -- tap
    run_op(device, frame_name, function(conn)
      report(device, exchange(conn, frame_name))
    end)
  end
end

local function handle_set_level(driver, device, command)
  local part = command.component
  if part == "lumbar" then
    local level = math.max(0, math.min(100, math.floor(command.args.level)))
    log.info(string.format("[%s] Set lumbar to %d%%", device.label, level))
    emit_level(device, "lumbar", level, true)
    run_op(device, "move-lumbar", function(conn, cancelled)
      move_lumbar(device, conn, cancelled, level)
    end)
    return
  end
  if not PARTS[part] then return end
  local level = math.max(0, math.min(100, math.floor(command.args.level)))
  log.info(string.format("[%s] Set %s to %d%%", device.label, part, level))
  -- reflect the request immediately; the real position is reported as the bed moves
  device:emit_component_event(device.profile.components[part], capabilities.switchLevel.level(level))
  device:set_field(part .. "_level", level)
  run_op(device, "move-" .. part, function(conn, cancelled)
    move_to(device, conn, cancelled, part, level)
  end)
end

local function poll(device)
  run_op(device, "refresh", function(conn)
    report(device, exchange(conn, "STOP") or exchange(conn, "STOP"), true)
  end)
end

local function handle_refresh(driver, device, command)
  poll(device)
end

-- 7. DISCOVERY HANDLER (Mirrors the exact Awair pattern)
local function discovery_handler(driver, opts, cons)
  local unique_id = tostring(socket.gettime()):gsub("%.", ""):sub(-6)
  local generated_dni = "ergomotion_instance_" .. unique_id
  local generated_label = "Ergomotion Bed " .. unique_id

  log.info(string.format("Spawning Ergomotion Tile Instance. DNI: %s | Label: %s", generated_dni, generated_label))

  driver:try_create_device({
    type = "LAN",
    device_network_id = generated_dni,
    label = generated_label,
    profile = PROFILE_NAME,
    manufacturer = "Ergomotion",
    model = "AdjustableBase"
  })
end

-- 8. LIFECYCLE HOOKS
local function info_changed(driver, device, event, args)
  log.info(string.format("[%s] Settings update noticed.", device.label))
  local old = args and args.old_st_store and args.old_st_store.preferences or {}
  if old.ipAddress ~= device.preferences.ipAddress
    or old.headMax ~= device.preferences.headMax
    or old.footMax ~= device.preferences.footMax then
    poll(device)
  end
end

local function device_init(driver, device)
  log.info(string.format("Attaching Ergomotion core handle for: %s", device.label))
  device:set_field("op_busy", false)
  -- The bed never reports lumbar, so always publish a value or the app disables the slider.
  -- If the position has never been tracked, show 0%; the first move re-syncs by lowering fully.
  device:set_field("lumbar_level", nil)
  emit_level(device, "lumbar", device:get_field("lumbar_pos") or 0, true)
  device:emit_component_event(device.profile.components.massageTimer, capabilities.mode.supportedModes(TIMER_MODES))
  -- the bed only reports status when asked, so check every minute while a massage is running
  device.thread:call_on_schedule(60, function()
    if device:get_field("massage_on") and not device:get_field("op_busy") then poll(device) end
  end, "massage-poll")
  poll(device)
end

local function device_removed(driver, device)
  log.info(string.format("Removing device instance: %s", device.label))
  device:set_field("op_id", (device:get_field("op_id") or 0) + 1) -- cancel anything running
end

-- 9. DRIVER INSTANTIATION
local ergomotion_driver = Driver("ergomotion_driver", {
  --discovery = discovery_handler,
  capability_handlers = {
    [capabilities.momentary.ID] = {
      [capabilities.momentary.commands.push.NAME] = handle_push,
    },
    [capabilities.switchLevel.ID] = {
      [capabilities.switchLevel.commands.setLevel.NAME] = handle_set_level,
    },
    [capabilities.fanSpeed.ID] = {
      [capabilities.fanSpeed.commands.setFanSpeed.NAME] = handle_set_fan_speed,
    },
    [capabilities.mode.ID] = {
      [capabilities.mode.commands.setMode.NAME] = handle_set_mode,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
    },
  },
  lifecycle_handlers = {
    init = device_init,
    infoChanged = info_changed,
    removed = device_removed
  }
})

ergomotion_driver:run()
