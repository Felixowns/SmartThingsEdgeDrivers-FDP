local mdns = require('st.mdns')
local log = require('log')

local function create_device(driver, device)
  log.info('===== CREATING DEVICE...')
  log.info('===== DEVICE DESTINATION ADDRESS: '..device.host_info.name)
  -- device metadata table
  local metadata = {
    type = "LAN",
    device_network_id = device.host_info.name,
    --device_network_id = device.host_info.address..':'..device.host_info.port,
    label = device.service_info.name,
    profile = "AWAIR-local",
    manufacturer = "AWAIR",
--     model = device.model,
--     vendor_provided_label = device.UDN
  }
  return driver:try_create_device(metadata)
end

local disco = {}
function disco.start(driver, _, _)
    local discover_responses = mdns.discover("_http._tcp", "local") or {}
    local device

    for _, found in ipairs(discover_responses.found) do
      log.info('===== DEVICE FOUND IN NETWORK...')
      log.info('===== DEVICE SERVICE NAME: '..found.service_info.name)
      log.info('===== DEVICE HOSTNAME: '..found.host_info.name)
      log.info('===== DEVICE IP: '..found.host_info.address)
      if found ~= nil and found.service_info.service_type == "_http._tcp" and string.match(found.service_info.name, "AWAIR.*") ~= nil
          then
        device = create_device(driver, found)
      end
    end
    if device ~= nil then
      return device
    end
end

return disco
