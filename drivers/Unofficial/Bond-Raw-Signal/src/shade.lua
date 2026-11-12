-- Shades / pergolas. Bond mode: Bridge Open/Close/Hold/SetPosition.
-- Custom mode: momentary-motor positioning by counting raw Open/Close bursts.
local capabilities = require "st.capabilities"
local cosock       = require "cosock"
local socket       = require "cosock.socket"
local log          = require "log"
local bond         = require "bond"
local U            = require "util"

local M = {}
local POS, MOVE = "position", "move_id"
local ws = capabilities.windowShade.windowShade

local function get_pos(device) return device:get_field(POS) or 0 end

local function set_pos(device, pos)
  pos = math.max(0, math.min(100, math.floor(pos + 0.5)))
  device:set_field(POS, pos, { persist = true })
  device:emit_event(capabilities.windowShadeLevel.shadeLevel(pos))
  if pos >= 100 then device:emit_event(ws.open())
  elseif pos <= 0 then device:emit_event(ws.closed())
  else device:emit_event(ws.partially_open()) end
end

local function cancel(device) device:set_field(MOVE, (device:get_field(MOVE) or 0) + 1) end

-- ---- custom: burst positioning ----
local function burst_move(device, target)
  local info = U.info(device)
  target = math.max(0, math.min(100, target))
  cancel(device)
  local my_id, start = device:get_field(MOVE), get_pos(device)
  local delta, full_end = target - start, (target == 0 or target == 100)
  if delta == 0 and not full_end then return set_pos(device, start) end
  local opening = delta > 0 or (delta == 0 and target == 100)
  local sig = U.sig(info, opening and "Open" or "Close")
  if not sig then
    return log.warn("[" .. device.label .. "] no raw " .. (opening and "Open" or "Close") ..
                    " signal (template device?). Learn the remote buttons in the Bond app, then Refresh the Bond Bridge.")
  end
  local full = opening and U.pref(device, "openBursts", 45) or U.pref(device, "closeBursts", 45)
  local n = math.floor(math.abs(delta) * full / 100 + 0.5)
  if full_end then n = n + U.pref(device, "coastBursts", 5) end
  local interval = U.pref(device, "burstMs", 620) / 1000
  local step = 100 / full
  device:emit_event(opening and ws.opening() or ws.closing())
  log.info(string.format("[%s] %d%% -> %d%%: %d bursts", device.label, start, target, n))
  cosock.spawn(function()
    local sent = 0
    for i = 1, n do
      if device:get_field(MOVE) ~= my_id then break end
      local t0 = socket.gettime()
      bond.tx(device, sig, 1)
      sent = i
      local wait = interval - (socket.gettime() - t0)
      if wait > 0 then socket.sleep(wait) end
    end
    if device:get_field(MOVE) == my_id then set_pos(device, target)
    else set_pos(device, start + math.min(sent * step, math.abs(delta)) * (opening and 1 or -1)) end
  end, "shade move " .. device.id)
end

-- ---- bond mode ----
local function bond_refresh(device)
  local st = bond.state(device)
  if not st then return set_pos(device, get_pos(device)) end
  if st.position ~= nil then set_pos(device, 100 - st.position)   -- Bond: 0 = open
  else set_pos(device, st.open == 1 and 100 or 0) end
end

local function bond_move(device, target)
  local info = U.info(device)
  if target >= 100 then bond.action(device, "Open")
  elseif target <= 0 then bond.action(device, "Close")
  elseif U.has_action(info, "SetPosition") then bond.action(device, "SetPosition", 100 - target)
  else bond.action(device, target >= 50 and "Open" or "Close") end
  bond_refresh(device)
end

local function move(device, target)
  if U.custom(device) then burst_move(device, target) else bond_move(device, target) end
end

function M.open(driver, device)  move(device, 100) end
function M.close(driver, device) move(device, 0) end
function M.pause(driver, device)
  if U.custom(device) then return cancel(device) end
  local info = U.info(device)
  bond.action(device, U.has_action(info, "Hold") and "Hold" or "Stop")
  bond_refresh(device)
end
function M.level(driver, device, cmd) move(device, tonumber(cmd.args.shadeLevel) or 0) end
function M.refresh(driver, device)
  if U.custom(device) then set_pos(device, get_pos(device)) else bond_refresh(device) end
end
function M.init(driver, device)
  device:emit_event(capabilities.windowShade.supportedWindowShadeCommands(
    { "open", "close", "pause" }, { visibility = { displayed = false } }))
  M.refresh(driver, device)
end

return M
