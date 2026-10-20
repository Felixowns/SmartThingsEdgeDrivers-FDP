local caps = require('st.capabilities')
local mdns = require('st.mdns')
local log = require('log')
local json = require('dkjson')
local cosock = require "cosock"
local socket = cosock.asyncify 'socket'
local http = cosock.asyncify "socket.http"
local ltn12 = require('ltn12')

local command_handler = {
  cached_ips = {}
}


function command_handler.resolve_ip(hostname)
  local hosts, error = mdns.resolve(hostname, "_http._tcp", "local")

  if hosts then
    for _, host in ipairs(hosts) do
      log.trace('Resolved '..hostname..' to '..host.address..':'..host.port)
      return host
    end
  end
  log.error('failed to resolve hostname '..hostname .. ' error: ' .. (error or ''))
  return nil
end

function command_handler.get_ip(hostname, use_cached)
  local hostinfo
  if use_cached then
    hostinfo = command_handler.cached_ips[hostname]
  else
    hostinfo = command_handler.resolve_ip(hostname)
    command_handler.cached_ips[hostname] = hostinfo
  end

  return hostinfo
end

------------------
-- Refresh command
function command_handler.refresh(_, device)
  log.trace('Refreshing '..device.label)
  if not command_handler.doRefresh(device, true) then
    if not command_handler.doRefresh(device, false) then
      device:offline()
      return
    end
  end
  -- Define online status
  device:online()
end


-- returns true if refreshing is done, false if another pass (with use_cached) is needed
function command_handler.doRefresh(device, use_cached)
  local hostinfo = command_handler.get_ip(device.device_network_id, use_cached)
  if hostinfo == nil then
    return false
  end

  --local success, data = command_handler.send_lan_command(
  --  hostinfo.address..':'..hostinfo.port,
  --  'GET',
  --  'air-data/latest')
  local success, data = command_handler.quick_and_dirty_http(
          hostinfo.address,
          hostinfo.port,
          'air-data/latest')

  -- Check success
  if success then
    log.trace(data)

    local raw_data = json.decode(data)

    local score = 100-raw_data.score
    local temp = raw_data.temp
    local humid = raw_data.humid
    local co2 = raw_data.co2
    local voc = raw_data.voc
    local pm25 = raw_data.pm25

    -- Refresh Switch Level

    device:emit_event(caps.airQualitySensor.airQuality(score))
    device:emit_event(caps.temperatureMeasurement.temperature({value=temp, unit='C'}))
    device:emit_event(caps.relativeHumidityMeasurement.humidity({value=humid}))
    device:emit_event(caps.carbonDioxideMeasurement.carbonDioxide(co2))
    device:emit_event(caps.tvocMeasurement.tvocLevel({value=voc/1000, unit='ppm'}))
    device:emit_event(caps.fineDustSensor.fineDustLevel(pm25))
    return true
  else
    log.error('failed to poll device state')
    return false
  end
end

function command_handler.quick_and_dirty_http(address, port, path)
  local dest_url = 'http://'..address..':'..port..'/'..path
  log.info('Querying '..dest_url)

  local tcp = socket.tcp();
  tcp:settimeout(3)
  local s, status = tcp:connect(address, port)
  if not s then
      log.error('failed to connect: '..(status or ''))
      return false, nil
  end
  s, status = tcp:send("GET /"..path.." HTTP/1.1\r\nHost: "..address.."\r\n\r\n")
  if not s then
    log.error('failed to send request: '..(status or ''))
    tcp:close()
    return false, nil
  end

  while true do
    s, status = tcp:receive('*l')
    --log.info("Received: ".. (s or 'status: '..status))
    if status then
      log.error('error receiving: '..(status or ''))
      tcp:close()
      return false, nil
    end
    local jsonData = s:match('(%{.*%})')
    if jsonData then
      tcp:close()
      return true, jsonData
    end
  end
end


------------------------
-- HTTP Request version of the above, does not currently work
function command_handler.send_lan_command(url, method, path)
  local dest_url = 'http://'..url..'/'..path
  log.trace('Querying '..dest_url)
--   local query = neturl.buildQuery(body or {})
  local res_body = {}

  -- HTTP Request
  local success, code, _, status = http.request({
    method=method,
    url=dest_url,
    sink=ltn12.sink.table(res_body),
--     headers={
--       ['Content-Type'] = 'application/json'
--     }
    create = function()
       local sock = cosock.socket.tcp()
       sock:settimeout(15)
       return sock
    end,
  })


  if not success then
    local err = code -- in error case second param is error message

    log.error(string.format("error while getting status for %s: %s",
                        url,
                        err))
    return false, nil
  elseif code ~= 200 then
    log.error(string.format("unexpected HTTP error response from %s: %s",
                         url,
                         status))
    return false, nil
  elseif code == 200 then
    return true, table.concat(res_body)
  end
end

return command_handler
