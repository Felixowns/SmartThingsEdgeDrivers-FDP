return function(opts, driver, device)
  local FINGERPRINTS = require "third-reality.fingerprints"
  local mfr = device:get_manufacturer() or ""
  if FINGERPRINTS[device:get_model()] and mfr:find("^Third Reality") then
    local subdriver = require("third-reality")
    return true, subdriver
  end
  return false
end
