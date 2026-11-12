-- Samsung multiroom speaker HTTP (UIC, port 55001) commands.
-- Based on the SmartThings samsung-audio driver (Apache 2.0), reworked so that:
--   * every request has a short timeout (a dead speaker can't stall the driver)
--   * "reachable" is decided by the speaker answering at all, not by which
--     fields happen to be in the answer (the old cause of false "offline")

local cosock = require "cosock"
local http = cosock.asyncify "socket.http"
local ltn12 = require "ltn12"
local xml2lua = require "xml2lua"
local xml_handler = require "xmlhandler.tree"
local log = require "log"

http.TIMEOUT = 4

local PORT = 55001

local Command = {}

-- percent-encode the UIC xml the same way the original driver's working URLs were encoded
local function enc(s)
  return (string.gsub(s, "[^%w%-%._~/=!%[%]]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

-- xml2lua can hand back text as a string or wrapped in a table (attributes / CDATA)
local function txt(v)
  if type(v) == "table" then v = v[1] end
  if type(v) == "string" or type(v) == "number" then return tostring(v) end
  return nil
end
Command.txt = txt

local function get(ip, path)
  if not ip then return nil, "no ip" end
  local url = string.format("http://%s:%d%s", ip, PORT, path)
  local chunks = {}
  local ok, code = http.request {
    url = url,
    method = "GET",
    sink = ltn12.sink.table(chunks),
  }
  if not ok then
    log.debug(string.format("[%s] request failed: %s", ip, tostring(code)))
    return nil, code
  end
  if code ~= 200 then
    log.debug(string.format("[%s] HTTP %s", ip, tostring(code)))
    return nil, "http " .. tostring(code)
  end
  local body = table.concat(chunks)
  if body == "" then return nil, "empty body" end

  local handler = xml_handler:new()
  local parser = xml2lua.parser(handler)
  local parsed = pcall(parser.parse, parser, body)
  -- /UIC replies are wrapped in <UIC>, /CPM (streaming player) replies in <CPM>
  local root = handler.root and (handler.root.UIC or handler.root.CPM)
  if not parsed or type(root) ~= "table" then
    return nil, "unparseable response"
  end
  return root
end

--- Send a UIC command. Returns the UIC table and its <response> table (may be empty).
local function uic(ip, xml)
  local root, err = get(ip, "/UIC?cmd=" .. enc(xml))
  if not root then return nil, nil, err end
  local resp = root.response
  if type(resp) ~= "table" then resp = {} end
  return root, resp
end

--- Content-provider (Spotify, TuneIn, ...) player lives on a separate /CPM endpoint
local function cpm(ip, xml)
  local root, err = get(ip, "/CPM?cmd=" .. enc(xml))
  if not root then return nil, nil, err end
  local resp = root.response
  if type(resp) ~= "table" then resp = {} end
  return root, resp
end

local function result_ok(resp)
  local r = resp and resp._attr and resp._attr.result
  return r ~= "ng"
end

local function normalize_playstatus(ps)
  ps = ps and string.lower(ps) or ""
  if ps == "play" or ps == "resume" or ps == "playing" then return "playing" end
  if ps == "pause" or ps == "paused" then return "paused" end
  return "stopped"
end

--- @return table|nil {playback = "playing"|"paused"|"stopped", raw = string|nil}; nil only if unreachable
--- @return table|nil {playback, raw, source = "cp"|nil, cpname}; nil only if unreachable
function Command.get_play_status(ip)
  local root, resp = uic(ip, "<name>GetPlayStatus</name>")
  if not root then return nil end
  local raw = txt(resp.playstatus)
  local submode = txt(resp.submode)
  local out = { playback = normalize_playstatus(raw), raw = raw, submode = submode, func = txt(resp["function"]) }
  -- streaming apps (submode "cp"): the UIC reply has no play state; ask the CP player instead
  if submode == "cp" or raw == nil then
    local croot, cresp = cpm(ip, "<name>GetPlayStatus</name>")
    if croot then
      local craw = txt(cresp.playstatus)
      if craw or txt(cresp.submode) == "cp" then
        out.source = "cp"
        out.cpname = txt(cresp.cpname)
        out.raw = craw
        out.playback = normalize_playstatus(craw)
      end
    end
  end
  return out
end

--- Multiroom group membership. Grouped speakers report mode "aasync" plus the group leader's MAC.
--- @return table|nil {mode, main_mac (uppercase, no colons) or nil}; nil if unreachable
function Command.get_group(ip)
  local root, resp = uic(ip, "<name>GetAcmMode</name>")
  if not root then return nil end
  local out = { mode = txt(resp.acmmode) }
  for k, v in pairs(resp) do
    local val = txt(v)
    if val and k ~= "_attr" then
      local mac = string.match(val, "^(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)$")
      if mac then
        out.main_mac = string.upper((string.gsub(mac, ":", "")))
      elseif not out.mode and (val == "aasync" or val == "none" or val == "sync") then
        out.mode = val
      end
    end
  end
  return out
end

--- Now-playing info from the content-provider player (Spotify etc.)
function Command.get_cp_info(ip)
  local root, resp = cpm(ip, "<name>GetRadioInfo</name>")
  if not root then return nil end
  local title = txt(resp.title)
  if not title or title == "" then return nil end
  return {
    title = title,
    artist = txt(resp.artist),
    album = txt(resp.album),
    art = txt(resp.thumbnail),
    length = tonumber(txt(resp.tracklength) or txt(resp.timelength) or ""),
    cpname = txt(resp.cpname),
  }
end

function Command.get_volume(ip)
  local root, resp = uic(ip, "<name>GetVolume</name>")
  if not root then return nil end
  return tonumber(txt(resp.volume))
end

function Command.set_volume(ip, level)
  level = math.floor(math.min(100, math.max(0, tonumber(level) or 0)))
  local root, resp = uic(ip, string.format(
    '<pwron>on</pwron><name>SetVolume</name><p type="dec" name="volume" val="%d"></p>', level))
  if not root then return nil end
  return tonumber(txt(resp.volume)) or level
end

--- @return boolean|nil true = muted
function Command.get_mute(ip)
  local root, resp = uic(ip, "<name>GetMute</name>")
  if not root then return nil end
  local m = txt(resp.mute)
  if m == nil then return nil end
  return m ~= "off"
end

function Command.set_mute(ip, muted)
  local root, resp = uic(ip, string.format(
    '<name>SetMute</name><p type="str" name="mute" val="%s"></p>', muted and "on" or "off"))
  if not root then return nil end
  local m = txt(resp.mute)
  if m == nil then return muted end
  return m ~= "off"
end

--- action: "resume" | "pause"
function Command.playback(ip, action, cp)
  if cp then
    local root, resp = cpm(ip, string.format(
      '<name>SetPlaybackControl</name><p type="str" name="playbackcontrol" val="%s"></p>',
      action == "resume" and "play" or action))
    if root and result_ok(resp) then return true end
    log.debug(string.format("[%s] CPM playback %s not accepted, trying UIC", ip, action))
  end
  local root = uic(ip, string.format(
    '<pwron>on</pwron><name>SetPlaybackControl</name><p type="str" name="playbackcontrol" val="%s"></p>', action))
  return root ~= nil
end

--- mode: "next" | "previous"
function Command.trick(ip, mode, cp)
  if cp then
    local root, resp = cpm(ip, mode == "next" and "<name>SetSkipCurrentTrack</name>" or "<name>SetPreviousTrack</name>")
    if root and result_ok(resp) then return true end
    log.debug(string.format("[%s] CPM %s not accepted, trying UIC", ip, mode))
  end
  local root = uic(ip, string.format(
    '<name>SetTrickMode</name><p type="str" name="trickmode" val="%s"></p>', mode))
  return root ~= nil
end

--- Same mapping as the original driver ("on" -> power on, "off" -> power off)
function Command.power(ip, on)
  local root = uic(ip, string.format(
    '<name>SetStandbyMode</name><p type="str" name="mode" val="%s"/>', on and "on" or "off"))
  return root ~= nil
end

--- @return string|nil speaker name ("" if the speaker answered without one); nil if unreachable
function Command.get_speaker_name(ip)
  local root, resp = uic(ip, "<name>GetSpkName</name>")
  if not root then return nil end
  return txt(resp.spkname) or ""
end

--- Best-effort current track info. Returns {title, artist, album} or nil.
function Command.get_track_info(ip)
  for _, name in ipairs({ "GetMusicInfo", "GetRadioInfo" }) do
    local root, resp = uic(ip, "<name>" .. name .. "</name>")
    if not root then return nil end
    local title = txt(resp.title)
    if title and title ~= "" then
      return { title = title, artist = txt(resp.artist), album = txt(resp.album) }
    end
  end
  return nil
end

--- Play a URL (audioNotification). Kept identical to the original driver's request format.
function Command.play_url(ip, uri)
  local http_uri = string.gsub(uri, "^https://", "http://")
  -- the URL sits inside the cmd= query value: escape characters that would end/split it there
  local safe = string.gsub(http_uri, "[%%&?#+= ]", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  local path = "/UIC?cmd=%3Cpwron%3Eon%3C/pwron%3E%3Cname%3ESetUrlPlayback%3C/name%3E%3Cp%20type=%22cdata%22%20name=%22url%22%20val=%22empty%22%3E%3C![CDATA[" .. safe .. "]]%3E%3C/p%3E%3Cp%20type=%22dec%22%20name=%22buffersize%22%20val=%220%22/%3E%3Cp%20type=%22dec%22%20name=%22seektime%22%20val=%220%22/%3E%3Cp%20type=%22dec%22%20name=%22resume%22%20val=%221%22/%3E"
  local root, err = get(ip, path)
  if not root then return false, nil, err, http_uri end
  local resp = type(root.response) == "table" and root.response or {}
  local result = resp._attr and resp._attr.result or "unknown"
  return result ~= "ng", result, nil, http_uri
end

---------------------------------------------------------------------------------------------------
-- input source, shuffle / repeat, play position, EQ
-- Command names follow the Samsung multiroom API; replies are parsed loosely and anything
-- unexpected is logged at debug level so it can be adjusted.
---------------------------------------------------------------------------------------------------

-- speaker "function" <-> SmartThings mediaInputSource value
Command.FUNC_TO_SOURCE = {
  wifi = "wifi", bt = "bluetooth", aux = "aux", optical = "optical",
  hdmi = "HDMI", hdmi1 = "HDMI1", hdmi2 = "HDMI2", usb = "USB",
}
Command.SOURCE_TO_FUNC = {}
for f, src in pairs(Command.FUNC_TO_SOURCE) do Command.SOURCE_TO_FUNC[src] = f end

local function dump_keys(resp)
  local keys = {}
  for k, v in pairs(resp or {}) do
    if k ~= "_attr" then table.insert(keys, k .. "=" .. tostring(txt(v))) end
  end
  return table.concat(keys, ", ")
end

--- current input ("wifi", "bt", "optical", ...) for speakers that don't answer GetPlayStatus
function Command.get_func(ip)
  local root, resp = uic(ip, "<name>GetFunc</name>")
  if not root then return nil end
  return txt(resp["function"])
end

function Command.set_func(ip, func)
  local root, resp = uic(ip, string.format('<name>SetFunc</name><p type="str" name="function" val="%s"></p>', func))
  return root ~= nil and result_ok(resp)
end

--- @return boolean|nil true = shuffle on
function Command.get_shuffle(ip, cp)
  local root, resp = (cp and cpm or uic)(ip, "<name>GetShuffleMode</name>")
  if not root then return nil end
  local v = txt(resp.shuffle) or txt(resp.shufflemode)
  if v == nil then
    log.debug(string.format("[%s] GetShuffleMode reply: %s", ip, dump_keys(resp)))
    return nil
  end
  return v == "on"
end

function Command.set_shuffle(ip, on, cp)
  local root, resp = (cp and cpm or uic)(ip, string.format(
    '<name>SetShuffleMode</name><p type="str" name="shufflemode" val="%s"></p>', on and "on" or "off"))
  return root ~= nil and result_ok(resp)
end

--- @return "one"|"all"|"off"|nil
function Command.get_repeat(ip, cp)
  local root, resp = (cp and cpm or uic)(ip, "<name>GetRepeatMode</name>")
  if not root then return nil end
  local v = txt(resp["repeat"]) or txt(resp.repeatmode)
  if v == nil then
    log.debug(string.format("[%s] GetRepeatMode reply: %s", ip, dump_keys(resp)))
    return nil
  end
  return v
end

function Command.set_repeat(ip, mode, cp)
  local root, resp = (cp and cpm or uic)(ip, string.format(
    '<name>SetRepeatMode</name><p type="str" name="repeatmode" val="%s"></p>', mode))
  return root ~= nil and result_ok(resp)
end

--- @return table|nil {elapsed = seconds, length = seconds|nil}
function Command.get_play_time(ip, cp)
  local root, resp = (cp and cpm or uic)(ip, "<name>GetCurrentPlayTime</name>")
  if not root then return nil end
  local elapsed = tonumber(txt(resp.playtime) or "")
  if not elapsed then
    log.debug(string.format("[%s] GetCurrentPlayTime reply: %s", ip, dump_keys(resp)))
    return nil
  end
  return { elapsed = math.floor(elapsed), length = tonumber(txt(resp.timelength) or "") }
end

--- @return table|nil {index, name} of the current EQ preset
function Command.get_eq(ip)
  local root, resp = uic(ip, "<name>GetCurrentEQMode</name>")
  if not root then return nil end
  local out = { index = tonumber(txt(resp.presetindex) or ""), name = txt(resp.presetname) }
  if out.index == nil and out.name == nil then
    log.debug(string.format("[%s] GetCurrentEQMode reply: %s", ip, dump_keys(resp)))
    return nil
  end
  return out
end

--- @return table|nil list of {index, name}
function Command.get_eq_presets(ip)
  local root, resp = uic(ip, "<name>Get7BandEQList</name>")
  if not root then return nil end
  local pl = resp.presetlist
  local presets = type(pl) == "table" and pl.preset or nil
  if type(presets) == "table" and presets.presetname then presets = { presets } end -- single entry
  local list = {}
  for _, p in ipairs(type(presets) == "table" and presets or {}) do
    local name, index = txt(p.presetname), tonumber(txt(p.presetindex) or "")
    if name and index then table.insert(list, { index = index, name = name }) end
  end
  if #list == 0 then
    log.debug(string.format("[%s] Get7BandEQList reply: %s", ip, dump_keys(resp)))
    return nil
  end
  return list
end

function Command.set_eq_preset(ip, index)
  local root, resp = uic(ip, string.format(
    '<name>Set7bandEQMode</name><p type="dec" name="presetindex" val="%d"></p>', index))
  return root ~= nil and result_ok(resp)
end

return Command
