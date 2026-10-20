-- Copyright 2025 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0

local devices = {
  AEOTEC_METERING_SWITCH = {
    MATCHING_MATRIX = {
      mfrs = 0x0086,
      product_types = {0x0003, 0x0103, 0x0203},
      product_ids = {0x0012, 0x0060, 0x0074, 0x004E}
    },
    CONFIGURATION = {
      {parameter_number = 80, size = 1, configuration_value = 2},
      {parameter_number = 101, size = 4, configuration_value = 12},
      {parameter_number = 111, size = 4, configuration_value = 300}
    }
  },
  AEOTEC_SMART_SWITCH_7 = {
    MATCHING_MATRIX = {
      mfrs = 0x0371,
      product_types = 0x0103,
      product_ids = 0x0017
    },
    CONFIGURATION = {
      {parameter_number = 21, size = 2, configuration_value = 2}
    }
  },
  AEOTEC_DUAL_NANO_SWITCH = {
    MATCHING_MATRIX = {
      mfrs = 0x0086,
      product_types = {0x0003, 0x0103, 0x0203},
      product_ids = 0x0084
    },
    CONFIGURATION = {
      {parameter_number = 255, size = 1, configuration_value = 0},
      {parameter_number = 4, size = 1, configuration_value = 1},
      {parameter_number = 80, size = 1, configuration_value = 2},
      {parameter_number = 101, size = 4, configuration_value = 2048},
      {parameter_number = 111, size = 4, configuration_value = 600},
      {parameter_number = 102, size = 4, configuration_value = 4096},
      {parameter_number = 112, size = 4, configuration_value = 600},
      {parameter_number = 90, size = 1, configuration_value = 1},
      {parameter_number = 91, size = 2, configuration_value = 20}
    }
  },
  AEOTEC_NANO_DIMMER = {
    MATCHING_MATRIX = {
      mfrs = 0x0086,
      product_types = {0x0003, 0x0103, 0x0203},
      product_ids = 0x006F
    },
    CONFIGURATION = {
      {parameter_number = 80, size = 1, configuration_value = 2},
      {parameter_number = 101, size = 4, configuration_value = 12},
      {parameter_number = 111, size = 4, configuration_value = 300},
      {parameter_number = 90, size = 1, configuration_value = 1},
      {parameter_number = 91, size = 2, configuration_value = 1},
      {parameter_number = 102, size = 1, configuration_value = 4},
      {parameter_number = 103, size = 1, configuration_value = 8},
      {parameter_number = 112, size = 4, configuration_value = 300},
      {parameter_number = 113, size = 4, configuration_value = 300}
    }
  },
  AEOTEC_DIMMER_SWITCH = {
    MATCHING_MATRIX = {
      mfrs = 0x0086,
      product_types = {0x0003, 0x0103, 0x0203},
      product_ids = {0x001B, 0x0063}
    },
    CONFIGURATION = {
      {parameter_number = 80, size = 1, configuration_value = 2},
      {parameter_number = 101, size = 4, configuration_value = 12},
      {parameter_number = 111, size = 4, configuration_value = 300}
    }
  },
  AEOTEC_SMART_SWITCH_AND_ILLUMINATOR = {
    MATCHING_MATRIX = {
      mfrs = 0x0086,
      product_types = {0x0003, 0x0103, 0x0203},
      product_ids = {0x004B, 0x0019, 0x0013, 0x0008}
    },
    CONFIGURATION = {
      {parameter_number = 101, size = 4, configuration_value = 8},   -- energy in kWh
      {parameter_number = 111, size = 4, configuration_value = 300}, -- every 5 min
      {parameter_number = 102, size = 4, configuration_value = 0},
      {parameter_number = 103, size = 4, configuration_value = 0}
    }
  }
}

local configurations = {}

configurations.get_device_configuration = function(zw_device)
  for _, device in pairs(devices) do
    if zw_device:id_match(
      device.MATCHING_MATRIX.mfrs,
      device.MATCHING_MATRIX.product_types,
      device.MATCHING_MATRIX.product_ids) then
      return device.CONFIGURATION
    end
  end
  return nil
end

return configurations
