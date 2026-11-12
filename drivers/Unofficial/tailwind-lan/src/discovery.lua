-- mDNS discovery (Tailwind API section 1):
-- controllers advertise "TW-WebServer" under _http._tcp, host tailwind-<mac>.local,
-- TXT: vendor=tailwind, device_id=_aa_bb_.._, Product=iQ3|light, SW ver, HW ver, Homekit.

local log = require "log"
local api = require "tailwind_api"

local ok_mdns, mdns = pcall(require, "st.mdns")

local M = {}

local function txt_map(entry)
  local out = {}
  local txt = entry.txt
  local list = txt and (txt.text or txt) or {}
  if type(list) == "table" then
    for _, kv in ipairs(list) do
      if type(kv) == "string" then
        local k, v = kv:match("^([^=]+)=(.*)$")
        if k then out[k:lower()] = v end
      end
    end
  end
  return out
end

--- Returns list of { id = "30aea4801880", ip = "x.x.x.x", product = "iQ3", fw = "10.10" }
function M.scan()
  if not ok_mdns then
    log.warn("tailwind: st.mdns not available on this hub firmware")
    return {}
  end
  local res, err = mdns.discover("_http._tcp", "local")
  if not res then
    log.warn("tailwind: mDNS error: " .. tostring(err))
    return {}
  end
  local found, seen = {}, {}
  for _, e in ipairs(res.found or {}) do
    local si, hi = e.service_info or {}, e.host_info or {}
    local txt = txt_map(e)
    local name = tostring(si.name or "")
    local host = tostring(hi.name or "")
    local is_tw = (txt.vendor and txt.vendor:lower() == "tailwind")
      or name:find("TW%-WebServer") or host:lower():find("^tailwind%-")
    if is_tw then
      local id = api.normalize_id(host) or api.normalize_id(txt.device_id)
      local ip = hi.address
      if id and ip and not seen[id] then
        seen[id] = true
        found[#found + 1] = {
          id = id, ip = ip,
          product = txt.product or "iQ3",
          fw = txt["sw ver"],
        }
        log.info(string.format("tailwind: found %s at %s (%s, fw %s)",
          id, ip, tostring(txt.product), tostring(txt["sw ver"])))
      end
    end
  end
  return found
end

--- Re-resolve a known controller's IP by id (used when it stops answering)
function M.lookup(id)
  for _, f in ipairs(M.scan()) do
    if f.id == id then return f.ip end
  end
  return nil
end

return M
