-- Third Reality smart plugs handled by the third-reality sub-driver.
-- Source: zigbee-herdsman-converters src/devices/third_reality.ts (the definitions behind zigbee2mqtt.io)
--
-- gen = 2 : 3RSP02028BZ  -> 0xFF03 mfg code 0x1233, fixed scaling (Z2M overrides the plug's reported divisors)
-- gen = 3 : 3RSP02064Z and its white labels -> 0xFF03 mfg code 0x1407, scaling read from the plug
--
-- Only 3RSP02028BZ and 3RSP02064Z have fingerprints in fingerprints.yml. The Gen 3 white labels are listed
-- here so they are handled correctly if they are ever added there (Z2M treats them as the same device).

return {
  ["3RSP02028BZ"] = { gen = 2, profile = "third-reality-plug-gen2" },
  ["3RSP02064Z"]  = { gen = 3, profile = "third-reality-plug-gen3" }, -- Smart Plug Gen3
  ["3RSPU01080Z"] = { gen = 3, profile = "third-reality-plug-gen3" }, -- Smart Plug UZ1
  ["3RSPE02065Z"] = { gen = 3, profile = "third-reality-plug-gen3" }, -- Smart Plug E3
  ["3RSP0186Z"]   = { gen = 3, profile = "third-reality-plug-gen3" }, -- Smart Plug C1
  ["3RSPJ0187Z"]  = { gen = 3, profile = "third-reality-plug-gen3" }, -- Smart Plug J1
}
