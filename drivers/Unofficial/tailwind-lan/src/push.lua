-- UDP status-report listener (Tailwind API 3.2, proto "udp").
-- One socket per driver; reports are routed to the controller by source IP
-- (falling back to dev_id in the payload).

local cosock = require "cosock"
local socket = cosock.socket
local json = require "st.json"
local log = require "log"

local M = {}

local function hub_ip_for(driver, peer_ip)
  local env = driver.environment_info
  if env and env.hub_ipv4 and env.hub_ipv4 ~= "" then return env.hub_ipv4 end
  -- fallback: let the OS pick the outgoing interface toward the controller
  local s = socket.udp()
  s:setpeername(peer_ip or "8.8.8.8", 80)
  local ip = s:getsockname()
  s:close()
  return ip
end

--- Start (once) and return "hubip:port" for notify_url, or nil
function M.ensure(driver, peer_ip, on_report)
  if not driver.tw_push then
    local sock = socket.udp()
    local ok, err = sock:setsockname("*", 0)
    if not ok then
      log.error("tailwind push: bind failed: " .. tostring(err))
      return nil
    end
    local _, port = sock:getsockname()
    driver.tw_push = { sock = sock, port = port }
    log.info("tailwind push: listening on UDP " .. tostring(port))

    driver:register_channel_handler(sock, function()
      local data, ip = sock:receivefrom(4096)
      if not data then return end
      local msg = json.decode(data)
      if type(msg) ~= "table" then
        log.warn("tailwind push: non-JSON from " .. tostring(ip))
        return
      end
      on_report(driver, ip, msg)
    end, "tailwind udp push")
  end
  local hub = hub_ip_for(driver, peer_ip)
  if not hub then return nil end
  return hub .. ":" .. tostring(driver.tw_push.port)
end

return M
