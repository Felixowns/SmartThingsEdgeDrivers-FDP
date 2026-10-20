-- Copyright 2025 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0


local function can_handle(opts, driver, device, ...)
  local fingerprints = {
    {mfr = 0x0086, prodId = 0x0060},
    {mfr = 0x0371, prodId = 0x00AF}, -- Smart Switch 7 EU
    {mfr = 0x0371, prodId = 0x0017},  -- Smart Switch 7 US
    {mfr = 0x0086, prodId = 0x0075}  -- aeotec smart switch with energy monitoring
  }

  for _, fingerprint in ipairs(fingerprints) do
    if device:id_match(fingerprint.mfr, nil, fingerprint.prodId) then
      local subdriver = require("aeotec-smart-switch")
      return true, subdriver
    end
  end
  return false
end

return can_handle
