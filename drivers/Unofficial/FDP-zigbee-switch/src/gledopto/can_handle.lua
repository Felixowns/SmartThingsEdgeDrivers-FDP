return function(opts, driver, device)
  local FINGERPRINTS = require "gledopto.fingerprints"
  local fingerprint = (FINGERPRINTS[device:get_manufacturer()] or {})[device:get_model()]
  if fingerprint then
    local subdriver = require("gledopto")
    return true, subdriver
  end
  return false
end
