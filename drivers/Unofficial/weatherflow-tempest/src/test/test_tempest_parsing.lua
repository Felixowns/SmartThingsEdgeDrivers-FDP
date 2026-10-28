-- Unit tests for the pure Tempest decoding helpers (no SmartThings runtime needed).
-- Run from the driver's src/ directory:  lua test/test_tempest_parsing.lua
local tempest = require("tempest")

local function near(a, b, eps)
  return math.abs(a - b) <= (eps or 1e-6)
end

-- Sample obs_st from the WeatherFlow UDP v171 reference, with a strike count of 3.
local sample = {
  serial_number = "ST-00000512",
  type = "obs_st",
  hub_sn = "HB-00013030",
  obs = { { 1588948614, 0.18, 0.22, 0.27, 144, 6, 1017.57, 22.37, 50.26, 328, 0.03, 3, 0.000000, 0, 0, 3, 2.410, 1 } },
  firmware_revision = 129,
}

local r = tempest.parse_obs_st(sample)
assert(r, "obs_st should parse")
assert(r.epoch == 1588948614)
assert(near(r.wind_avg, 0.22))
assert(near(r.pressure, 1017.57))
assert(near(r.temperature, 22.37))
assert(near(r.humidity, 50.26))
assert(r.illuminance == 328)
assert(near(r.uv, 0.03))
assert(r.rain_minute == 0 and r.rain_rate == 0)
assert(r.strike_count == 3, "index 16 is the lightning strike count")
assert(near(r.battery, 2.410), "battery must come from index 17, not the strike count")
assert(r.report_interval == 1)

-- Missing / null fields decode to nil instead of erroring.
local partial = tempest.parse_obs_st({ obs = { { 1, nil, nil, nil, nil, nil, "bad" } } })
assert(partial and partial.pressure == nil and partial.battery == nil)
assert(tempest.parse_obs_st({}) == nil)
assert(tempest.parse_obs_st({ obs = {} }) == nil)

-- Precipitation intensity (rate in mm/h).
assert(tempest.precip_intensity(0, 0) == "none")
assert(tempest.precip_intensity(0, 1) == "possiblePrecipitation")
assert(tempest.precip_intensity(0.01 * 60, 1) == "light")    -- 0.01 mm/min
assert(tempest.precip_intensity(0.08 * 60, 1) == "moderate") -- 0.08 mm/min = 4.8 mm/h
assert(tempest.precip_intensity(0.2 * 60, 1) == "heavy")     -- 12 mm/h
assert(tempest.precip_intensity(1.0 * 60, 1) == "violent")   -- 60 mm/h
assert(tempest.precip_intensity(nil, nil) == "none")

-- Battery percentage.
assert(tempest.battery_percent(2.80) == 100)
assert(tempest.battery_percent(3.00) == 100)
assert(tempest.battery_percent(2.35) == 0)
assert(tempest.battery_percent(2.00) == 0)
assert(tempest.battery_percent(2.575) == 50)
assert(math.type(tempest.battery_percent(2.41)) == "integer")
assert(tempest.battery_percent(nil) == nil)

-- Dew point: 20 C / 50 % RH is about 9.3 C.
assert(near(tempest.dew_point_c(20, 50), 9.26, 0.05))
assert(near(tempest.dew_point_c(22.37, 100), 22.37, 0.01))
assert(tempest.dew_point_c(20, 0) == nil)

-- Sea-level pressure.
assert(tempest.sea_level_pressure(1000, 0, 20) == 1000)
local slp = tempest.sea_level_pressure(1000, 300, 15)
assert(slp > 1034 and slp < 1038, "300 m adds about 36 mbar, got " .. slp)

-- Unit conversions.
assert(near(tempest.convert_pressure(1013.25, "inHg"), 29.92, 0.01))
assert(tempest.convert_pressure(1013.25, "mbar") == 1013.25)
assert(near(tempest.convert_wind(10, "mph"), 22.37, 0.01))
assert(near(tempest.convert_wind(10, "km/h"), 36))
assert(tempest.unit_system("metric").pressure == "mbar")
assert(tempest.unit_system(nil).pressure == "inHg")

-- Rounding.
assert(tempest.round(22.37, 1) == 22.4)
assert(math.type(tempest.round(50.26, 0)) == "integer")

-- Serial filter.
assert(tempest.is_tempest_serial("ST-00000512"))
assert(not tempest.is_tempest_serial("HB-00013030"))
assert(not tempest.is_tempest_serial(nil))

print("test_tempest_parsing: all tests passed")
