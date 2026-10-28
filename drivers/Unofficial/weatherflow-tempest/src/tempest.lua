-- Pure helpers for decoding WeatherFlow Tempest UDP messages.
-- No SmartThings dependencies, so this module can be unit tested with plain Lua.
--
-- Reference: WeatherFlow Tempest UDP API v171. The spec numbers obs_st fields
-- from 0; Lua arrays start at 1, so every index below is spec index + 1.

local M = {}

M.OBS = {
  EPOCH = 1,
  WIND_LULL = 2,        -- m/s
  WIND_AVG = 3,         -- m/s
  WIND_GUST = 4,        -- m/s
  WIND_DIR = 5,         -- degrees
  WIND_INTERVAL = 6,    -- s
  PRESSURE = 7,         -- station pressure, mbar
  TEMPERATURE = 8,      -- C
  HUMIDITY = 9,         -- %
  ILLUMINANCE = 10,     -- lux
  UV = 11,              -- index
  SOLAR_RADIATION = 12, -- W/m^2
  RAIN_MINUTE = 13,     -- mm over the previous minute
  PRECIP_TYPE = 14,     -- 0 none, 1 rain, 2 hail, 3 rain + hail
  STRIKE_DISTANCE = 15, -- km
  STRIKE_COUNT = 16,
  BATTERY = 17,         -- V
  REPORT_INTERVAL = 18, -- minutes
}

M.MAX_LUX = 100000 -- illuminanceMeasurement schema maximum

-- Tempest battery: ~2.80 V when full; the device sheds features below ~2.41 V
-- and is effectively empty around 2.35 V.
M.BATTERY_EMPTY_V = 2.35
M.BATTERY_FULL_V = 2.80

-- Rain-rate thresholds (mm/h), standard meteorological bands.
M.RATE_LIGHT_MAX = 2.5
M.RATE_MODERATE_MAX = 7.6
M.RATE_HEAVY_MAX = 50

-- Returns v if it is a finite number, else nil (JSON null, strings, NaN).
function M.num(v)
  if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
    return nil
  end
  return v
end

function M.round(v, places)
  local mult = 10 ^ (places or 0)
  local r = math.floor(v * mult + 0.5) / mult
  if (places or 0) == 0 then
    return math.tointeger(r) or r
  end
  return r
end

function M.clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- Precipitation intensity enum for precipitationSensor.precipitationIntensity.
-- rate_mmh: rain rate in mm/h; precip_type: Tempest precip type code (optional).
function M.precip_intensity(rate_mmh, precip_type)
  rate_mmh = M.num(rate_mmh) or 0
  if rate_mmh <= 0 then
    if M.num(precip_type) and precip_type > 0 then
      return "possiblePrecipitation"
    end
    return "none"
  elseif rate_mmh < M.RATE_LIGHT_MAX then
    return "light"
  elseif rate_mmh < M.RATE_MODERATE_MAX then
    return "moderate"
  elseif rate_mmh < M.RATE_HEAVY_MAX then
    return "heavy"
  end
  return "violent"
end

function M.battery_percent(volts)
  volts = M.num(volts)
  if not volts then return nil end
  local pct = (volts - M.BATTERY_EMPTY_V) / (M.BATTERY_FULL_V - M.BATTERY_EMPTY_V) * 100
  return M.round(M.clamp(pct, 0, 100), 0)
end

-- Magnus-formula dew point in C.
function M.dew_point_c(temp_c, rh)
  temp_c, rh = M.num(temp_c), M.num(rh)
  if not temp_c or not rh or rh <= 0 then return nil end
  local a, b = 17.625, 243.04
  local gamma = math.log(rh / 100) + (a * temp_c) / (b + temp_c)
  return b * gamma / (a - gamma)
end

-- Reduce station pressure (mbar) to sea level using station elevation (m)
-- and air temperature (C). Returns station pressure unchanged when elevation is 0.
function M.sea_level_pressure(station_mbar, elevation_m, temp_c)
  station_mbar = M.num(station_mbar)
  if not station_mbar then return nil end
  elevation_m = M.num(elevation_m) or 0
  if elevation_m == 0 then return station_mbar end
  temp_c = M.num(temp_c) or 15
  local lapse = 0.0065 * elevation_m
  return station_mbar * (1 - lapse / (temp_c + lapse + 273.15)) ^ -5.257
end

M.UNIT_SYSTEMS = {
  imperial = { pressure = "inHg", pressure_places = 2, wind = "mph" },
  metric = { pressure = "mbar", pressure_places = 1, wind = "km/h" },
}

function M.unit_system(name)
  return M.UNIT_SYSTEMS[name] or M.UNIT_SYSTEMS.imperial
end

function M.convert_pressure(mbar, unit)
  if unit == "inHg" then return mbar * 0.0295300 end
  if unit == "kPa" then return mbar / 10 end
  return mbar -- mbar / hPa
end

function M.convert_wind(ms, unit)
  if unit == "mph" then return ms * 2.236936 end
  if unit == "km/h" then return ms * 3.6 end
  if unit == "knots" then return ms * 1.943844 end
  return ms
end

-- Decode an obs_st payload into named readings (each nil if missing/invalid).
function M.parse_obs_st(payload)
  if type(payload) ~= "table" or type(payload.obs) ~= "table" then return nil end
  local obs = payload.obs[1]
  if type(obs) ~= "table" then return nil end
  local I = M.OBS
  local rain_minute = M.num(obs[I.RAIN_MINUTE])
  return {
    epoch = M.num(obs[I.EPOCH]),
    wind_avg = M.num(obs[I.WIND_AVG]),
    wind_gust = M.num(obs[I.WIND_GUST]),
    wind_dir = M.num(obs[I.WIND_DIR]),
    pressure = M.num(obs[I.PRESSURE]),
    temperature = M.num(obs[I.TEMPERATURE]),
    humidity = M.num(obs[I.HUMIDITY]),
    illuminance = M.num(obs[I.ILLUMINANCE]),
    uv = M.num(obs[I.UV]),
    solar_radiation = M.num(obs[I.SOLAR_RADIATION]),
    rain_minute = rain_minute,
    rain_rate = rain_minute and rain_minute * 60 or nil, -- mm/h
    precip_type = M.num(obs[I.PRECIP_TYPE]),
    strike_distance = M.num(obs[I.STRIKE_DISTANCE]),
    strike_count = M.num(obs[I.STRIKE_COUNT]),
    battery = M.num(obs[I.BATTERY]),
    report_interval = M.num(obs[I.REPORT_INTERVAL]),
  }
end

-- Only Tempest sensors (not hubs "HB-" or legacy Air/Sky units) become devices.
function M.is_tempest_serial(serial)
  return type(serial) == "string" and serial:sub(1, 3) == "ST-"
end

return M
