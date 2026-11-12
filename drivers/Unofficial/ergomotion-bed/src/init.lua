local Driver = require("st.driver")
local log = require("log")
local cosock = require("cosock")
local socket = require("cosock.socket")
local capabilities = require("st.capabilities")

-- Look up a capability without failing if the hub has no definition for it
-- (motionBed and the proposed massage capabilities may not exist on every hub).
local function cap(id)
  local ok, c = pcall(function() return capabilities[id] end)
  if ok then return c end
  return nil
end

-- Base configuration
local PROFILE_NAME = "ergomotion-bed"
local PORT = 5000
local RX_WAIT_S = 0.13          -- wait for a status reply after each frame (also paces repeats)
local MAX_MOVE_S = 50           -- safety cutoff for any movement loop (head full travel is ~45-50 s)
local OVERRUN = 1.15            -- when driving to 100%, stop at this multiple of the learned max
local STALL_S = 1.0             -- no position change for this long = end of travel
local DEFAULT_MAX = { head = 4000, foot = 4000 } -- used until the real maximum is learned
local EMIT_INTERVAL_S = 1.0     -- throttle slider updates while moving
local HEALTH_TICK_S = 60        -- health timer tick
local HEALTH_INTERVAL_S = 300   -- check connectivity this often while online (any real command also counts)
local HEALTH_FAILS = 2          -- consecutive failed connections before marking offline
local PRESET_TOL = 0.03         -- position match tolerance for preset modes (fraction of max travel)

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

-- motionBed capability mapping
local MB_MODES = { "preset1", "preset2", "zeroG", "flat" }
local MB_MODE_FRAME = { preset1 = "MEM_A", preset2 = "MEM_B", zeroG = "ZERO_G", flat = "FLAT" }
local MB_MATCH_ORDER = { "flat", "zeroG", "preset1", "preset2" }
local MB_POSITIONS = { "headUp", "headDown", "footUp", "footDown", "elevationUp", "elevationDown" }
-- position -> { frame, part (nil = lumbar), direction }
local MB_MOVES = {
  headUp        = { "HEAD_UP", "head", 1 },
  headDown      = { "HEAD_DOWN", "head", -1 },
  footUp        = { "FOOT_UP", "foot", 1 },
  footDown      = { "FOOT_DOWN", "foot", -1 },
  elevationUp   = { "LUMBAR_UP", nil, 1 },   -- elevation is used for the lumbar motor
  elevationDown = { "LUMBAR_DOWN", nil, -1 },
}
-- which learned presets each "Relearn preset position" setting clears
local RELEARN = { memA = { "preset1" }, memB = { "preset2" }, zeroG = { "zeroG" }, all = { "preset1", "preset2", "zeroG" } }

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

-- HEALTH: switch on main = bed reachable on the network; device is marked offline after
-- HEALTH_FAILS failed connections in a row (immediately if it was never seen online).
local function emit_switch(device)
  local on = device:get_field("online") == true
  device:emit_component_event(device.profile.components.main,
    on and capabilities.switch.switch.on() or capabilities.switch.switch.off())
end

local function set_online(device, ok)
  local was = device:get_field("online")
  if ok then
    device:set_field("fail_count", 0)
    device:set_field("last_ok", socket.gettime())
    if was ~= true then
      log.info(string.format("[%s] Bed is online", device.label))
      device:online()
      device:set_field("online", true)
      emit_switch(device)
    end
  else
    local n = (device:get_field("fail_count") or 0) + 1
    device:set_field("fail_count", n)
    if was == false or (was == true and n < HEALTH_FAILS) then return end
    log.warn(string.format("[%s] Bed is offline (%d failed connection%s)", device.label, n, n == 1 and "" or "s"))
    device:set_field("online", false)
    emit_switch(device)
    device:offline()
  end
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
    set_online(device, false)
    return nil
  end
  set_online(device, true)
  sock:settimeout(RX_WAIT_S)
  return { sock = sock, buf = "" }
end

-- Connect and close without sending anything (does not disturb the bed).
local function health_check(device)
  if device:get_field("op_busy") or not get_ip(device) then return end
  local sock = socket.tcp()
  sock:settimeout(3)
  local ok, err = sock:connect(get_ip(device), PORT)
  sock:close()
  if not ok then log.debug(string.format("[%s] Health check failed: %s", device.label, tostring(err))) end
  set_online(device, ok and true or false)
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

-- PRESET MODES: learned head/foot position for each motionBed mode (flat is always 0/0)
local function get_preset(device, mode)
  if mode == "flat" then return { head = 0, foot = 0 } end
  return device:get_field("preset_" .. mode)
end

local function learn_preset(device, mode, st)
  if mode == "flat" or not st or get_preset(device, mode) then return end
  device:set_field("preset_" .. mode, { head = st.head, foot = st.foot }, { persist = true })
  log.info(string.format("[%s] Learned %s position: head=%d foot=%d", device.label, mode, st.head, st.foot))
end

local function match_mode(device, st)
  local tol_h = math.max(150, get_max(device, "head") * PRESET_TOL)
  local tol_f = math.max(150, get_max(device, "foot") * PRESET_TOL)
  for _, mode in ipairs(MB_MATCH_ORDER) do
    local p = get_preset(device, mode)
    if p and math.abs(st.head - p.head) <= tol_h and math.abs(st.foot - p.foot) <= tol_f then return mode end
  end
  return "noMode"
end

local function emit_bed_mode(device, mode, force)
  local mb = cap("motionBed")
  if not mb then return end
  if force or device:get_field("bed_mode") ~= mode then
    device:emit_component_event(device.profile.components.main, mb.mode(mode))
    device:set_field("bed_mode", mode)
  end
end

-- MASSAGE CAPABILITIES (proposed): massageIntensityControl, massageIntensityChange,
-- massageOperating, massageOperatingState, massageTimeChange, massageTimeControl on main.
local MASSAGE_POSITIONS = { "head", "foot", "whole" }
local MASSAGE_SET_TIMES = { 0, 10, 20, 30 }

local function iso_utc(epoch)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(epoch))
end

local function emit_main(device, capability, event_fn, value, field, force)
  if not capability then return end
  if force or device:get_field(field) ~= value then
    device:emit_component_event(device.profile.components.main, event_fn(value))
    device:set_field(field, value)
  end
end

local function report_massage(device, st, force)
  local head, foot = mas_index(st.head_mas), mas_index(st.foot_mas)
  local running = head > 0 or foot > 0
  if running then device:set_field("last_mas", { head = head, foot = foot }, { persist = true }) end

  local mic = cap("massageIntensityControl")
  if mic then
    emit_main(device, mic, mic.intensityHead, head, "mic_head", force)
    emit_main(device, mic, mic.intensityFoot, foot, "mic_foot", force)
    emit_main(device, mic, mic.intensityWhole, math.max(head, foot), "mic_whole", force)
  end
  local state = running and "on" or "off"
  local mo, mos = cap("massageOperating"), cap("massageOperatingState")
  if mo then emit_main(device, mo, mo.massageState, state, "mo_state", force) end
  if mos then emit_main(device, mos, mos.massageState, state, "mos_state", force) end

  local mtc = cap("massageTimeControl")
  if mtc then
    local now = os.time()
    local last = device:get_field("mtc_epoch")
    local target
    if running then
      target = now + st.remaining // 100
    elseif last == nil or last > now then
      target = now -- stopped (or never ran): completion is now
    else
      target = last
    end
    if force or last == nil or math.abs(target - last) > 5 then
      device:emit_component_event(device.profile.components.main, mtc.completionTime(iso_utc(target)))
      device:set_field("mtc_epoch", target)
    end
  end
end

-- Attributes that never change (supported lists/ranges). Sent at startup and on every full
-- report, so a profile update picked up later (or a dropped event) is filled in by a refresh.
local function emit_static(device)
  local main = device.profile.components.main
  local mb = cap("motionBed")
  if mb then
    device:emit_component_event(main, mb.supportedModes(MB_MODES))
    device:emit_component_event(main, mb.supportedMotionPositions(MB_POSITIONS))
    device:emit_component_event(main, mb.statelessMode(false))
  end
  local mic, mich, mtc = cap("massageIntensityControl"), cap("massageIntensityChange"), cap("massageTimeControl")
  if mic then
    device:emit_component_event(main, mic.intensityRange({ minimum = 0, maximum = 3, step = 1 }))
    device:emit_component_event(main, mic.supportedPositions(MASSAGE_POSITIONS))
  end
  if mich then device:emit_component_event(main, mich.supportedPositions(MASSAGE_POSITIONS)) end
  if mtc then device:emit_component_event(main, mtc.supportedSetTimes(MASSAGE_SET_TIMES)) end
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

  -- massage (intensity/timer are reported by the massage capabilities on main)
  local running = st.head_mas > 0 or st.foot_mas > 0
  local vib = WAVE_TO_SPEED[st.wave]
  if vib and (force or device:get_field("vibration_speed") ~= vib) then
    device:emit_component_event(device.profile.components.vibration, capabilities.fanSpeed.fanSpeed(vib))
    device:set_field("vibration_speed", vib)
  end
  device:set_field("massage_on", running)
  if not device:get_field("preset_pending") then emit_bed_mode(device, match_mode(device, st), force) end
  report_massage(device, st, force)

  log.debug(string.format("[%s] head=%d foot=%d headMas=%d footMas=%d timer=%d remaining=%ds",
    device.label, st.head, st.foot, st.head_mas, st.foot_mas, st.timer, st.remaining // 100))
end

-- 5. OPERATION RUNNER
local MB_PRESET_OPS = { MEM_A = true, MEM_B = true, ZERO_G = true, FLAT = true }
-- Only one operation runs at a time; starting a new one cancels the old one.
local function run_op(device, name, fn)
  if not MB_PRESET_OPS[name] then device:set_field("preset_pending", false) end
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

-- motionBed start(position): keep moving until stop(), another command, end of travel or MAX_MOVE_S.
local function hold_move(device, conn, cancelled, position)
  local frame_name, part, dir = table.unpack(MB_MOVES[position])
  local start = socket.gettime()
  log.info(string.format("[%s] Hold move %s", device.label, position))

  local travel = tonumber(device.preferences.lumbarSeconds) or 15
  local lumbar_from = device:get_field("lumbar_pos") or (dir > 0 and 0 or 100)
  local last_pos, stall_t
  while not cancelled() do
    local now = socket.gettime()
    if now - start > MAX_MOVE_S then log.warn("Hold move timed out"); break end
    local s = exchange(conn, frame_name)
    report(device, s)
    if part == nil then
      local pos = math.max(0, math.min(100, lumbar_from + dir * ((now - start) / travel) * 100))
      device:set_field("lumbar_pos", pos, { persist = true })
      emit_level(device, "lumbar", pos)
    elseif s then
      local pos = s[part]
      if last_pos and pos == last_pos then stall_t = stall_t or now else stall_t = nil end
      last_pos = pos
      if stall_t and now - stall_t >= STALL_S and now - start > 1.5 then
        if dir > 0 then learn_max(device, part, pos, true) end
        break -- end of travel
      end
    end
  end
  if not conn.closed then stop_and_settle(device, conn) end
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

-- Set head and/or foot intensity (0-3) in one operation.
local function set_intensities(device, conn, cancelled, head, foot)
  if head then set_massage(device, conn, cancelled, "headMassage", head) end
  if foot and not cancelled() then set_massage(device, conn, cancelled, "footMassage", foot) end
end

local function clamp_intensity(v) return math.max(0, math.min(3, math.floor(tonumber(v) or 0))) end

local function handle_set_intensity(which)
  return function(driver, device, command)
    local level = clamp_intensity(command.args.intensity)
    log.info(string.format("[%s] massageIntensityControl %s -> %d", device.label, which, level))
    run_op(device, "intensity-" .. which, function(conn, cancelled)
      if which == "head" then set_intensities(device, conn, cancelled, level, nil)
      elseif which == "foot" then set_intensities(device, conn, cancelled, nil, level)
      else set_intensities(device, conn, cancelled, level, level) end
    end)
  end
end

-- nextIntensity: Off -> Low -> Medium -> High -> Off
local function handle_next_intensity(driver, device, command)
  local position = command.args.position
  log.info(string.format("[%s] nextIntensity %s", device.label, tostring(position)))
  run_op(device, "next-intensity", function(conn, cancelled)
    local st = read_status(conn)
    if not st then return end
    local head, foot = mas_index(st.head_mas), mas_index(st.foot_mas)
    local function nxt(v) return v < 3 and v + 1 or 0 end
    if position == "head" then set_intensities(device, conn, cancelled, nxt(head), nil)
    elseif position == "foot" then set_intensities(device, conn, cancelled, nil, nxt(foot))
    else local n = nxt(math.max(head, foot)); set_intensities(device, conn, cancelled, n, n) end
  end)
end

-- massageOperating start: restore the last levels used (Low/Low the first time)
local function handle_massage_start(driver, device, command)
  run_op(device, "massage-start", function(conn, cancelled)
    local st = read_status(conn)
    if not st then return end
    if st.head_mas > 0 or st.foot_mas > 0 then report(device, st, true); return end
    local last = device:get_field("last_mas") or { head = 1, foot = 1 }
    log.info(string.format("[%s] Massage start: head=%d foot=%d", device.label, last.head, last.foot))
    set_intensities(device, conn, cancelled, last.head, last.foot)
  end)
end

-- massageOperating stop: Timer/All Off (only if something is running)
local function handle_massage_stop(driver, device, command)
  run_op(device, "massage-stop", function(conn, cancelled)
    local st = read_status(conn)
    if not st then return end
    if st.head_mas > 0 or st.foot_mas > 0 then st = tap_and_wait(device, conn, "TIMER", st) end
    report(device, st, true)
  end)
end

-- massageTimeChange nextTime: 10 -> 20 -> 30 -> 10 (keeps a running massage going)
local function handle_next_time(driver, device, command)
  run_op(device, "next-time", function(conn, cancelled)
    local st = read_status(conn)
    if not st then return end
    set_timer(device, conn, cancelled, (st.timer % 3) + 1)
  end)
end

-- massageTimeControl setTime(minutes): 0 = all off; 10/20/30 (others rounded to the nearest)
local function handle_set_time(driver, device, command)
  local minutes = tonumber(command.args.massageTime) or 0
  local target = 0
  if minutes > 0 then target = math.max(1, math.min(3, math.floor(minutes / 10 + 0.5))) end
  log.info(string.format("[%s] setTime %s min -> %s", device.label, tostring(minutes), TIMER_MODES[target + 1]))
  run_op(device, "set-time", function(conn, cancelled)
    set_timer(device, conn, cancelled, target)
  end)
end

-- 6. CAPABILITY HANDLERS
-- Run a preset (Flat / Zero-G / Memory A / Memory B), then read where it ended up.
-- The first run of each preset (or after a relearn) records that position for mode matching.
local function run_preset(device, mode)
  local frame_name = MB_MODE_FRAME[mode]
  local settle = tonumber(device.preferences.presetSeconds) or 50
  device:set_field("preset_pending", true)
  emit_bed_mode(device, mode) -- show the requested mode right away
  run_op(device, frame_name, function(conn, cancelled)
    exchange(conn, frame_name)
    -- Polling sends STOP, which would interrupt the preset, so wait for it to finish first.
    local start = socket.gettime()
    while not cancelled() and socket.gettime() - start < settle do socket.sleep(0.25) end
    if cancelled() then return end
    local st = exchange(conn, "STOP") or exchange(conn, "STOP")
    learn_preset(device, mode, st)
    device:set_field("preset_pending", false)
    report(device, st, true)
  end)
end

local function handle_bed_set_mode(driver, device, command)
  local mode = command.args.mode
  if not MB_MODE_FRAME[mode] then return end
  log.info(string.format("[%s] motionBed setMode %s", device.label, mode))
  run_preset(device, mode)
end

local function handle_bed_start(driver, device, command)
  local position = command.args.position
  if not MB_MOVES[position] then return end
  run_op(device, "hold-" .. position, function(conn, cancelled)
    hold_move(device, conn, cancelled, position)
  end)
end

local function handle_bed_stop(driver, device, command)
  log.info(string.format("[%s] motionBed stop %s", device.label, tostring(command.args.position)))
  run_op(device, "stop", function(conn) stop_and_settle(device, conn) end)
end

local function handle_switch(driver, device, command)
  -- the switch only reports health: re-publish the real state and check now
  emit_switch(device)
  cosock.spawn(function() health_check(device) end, "ergomotion-health")
end

-- Vibration pattern as a fan-speed slider
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
  emit_static(device)
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
  local relearn = device.preferences.relearnPreset
  if relearn and relearn ~= old.relearnPreset and RELEARN[relearn] then
    for _, mode in ipairs(RELEARN[relearn]) do device:set_field("preset_" .. mode, nil, { persist = true }) end
    log.info(string.format("[%s] Cleared learned preset position(s) for %s; the next press relearns them", device.label, relearn))
  end
  if old.ipAddress ~= device.preferences.ipAddress
    or old.headMax ~= device.preferences.headMax
    or old.footMax ~= device.preferences.footMax then
    poll(device)
  end
end

local function device_init(driver, device)
  log.info(string.format("Attaching Ergomotion core handle for: %s", device.label))
  device:set_field("op_busy", false)
  device:set_field("preset_pending", false)
  device:set_field("online", nil)
  device:set_field("fail_count", 0)
  emit_switch(device) -- reports off until the first successful connection
  emit_static(device)
  emit_bed_mode(device, "noMode", true)
  device:set_field("mtc_epoch", nil)

  -- health: re-check every HEALTH_INTERVAL_S while online, every tick while offline
  device.thread:call_on_schedule(HEALTH_TICK_S, function()
    local last_ok = device:get_field("last_ok") or 0
    if device:get_field("online") ~= true or socket.gettime() - last_ok >= HEALTH_INTERVAL_S then
      health_check(device)
    end
  end, "health-check")
  -- The bed never reports lumbar, so always publish a value or the app disables the slider.
  -- If the position has never been tracked, show 0%; the first move re-syncs by lowering fully.
  device:set_field("lumbar_level", nil)
  emit_level(device, "lumbar", device:get_field("lumbar_pos") or 0, true)
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
    [capabilities.switchLevel.ID] = {
      [capabilities.switchLevel.commands.setLevel.NAME] = handle_set_level,
    },
    [capabilities.fanSpeed.ID] = {
      [capabilities.fanSpeed.commands.setFanSpeed.NAME] = handle_set_fan_speed,
    },
    ["massageIntensityControl"] = {
      ["setIntensityHead"] = handle_set_intensity("head"),
      ["setIntensityFoot"] = handle_set_intensity("foot"),
      ["setIntensityWhole"] = handle_set_intensity("whole"),
    },
    ["massageIntensityChange"] = {
      ["nextIntensity"] = handle_next_intensity,
    },
    ["massageOperating"] = {
      ["start"] = handle_massage_start,
      ["stop"] = handle_massage_stop,
    },
    ["massageTimeChange"] = {
      ["nextTime"] = handle_next_time,
    },
    ["massageTimeControl"] = {
      ["setTime"] = handle_set_time,
    },
    ["motionBed"] = {
      ["setMode"] = handle_bed_set_mode,
      ["start"] = handle_bed_start,
      ["stop"] = handle_bed_stop,
    },
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = handle_switch,
      [capabilities.switch.commands.off.NAME] = handle_switch,
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
