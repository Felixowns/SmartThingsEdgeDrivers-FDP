-- Copyright 2025 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0

local AEOTEC_HEAVY_DUTY_SWITCH = {
  PARAMETERS = {
    overloadProtection = { type = 'config', parameter_number = 3, size = 1 },
    ledAfterPower      = { type = 'config', parameter_number = 20, size = 1 },
    autoReportType     = { type = 'config', parameter_number = 80, size = 1 },
    powerThreshold     = { type = 'config', parameter_number = 90, size = 1 },
    group1Sensors      = { type = 'config', parameter_number = 101, size = 4 },
    group2Sensors      = { type = 'config', parameter_number = 102, size = 4 },
    group3Sensors      = { type = 'config', parameter_number = 103, size = 4 },
    group1Time         = { type = 'config', parameter_number = 111, size = 4 },
    group2Time         = { type = 'config', parameter_number = 112, size = 4 },
    group3Time         = { type = 'config', parameter_number = 113, size = 4 },
    assocGroup1        = { type = 'assoc', group = 1, maxnodes = 5, addhub = true }
  }
}

local SWITCH_US = {
  PARAMETERS = {
    thresholdKwh    = { type = 'config', parameter_number = 20, size = 2 },
    thresholdPower  = { type = 'config', parameter_number = 21, size = 2 },
    assocGroup1     = { type = 'assoc', group = 1, maxnodes = 5, addhub = true }
  }
}

local SWITCH_EU = {
  PARAMETERS = {
    thresholdPower = { type = 'config', parameter_number = 91, size = 2 },
    thresholdKwh   = { type = 'config', parameter_number = 92, size = 2 },
    group1Sensors  = { type = 'config', parameter_number = 101, size = 4 },
    group1Time     = { type = 'config', parameter_number = 111, size = 4 },
    assocGroup1    = { type = 'assoc', group = 1, maxnodes = 5, addhub = true }
  }
}

local devices = {
  AEOTEC_NANO_DIMMER = {
    MATCHING_MATRIX = {
      mfrs = 0x0086,
      product_types = {0x0003, 0x0103, 0x0203},
      product_ids = 0x006F
    },
    PARAMETERS = {
      minimumDimmingValue = {parameter_number = 131, size = 1}
    }
  },
  AEOTEC_HEAVY_DUTY = {
    MATCHING_MATRIX = {
      mfrs = 0x0086,
      product_ids = 0x004E
    },
    PARAMETERS = AEOTEC_HEAVY_DUTY_SWITCH.PARAMETERS
  },
  AEOTEC_SMART_SWITCH_US = {
    MATCHING_MATRIX = {
      mfrs = 0x0371,
      product_types = 0x0103,
      product_ids = 0x0017
    },
    PARAMETERS = SWITCH_US.PARAMETERS
  },
  AEOTEC_SMART_SWITCH_7_EU = {
    MATCHING_MATRIX = {
      mfrs = 0x0371,
      product_types = 0x0003,
      product_ids = 0x00AF
    },
    PARAMETERS = SWITCH_EU.PARAMETERS
  }
}

local preferences = {}

preferences.get_device_parameters = function(zw_device)
  for _, device in pairs(devices) do
    if zw_device:id_match(
      device.MATCHING_MATRIX.mfrs,
      device.MATCHING_MATRIX.product_types,
      device.MATCHING_MATRIX.product_ids) then
      return device.PARAMETERS
    end
  end
  return nil
end

preferences.to_numeric_value = function(new_value)
  local numeric = tonumber(new_value)
  if numeric == nil then -- in case the value is boolean
    numeric = new_value and 1 or 0
  end
  return numeric
end

return preferences
