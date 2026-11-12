-- Tailwind Local Control API client (iQ3 garage controller + Tailwind Light)
-- Reference: https://github.com/Scott--R/Tailwind_Local_Control_API (fw 9.96+ JSON API)
--
-- Every call is an HTTP POST of a JSON body to http://<ip>/json with header
-- "TOKEN: <6-digit local control key>". Responses: {"result":"OK", ...} or
-- {"result":"Fail","info":"..."}.

local cosock = require "cosock"
local http = cosock.asyncify "socket.http"
local ltn12 = require "ltn12"
local json = require "st.json"
local log = require "log"

http.TIMEOUT = 5

local M = {}

-- door_op / status_led / notify_url / dev_op use protocol 0.1;
-- identify / reboot / server_monitor were added with protocol 0.2.
local function body(product, version, data)
  local t = { version = version or "0.1", data = data }
  if product then t.product = product end
  return json.encode(t)
end

--- Low-level POST. Returns decoded table or nil, err
function M.post(ip, token, payload)
  if not ip or ip == "" then return nil, "no ip" end
  local resp = {}
  local headers = {
    ["Content-Type"] = "application/json",
    ["Content-Length"] = tostring(#payload),
  }
  if token and token ~= "" then headers["TOKEN"] = token end

  local last_err
  for attempt = 1, 2 do
    resp = {}
    local ok, code = http.request {
      url = "http://" .. ip .. "/json",
      method = "POST",
      headers = headers,
      source = ltn12.source.string(payload),
      sink = ltn12.sink.table(resp),
    }
    if ok and code == 200 then
      local text = table.concat(resp)
      local decoded, _, derr = json.decode(text)
      if type(decoded) ~= "table" then
        return nil, "bad json: " .. tostring(derr or text)
      end
      if decoded.result ~= "OK" then
        return nil, "device: " .. tostring(decoded.info or decoded.Info or text), decoded
      end
      return decoded
    end
    last_err = ok and ("http " .. tostring(code)) or tostring(code)
    if code == 401 or code == 403 then break end -- bad token, don't retry
    if attempt == 1 then cosock.socket.sleep(0.5) end
  end
  return nil, last_err
end

-- 3.1 Read device status (all products)
function M.get_status(ip, token)
  return M.post(ip, token, body(nil, "0.1", { type = "get", name = "dev_st" }))
end

-- 3.2 Status report (push) address. proto "udp" -> url "ip:port"; "http" -> full URL
function M.set_notify(ip, token, product, proto, url, enable)
  return M.post(ip, token, body(product or "iQ3", "0.1", {
    type = "set", name = "notify_url",
    value = { url = url, proto = proto, enable = enable and 1 or 0 },
  }))
end

-- 3.3 Open/close door. door_idx 0..2. partial_ms only valid with "open".
function M.door_op(ip, token, door_idx, cmd, partial_ms)
  local value = { door_idx = door_idx, cmd = cmd }
  if cmd == "open" and partial_ms and partial_ms > 0 then value.partial_time = math.floor(partial_ms) end
  return M.post(ip, token, body("iQ3", "0.1", { type = "set", name = "door_op", value = value }))
end

-- 3.4 Green status LED brightness 0..100
function M.set_led(ip, token, brightness)
  return M.post(ip, token, body("iQ3", "0.1", {
    type = "set", name = "status_led", value = { brightness = brightness },
  }))
end

-- 3.5 Light controller parameters (any subset of power/delay/lux/distance/mode)
function M.light_op(ip, token, value)
  return M.post(ip, token, body("light", "0.1", { type = "set", name = "dev_op", value = value }))
end

-- 3.6 Identify (blink white LED 3x), fw 10.10+
function M.identify(ip, token, product)
  return M.post(ip, token, body(product or "iQ3", "0.2", { type = "set", name = "identify" }))
end

-- 3.7 Reboot (~2 s), fw 10.10+
function M.reboot(ip, token, product)
  return M.post(ip, token, body(product or "iQ3", "0.2", { type = "set", name = "reboot" }))
end

-- 3.8 Server connection monitoring (self-reboot when cloud unreachable), fw 10.61+
function M.server_monitor(ip, token, enable)
  return M.post(ip, token, body("iQ3", "0.2", {
    type = "set", name = "server_monitor", value = { enable = enable and true or false },
  }))
end

--- "_30_ae_a4_80_18_80_" / "30:ae:a4:80:18:80" / "tailwind-30aea4801880.local" -> "30aea4801880"
function M.normalize_id(s)
  if type(s) ~= "string" then return nil end
  local host = s:match("tailwind%-(%x+)")
  if host and #host == 12 then return host:lower() end
  local parts = {}
  for p in s:gmatch("%x+") do
    if #p > 2 then return nil end
    parts[#parts + 1] = string.rep("0", 2 - #p) .. p:lower()
  end
  if #parts ~= 6 then
    log.debug("tailwind: could not normalize id " .. s)
    return nil
  end
  return table.concat(parts)
end

return M
