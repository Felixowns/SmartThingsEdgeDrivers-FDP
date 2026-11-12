-- Bond Bridge local API helpers: HTTP, credentials, token, mDNS discovery, raw tx, actions
local cosock = require "cosock"
local http   = cosock.asyncify "socket.http"
local ltn12  = require "ltn12"
local json   = require "st.json"
local log    = require "log"
http.TIMEOUT = 4

local M = {}

function M.blank(v) return v == nil or v == "" end

-- The hub (Bond Bridge) device for any device
function M.hub_of(device)
  if device.network_type == "DEVICE_EDGE_CHILD" then return device:get_parent_device() end
  return device
end

function M.creds(device)
  local hub = M.hub_of(device)
  if hub == nil then return nil, nil end
  local ip = hub.preferences.bondIp
  if M.blank(ip) then ip = hub:get_field("ip") end
  local token = hub.preferences.bondToken
  if M.blank(token) then token = hub:get_field("token") end
  return ip, token
end

-- Raw request. body_str is a JSON string or nil. Returns status code, decoded body.
function M.request(ip, token, method, path, body_str)
  local headers = { ["BOND-Token"] = token or "" }
  local source = nil
  if body_str ~= nil then
    headers["Content-Type"] = "application/json"
    headers["Content-Length"] = tostring(#body_str)
    source = ltn12.source.string(body_str)
  end
  local resp = {}
  local ok, code = http.request{
    url = "http://" .. ip .. path, method = method, headers = headers,
    source = source, sink = ltn12.sink.table(resp),
  }
  if not ok then return nil, nil end
  local text = table.concat(resp)
  local data = nil
  if #text > 0 then
    local good, decoded = pcall(json.decode, text)
    if good then data = decoded end
  end
  return code, data
end

function M.call(device, method, path, body_str)
  local ip, token = M.creds(device)
  if M.blank(ip) then
    log.warn("[" .. device.label .. "] Bond Bridge IP unknown")
    return nil, nil
  end
  return M.request(ip, token, method, path, body_str)
end

-- Token is readable without auth for ~10 minutes after the Bridge powers up
function M.fetch_token(ip)
  local code, data = M.request(ip, "", "GET", "/v2/token", nil)
  if code == 200 and type(data) == "table" and data.locked == 0 and not M.blank(data.token) then
    return data.token
  end
  return nil
end

-- Find Bond Bridges via mDNS (_bond._tcp). Returns { {ip=, id=}, ... }
function M.discover()
  local found = {}
  local ok, mdns = pcall(require, "st.mdns")
  if not ok or mdns == nil then
    log.warn("st.mdns not available on this hub firmware")
    return found
  end
  local good, res = pcall(mdns.discover, "_bond._tcp", "local")
  if not good or type(res) ~= "table" or type(res.found) ~= "table" then return found end
  for _, f in ipairs(res.found) do
    local ip = f.host_info and f.host_info.address
    local name = f.service_info and f.service_info.name
    if type(ip) == "string" and ip:match("^%d+%.%d+%.%d+%.%d+$") then
      table.insert(found, { ip = ip, id = name or ip })
    end
  end
  return found
end

function M.duration(sig) return #sig.data * 4 / sig.bps end

-- Broadcast a stored raw signal
function M.tx(device, sig, reps)
  local body = string.format(
    '{"freq":%d,"bps":%d,"modulation":"%s","encoding":"%s","data":"%s","reps":%d}',
    sig.freq, sig.bps, sig.modulation or "OOK", sig.encoding or "hex", sig.data,
    reps or sig.reps or 1)
  local code = M.call(device, "PUT", "/v2/signal/tx", body)
  if code ~= 204 and code ~= 200 then
    log.warn(string.format("[%s] raw tx failed: %s", device.label, tostring(code)))
    return false
  end
  return true
end

-- Ask the Bridge to run one of its own actions for this Bond device
function M.action(device, action, arg)
  local body = "{}"
  if arg ~= nil then body = '{"argument":' .. tostring(arg) .. '}' end
  local code = M.call(device, "PUT",
    "/v2/devices/" .. device.parent_assigned_child_key .. "/actions/" .. action, body)
  if code ~= 200 and code ~= 204 then
    log.warn(string.format("[%s] Bond action %s failed: %s", device.label, action, tostring(code)))
    return false
  end
  return true
end

function M.state(device)
  local code, data = M.call(device, "GET",
    "/v2/devices/" .. device.parent_assigned_child_key .. "/state", nil)
  if code == 200 and type(data) == "table" then return data end
  return nil
end

return M
