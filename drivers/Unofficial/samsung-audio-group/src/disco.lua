-- SSDP discovery for Samsung multiroom speakers.
-- Any device answering the Samsung RemoteControlReceiver search is accepted only if it
-- also answers the speaker API on port 55001 (filters out TVs), so newer models that
-- aren't on a hardcoded model list still get picked up.

local cosock = require "cosock"
local socket = require "cosock.socket"
local http = cosock.asyncify "socket.http"
local ltn12 = require "ltn12"
local xml2lua = require "xml2lua"
local xml_handler = require "xmlhandler.tree"
local log = require "log"
local command = require "command"

http.TIMEOUT = 4

local SEARCH_TARGETS = {
  "urn:samsung.com:device:RemoteControlReceiver:1",
  "urn:schemas-upnp-org:device:MediaRenderer:1",
}
local SPEAKER_PORT = 55001
local MULTICAST_IP = "239.255.255.250"
local MULTICAST_PORT = 1900

local Disco = {}

local txt = command.txt

local function parse_headers(val)
  local info = {}
  for line in string.gmatch(val, "[^\r\n]+") do
    local k, v = string.match(line, "^([^:%s]+)%s*:%s*(.-)%s*$")
    if k then info[string.lower(k)] = v end
  end
  return info
end

local function fetch_metadata(location)
  local chunks = {}
  local ok, code = http.request { url = location, sink = ltn12.sink.table(chunks) }
  if not ok or code ~= 200 then
    log.debug(string.format("metadata fetch failed for %s (%s)", location, tostring(code)))
    return nil
  end
  local handler = xml_handler:new()
  local parser = xml2lua.parser(handler)
  if not pcall(parser.parse, parser, table.concat(chunks)) then return nil end
  local root = handler.root and handler.root.root
  local dev = type(root) == "table" and root.device or nil
  if type(dev) ~= "table" then return nil end

  local udn = txt(dev.UDN)
  local mac = nil
  if udn and #udn >= 12 then
    -- same id the SmartThings driver used for device_network_id
    mac = string.upper(string.sub(udn, -12))
  end
  return {
    mac = mac,
    name = txt(dev.friendlyName),
    model = txt(dev.modelName),
  }
end

--- Check one IP directly. location (optional) is the SSDP description URL.
--- @return table|nil {id, ip, name, model}
function Disco.probe(ip, location)
  local spk_name = command.get_speaker_name(ip)
  if not spk_name then
    log.debug(string.format("%s does not answer the Samsung speaker API, skipping", ip))
    return nil
  end
  local meta = location and fetch_metadata(location) or nil
  local name = spk_name
  if name == "" then name = (meta and meta.name) or ("Samsung speaker " .. ip) end
  return {
    id = meta and meta.mac or nil,
    ip = ip,
    name = name,
    model = (meta and meta.model) or "Samsung speaker",
  }
end

--- Multicast search; returns a list of verified speakers.
function Disco.scan(timeout)
  timeout = timeout or 4
  local s, err = socket.udp()
  if not s then
    log.error("discovery: cannot create socket: " .. tostring(err))
    return {}
  end
  local ok, serr = s:setsockname("0.0.0.0", 0)
  if not ok then
    log.error("discovery: setsockname failed: " .. tostring(serr))
    s:close()
    return {}
  end

  local function send_all()
    for _, st in ipairs(SEARCH_TARGETS) do
      local msg = table.concat({
        "M-SEARCH * HTTP/1.1",
        "HOST: 239.255.255.250:1900",
        'MAN: "ssdp:discover"',
        "MX: 2",
        "ST: " .. st,
        "", "",
      }, "\r\n")
      local ok, serr2 = s:sendto(msg, MULTICAST_IP, MULTICAST_PORT)
      if not ok then log.warn("SSDP send failed: " .. tostring(serr2)) end
    end
  end

  send_all()
  local sends_left = 2 -- multicast is lossy: send 3 times, 1 s apart
  local resend_at = socket.gettime() + 1
  local deadline = socket.gettime() + timeout
  local locations, order, seen, rcr = {}, {}, {}, {}

  while true do
    local now = socket.gettime()
    if now >= deadline then break end
    if resend_at and now >= resend_at then
      send_all()
      sends_left = sends_left - 1
      resend_at = (sends_left > 0) and (now + 1) or nil
    end
    s:settimeout(math.max(0.05, math.min(deadline, resend_at or deadline) - now))
    local val, rip = s:receivefrom()
    if val then
      local h = parse_headers(val)
      local loc = h["location"]
      local lip = loc and string.match(loc, "^http://([^:/]+)")
      if rip and not seen[rip] then
        log.info(string.format("SSDP reply from %s st=%s location=%s server=%s",
          tostring(rip), tostring(h["st"]), tostring(loc), tostring(h["server"])))
      end
      -- soundbars answer both searches with different description URLs (and different UDNs);
      -- always prefer the RemoteControlReceiver one so a speaker's id stays the same
      local is_rcr = string.find(h["st"] or "", "RemoteControlReceiver", 1, true) ~= nil
      if rip and not seen[rip] then
        seen[rip] = true
        table.insert(order, rip)
      end
      if rip and lip == rip and (is_rcr or not locations[rip]) and not rcr[rip] then
        locations[rip] = loc
        if is_rcr then rcr[rip] = true end
      end
    elseif rip ~= "timeout" then
      log.warn("discovery receive error: " .. tostring(rip))
      break
    end
  end
  s:close()

  log.info(string.format("SSDP: %d device(s) answered", #order))
  local results = {}
  for _, ip in ipairs(order) do
    local spk = Disco.probe(ip, locations[ip])
    if spk then
      log.info(string.format("found speaker %s (%s) at %s id=%s", spk.name, spk.model, spk.ip, tostring(spk.id)))
      table.insert(results, spk)
    end
  end
  return results
end

--- Fallback when multicast is blocked: try TCP port 55001 on every host in the hub's /24.
function Disco.sweep(hub_ip, skip)
  local prefix = hub_ip and string.match(hub_ip, "^(%d+%.%d+%.%d+)%.%d+$")
  if not prefix then
    log.warn("subnet sweep skipped: hub IP unknown")
    return {}
  end
  skip = skip or {}
  log.info(string.format("sweeping %s.1-254 for speaker port %d", prefix, SPEAKER_PORT))
  local tx, rx = cosock.channel.new()
  local open = {}
  local BATCH = 32
  for first = 1, 254, BATCH do
    local n = 0
    for i = first, math.min(254, first + BATCH - 1) do
      local ip = prefix .. "." .. i
      if ip ~= hub_ip and not skip[ip] then
        n = n + 1
        cosock.spawn(function()
          local t = socket.tcp()
          local ok = false
          if t then
            t:settimeout(0.8)
            ok = t:connect(ip, SPEAKER_PORT) and true or false
            t:close()
          end
          tx:send(ok and ip or "")
        end, "sweep " .. ip)
      end
    end
    for _ = 1, n do
      local r = rx:receive()
      if r and r ~= "" then table.insert(open, r) end
    end
  end
  log.info(string.format("sweep: %d host(s) have port %d open", #open, SPEAKER_PORT))

  local results = {}
  for _, ip in ipairs(open) do
    local spk = Disco.probe(ip)
    if spk then
      log.info(string.format("found speaker %s at %s (sweep)", spk.name, spk.ip))
      table.insert(results, spk)
    end
  end
  return results
end

return Disco
