-- Gledopto controllers handled by the gledopto sub-driver.
-- profile:     gledopto-* = transition/auto-off/effects only (older firmware rejects the ZCL start-up attributes)
--              gledopto-pro-* = also power-on behavior / brightness / color temp (P models per Zigbee2MQTT)
--              the Gledopto profile the device is moved to (keeps the per-device color temp range)
-- min_kelvin / max_kelvin: the device's white range, used for clamping and the initial colorTemperatureRange

return {
  ["GLEDOPTO"] = {
    ["GL-C-008"]  = { profile = "gledopto-rgbw-2700K-6500K", min_kelvin = 2700, max_kelvin = 6500 },
    ["GL-C-007"]  = { profile = "gledopto-rgbw-2000K-6500K", min_kelvin = 2000, max_kelvin = 6500 },
    ["GL-C-007S"] = { profile = "gledopto-rgbw-2000K-6500K", min_kelvin = 2000, max_kelvin = 6500 },
    ["GL-C-007P"] = { profile = "gledopto-pro-rgbw-2000K-6500K", min_kelvin = 2000, max_kelvin = 6500 },
  }
}
