-- Samsung Audio Group (Unofficial)
--
-- One SmartThings device ("Samsung Speakers") that holds every Samsung multiroom
-- speaker on the network as a component:
--   main       -> controls all speakers at once, shows a summary
--   speaker1.. -> each individual speaker
--
-- Based on the SmartThings samsung-audio driver (Apache 2.0).

local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local log = require "log"
local command = require "command"
local disco = require "disco"
local cosock = require "cosock"
local json = require "st.json"
local custom_caps = require "custom_caps"

-- custom EQ preset capability (only when make_profiles.py was run with a namespace)
local EQ_PRESET_ID = custom_caps.namespace and (custom_caps.namespace .. ".eqPreset") or nil

-- Preset names as written in capabilities/eqPreset.presentation.json. Speakers report them in
-- different cases (soundbars: "NONE", "POP", ...), so names are matched ignoring case and sent to
-- SmartThings in the app's spelling.
local APP_PRESETS = { "None", "Pop", "Jazz", "Classic" }
local function app_preset_name(name)
  local l = string.lower(name or "")
  for _, p in ipairs(APP_PRESETS) do
    if string.lower(p) == l then return p end
  end
  return name
end

local function custom_cap(id)
  if not id then return nil end
  local ok, cap = pcall(function() return capabilities[id] end)
  if ok and cap then return cap end
  return nil
end

local HUB_DNI = "samsung-audio-group"
local PROFILE_PREFIX = "samsung-audio-group-"
local MAX_SPEAKERS = 16
local FAILS_BEFORE_UNREACHABLE = 3 -- consecutive failed polls before a speaker counts as unreachable
local RESCAN_MIN_INTERVAL = 300    -- seconds between automatic re-discovery runs
local PERIODIC_RESCAN = 1800       -- look for new speakers / IP changes every 30 min
local DEFAULT_POLL = 60
local VOL_STEP = 5

local F_SPEAKERS = "speakers"      -- persisted: list of {key, ip, name, model}
local F_STATE = "speaker_state"    -- runtime: key -> state table
local F_LAST_SCAN = "last_scan"
local F_PROFILE = "profile_name"
local F_POLL_TIMER = "poll_timer"
local F_SCAN_TIMER = "scan_timer"
local F_EMITTED = "emitted"        -- runtime: last value sent per component/attribute

local pending_speakers = nil -- speakers found by discovery before the device exists
local hub_ip = nil

local function remember_hub_ip(driver)
  local env = driver and driver.environment_info
  if env and env.hub_ipv4 then hub_ip = env.hub_ipv4 end
end

--- SSDP first, then a direct subnet sweep if multicast found nothing new
local function find_speakers(known_ips)
  local found = disco.scan(5)
  if #found == 0 then
    local skip = {}
    for _, ip in ipairs(known_ips or {}) do skip[ip] = true end
    found = disco.sweep(hub_ip, skip)
  end
  return found
end

---------------------------------------------------------------------------------------------------
-- speaker bookkeeping
---------------------------------------------------------------------------------------------------

-- persisted fields come back as proxy tables (# reports 0), so always work on a plain copy
local function get_speakers(device)
  local stored = device:get_field(F_SPEAKERS)
  local list = {}
  if type(stored) ~= "table" then return list end
  local i = 1
  while stored[i] ~= nil do
    local s = stored[i]
    table.insert(list, { key = s.key, ip = s.ip, name = s.name, model = s.model })
    i = i + 1
  end
  return list
end

local log_rename_body -- forward declaration

local function sort_key(s)
  return string.lower(s.name or "") .. "\0" .. (s.ip or "")
end

--- speakers are stored (and shown as components) in alphabetical order
local function save_speakers(device, list)
  table.sort(list, function(a, b) return sort_key(a) < sort_key(b) end)
  device:set_field(F_SPEAKERS, list, { persist = true })
  log_rename_body(device, list)
end

log_rename_body = function(device, list)
  -- component headers can only be renamed from outside the driver (app / SmartThings API).
  -- Log a ready-made body so the user can label speaker1..N with the speaker names.
  local ips, comps = {}, {}
  for i, s in ipairs(list) do
    table.insert(ips, s.ip)
    table.insert(comps, { id = "speaker" .. i, label = s.name })
  end
  log.info(string.format("speaker list (%d): %s", #ips, table.concat(ips, ", ")))
  local ok, body = pcall(json.encode, { components = comps })
  if ok then
    log.info("component rename body for device " .. tostring(device.id) .. ": " .. body)
  end
end

local function state_for(device, key)
  local all = device:get_field(F_STATE)
  if not all then
    all = {}
    device:set_field(F_STATE, all)
  end
  all[key] = all[key] or { fails = 0, polled = false, on = true }
  return all[key]
end

local function is_reachable(st)
  return st.polled and st.fails < FAILS_BEFORE_UNREACHABLE
end

--- merge a discovered speaker into list; returns true if the list changed
local function merge_speaker(device, list, found)
  local key = found.id or ("ip:" .. found.ip)
  for _, s in ipairs(list) do
    local same = (s.key == key)
      or (found.id and s.ip == found.ip and string.sub(s.key, 1, 3) == "ip:")
      or (s.ip == found.ip and s.name == found.name) -- same speaker reported with another UDN
    if same then
      if s.key ~= key and string.sub(s.key, 1, 3) ~= "ip:" then key = s.key end -- keep the established id
      local changed = (s.ip ~= found.ip) or (s.key ~= key) or (s.name ~= found.name)
      if s.ip ~= found.ip then
        log.info(string.format("speaker %s moved %s -> %s", s.name, s.ip, found.ip))
        state_for(device, key).fails = 0
      end
      s.key, s.ip, s.name, s.model = key, found.ip, found.name, found.model
      return changed
    end
  end
  if #list >= MAX_SPEAKERS then
    log.warn(string.format("ignoring %s: limit of %d speakers reached", found.name, MAX_SPEAKERS))
    return false
  end
  log.info(string.format("adding speaker %d: %s (%s)", #list + 1, found.name, found.ip))
  table.insert(list, { key = key, ip = found.ip, name = found.name, model = found.model })
  return true
end

local function parse_ips(raw)
  local ips = {}
  for ip in string.gmatch(raw or "", "[^,;%s]+") do
    if string.match(ip, "^%d+%.%d+%.%d+%.%d+$") then table.insert(ips, ip) end
  end
  return ips
end

local function excluded_set(device)
  local set = {}
  for _, ip in ipairs(parse_ips(device.preferences and device.preferences.excludedIps)) do set[ip] = true end
  return set
end

--- IPs from the "always included" setting, minus any that are excluded
local function manual_ips(device)
  local excluded = excluded_set(device)
  local ips = {}
  for _, ip in ipairs(parse_ips(device.preferences and device.preferences.speakerIps)) do
    if not excluded[ip] then table.insert(ips, ip) end
  end
  return ips
end

--- drop saved speakers whose IP is excluded; returns true if the list changed
--- remove duplicate entries (same IP + same name); keeps the first non "ip:" id
local function dedupe(list)
  local changed = false
  local i = 1
  while i <= #list do
    local a = list[i]
    local dup_of = nil
    for j = 1, i - 1 do
      if list[j].ip == a.ip and list[j].name == a.name then dup_of = j; break end
    end
    if dup_of then
      if string.sub(list[dup_of].key, 1, 3) == "ip:" and string.sub(a.key, 1, 3) ~= "ip:" then
        list[dup_of].key = a.key
      end
      log.info(string.format("removing duplicate entry for %s (%s)", a.name, a.ip))
      table.remove(list, i)
      changed = true
    else
      i = i + 1
    end
  end
  return changed
end

local function prune_excluded(device, list)
  local excluded = excluded_set(device)
  local changed = false
  for i = #list, 1, -1 do
    if excluded[list[i].ip] then
      log.info(string.format("removing excluded speaker %s (%s)", list[i].name, list[i].ip))
      table.remove(list, i)
      changed = true
    end
  end
  return changed
end

---------------------------------------------------------------------------------------------------
-- profile / event helpers
---------------------------------------------------------------------------------------------------

local function component_count(device)
  local n = 0
  for _ in pairs(device.profile.components) do n = n + 1 end
  return n
end

local function ensure_profile(device)
  local list = get_speakers(device)
  local want = PROFILE_PREFIX .. math.max(1, math.min(#list, MAX_SPEAKERS))
  if device:get_field(F_PROFILE) ~= want or component_count(device) ~= math.max(1, #list) + 1 then
    log.info("switching profile to " .. want)
    device:set_field(F_PROFILE, want, { persist = true })
    device:try_update_metadata({ profile = want })
  end
end

--- Send an event only when its value changed. Re-sending every value on every poll
--- (~85 events/min for 12 speakers) gets the device throttled and the app stops updating.
local function emit(device, comp_id, event)
  local comp = device.profile.components[comp_id]
  if not comp then return end
  local cache = device:get_field(F_EMITTED)
  if not cache then
    cache = {}
    device:set_field(F_EMITTED, cache)
  end
  local key, val
  local ok = pcall(function()
    key = comp_id .. "/" .. event.capability.ID .. "/" .. event.attribute.NAME
    val = json.encode(event.state or event.value)
  end)
  if ok and key and val and cache[key] == val then return end
  device:emit_component_event(comp, event)
  if ok and key then cache[key] = val end
end

--- forget what was sent so the next emit_all re-sends everything (after init / profile change)
local function reset_emitted(device)
  device:set_field(F_EMITTED, {})
end

--- forget what was sent for one component, so its next emits always go out. Used after a
--- command: the app waits for the device to report state, even when nothing changed.
local function forget_component(device, comp_id)
  local cache = device:get_field(F_EMITTED)
  if not cache then return end
  local prefix = comp_id .. "/"
  for k in pairs(cache) do
    if string.sub(k, 1, #prefix) == prefix then cache[k] = nil end
  end
end

local function emit_supported_commands(device)
  for comp_id, _ in pairs(device.profile.components) do
    emit(device, comp_id, capabilities.mediaPlayback.supportedPlaybackCommands({
      capabilities.mediaPlayback.commands.play.NAME,
      capabilities.mediaPlayback.commands.pause.NAME,
      capabilities.mediaPlayback.commands.stop.NAME,
    }))
    emit(device, comp_id, capabilities.mediaTrackControl.supportedTrackControlCommands({
      capabilities.mediaTrackControl.commands.nextTrack.NAME,
      capabilities.mediaTrackControl.commands.previousTrack.NAME,
    }))
  end
end

local function playback_event(pb)
  if pb == "playing" then return capabilities.mediaPlayback.playbackStatus.playing() end
  if pb == "paused" then return capabilities.mediaPlayback.playbackStatus.paused() end
  return capabilities.mediaPlayback.playbackStatus.stopped()
end

--- inputs offered in the app; soundbars have more than the WAM speakers. A soundbar reports
--- either "HW-MS750" or "SPK-WAM750" depending on which UPnP description was read.
local function is_soundbar(s)
  local model, name = s.model or "", string.lower(s.name or "")
  return string.match(model, "^HW%-") ~= nil or string.find(model, "WAM750", 1, true) ~= nil
    or string.find(name, "soundbar", 1, true) ~= nil
end

local function input_sources_for(s)
  if is_soundbar(s) then
    return { "wifi", "bluetooth", "HDMI", "optical", "aux", "USB" }
  end
  return { "wifi", "bluetooth" }
end

local function emit_speaker(device, idx, s)
  local cid = "speaker" .. idx
  local st = state_for(device, s.key)
  if not st.polled then return end

  if not is_reachable(st) then
    emit(device, cid, capabilities.switch.switch.off())
    emit(device, cid, capabilities.mediaPlayback.playbackStatus.stopped())
    emit(device, cid, capabilities.audioTrackData.audioTrackData({ title = s.name .. " (unreachable)", artist = s.ip }))
    return
  end

  emit(device, cid, st.on and capabilities.switch.switch.on() or capabilities.switch.switch.off())
  emit(device, cid, playback_event(st.playback))
  if st.volume then emit(device, cid, capabilities.audioVolume.volume(st.volume)) end
  if st.muted ~= nil then
    emit(device, cid, st.muted and capabilities.audioMute.mute.muted() or capabilities.audioMute.mute.unmuted())
  end
  local track = { title = s.name, artist = s.ip, album = s.model or "" }
  if st.playback == "playing" and st.track then
    track = {
      title = st.track.title,
      artist = st.track.artist or "",
      album = st.track.album or st.cpname or s.name,
    }
    if st.leader_name then track.album = (track.album or "") .. " · grouped with " .. st.leader_name end
    if st.track.art then
      -- the app won't load plain-HTTP images; Spotify's image CDN also serves HTTPS
      track.albumArtUrl = string.gsub(st.track.art, "^http://([%w%.%-]*scdn%.co/)", "https://%1")
    end
    if st.track.length then emit(device, cid, capabilities.audioTrackData.totalTime(st.track.length)) end
  end
  emit(device, cid, capabilities.audioTrackData.audioTrackData(track))
  emit(device, cid, capabilities.audioTrackData.elapsedTime(st.elapsed or 0))

  emit(device, cid, capabilities.mediaInputSource.supportedInputSources(input_sources_for(s)))
  local src = st.func and command.FUNC_TO_SOURCE[st.func]
  if src then emit(device, cid, capabilities.mediaInputSource.inputSource(src)) end
  if st.shuffle ~= nil then
    emit(device, cid, capabilities.mediaPlaybackShuffle.playbackShuffle(st.shuffle and "enabled" or "disabled"))
  end
  if st.repeat_mode == "one" or st.repeat_mode == "all" or st.repeat_mode == "off" then
    emit(device, cid, capabilities.mediaPlaybackRepeat.playbackRepeatMode(st.repeat_mode))
  end

  local eqp = custom_cap(EQ_PRESET_ID)
  if eqp and st.eq_presets then
    local names = {}
    for _, p in ipairs(st.eq_presets) do table.insert(names, app_preset_name(p.name)) end
    emit(device, cid, eqp.supportedPresets(names))
  end
  if eqp and st.eq and st.eq.name then emit(device, cid, eqp.preset(app_preset_name(st.eq.name))) end
end

local function emit_main(device)
  local list = get_speakers(device)
  local reachable, polled = 0, 0
  local any_on, any_playing, any_paused = false, false, false
  local all_muted, any_mute_known = true, false
  local vol_sum, vol_n = 0, 0
  local playing_names = {}

  for _, s in ipairs(list) do
    local st = state_for(device, s.key)
    if st.polled then polled = polled + 1 end
    if is_reachable(st) then
      reachable = reachable + 1
      if st.on then any_on = true end
      if st.playback == "playing" then
        any_playing = true
        local what = st.track and st.track.title and (" (" .. st.track.title .. ")") or ""
        table.insert(playing_names, s.name .. what)
      elseif st.playback == "paused" then
        any_paused = true
      end
      if st.volume then vol_sum, vol_n = vol_sum + st.volume, vol_n + 1 end
      if st.muted ~= nil then
        any_mute_known = true
        if not st.muted then all_muted = false end
      end
    end
  end

  -- Only mark the whole device offline when every known speaker has failed repeatedly.
  if #list > 0 and polled == #list and reachable == 0 then
    device:offline()
  else
    device:online()
  end

  emit(device, "main", any_on and capabilities.switch.switch.on() or capabilities.switch.switch.off())
  emit(device, "main", playback_event(any_playing and "playing" or (any_paused and "paused" or "stopped")))
  if vol_n > 0 then
    emit(device, "main", capabilities.audioVolume.volume(math.floor(vol_sum / vol_n + 0.5)))
  end
  if any_mute_known then
    emit(device, "main", all_muted and capabilities.audioMute.mute.muted() or capabilities.audioMute.mute.unmuted())
  end

  local title
  if #list == 0 then
    title = "No speakers found yet"
  elseif polled < #list and reachable == 0 then
    title = string.format("Checking %d speakers...", #list)
  else
    title = string.format("%d of %d speakers online", reachable, #list)
  end
  local artist = (#playing_names > 0) and ("Playing: " .. table.concat(playing_names, ", ")) or ""
  emit(device, "main", capabilities.audioTrackData.audioTrackData({ title = title, artist = artist }))
end

local function emit_all(device)
  for idx, s in ipairs(get_speakers(device)) do emit_speaker(device, idx, s) end
  emit_main(device)
end

---------------------------------------------------------------------------------------------------
-- discovery / polling
---------------------------------------------------------------------------------------------------

local function rescan(device, force)
  local now = os.time()
  local last = device:get_field(F_LAST_SCAN) or 0
  if not force and (now - last) < RESCAN_MIN_INTERVAL then return end
  device:set_field(F_LAST_SCAN, now)

  log.info("scanning network for Samsung speakers")
  local excluded = excluded_set(device)
  local known = {}
  for _, s in ipairs(get_speakers(device)) do
    if is_reachable(state_for(device, s.key)) then table.insert(known, s.ip) end
  end
  for ip in pairs(excluded) do table.insert(known, ip) end -- sweep skips these too
  local found = find_speakers(known)
  for _, ip in ipairs(manual_ips(device)) do
    local dup = false
    for _, f in ipairs(found) do if f.ip == ip then dup = true end end
    if not dup then
      local spk = disco.probe(ip)
      if spk then table.insert(found, spk) else log.warn("manual speaker IP not responding: " .. ip) end
    end
  end

  local list = get_speakers(device)
  local changed = prune_excluded(device, list)
  if dedupe(list) then changed = true end
  for _, f in ipairs(found) do
    if excluded[f.ip] then
      log.debug(string.format("ignoring excluded speaker %s (%s)", f.name, f.ip))
    elseif merge_speaker(device, list, f) then
      changed = true
    end
  end
  if dedupe(list) then changed = true end
  if changed then
    save_speakers(device, list)
    ensure_profile(device)
  end
end

--- run an optional status request; after 2 failures in a row it's only retried every 20th poll
--- (some soundbars never answer certain commands and each try costs a 4 s timeout)
local function optional(st, name, fn, ...)
  st.skip = st.skip or {}
  local e = st.skip[name]
  if not e then e = { miss = 0, wait = 0 }; st.skip[name] = e end
  if e.miss >= 2 then
    e.wait = e.wait + 1
    if e.wait < 20 then return nil end
    e.wait = 0
  end
  local r = fn(...)
  if r == nil then e.miss = e.miss + 1 else e.miss = 0 end
  return r
end

local function poll_speaker(device, s)
  local st = state_for(device, s.key)
  -- Some soundbars (e.g. WAM750) never answer GetPlayStatus and each try costs a 4 s timeout.
  -- After 2 such misses, skip it and only retry it every 10th poll.
  st.ps_skip = st.ps_skip or 0
  local ps = nil
  local try_ps = (st.ps_misses or 0) < 2 or st.ps_skip >= 10
  if try_ps then
    st.ps_skip = 0
    ps = command.get_play_status(s.ip)
    if ps then st.ps_misses = 0 end
  else
    st.ps_skip = st.ps_skip + 1
  end
  if not ps then
    -- any answer at all means the speaker is up
    local v = command.get_volume(s.ip)
    if v then
      ps = { playback = st.playback or "stopped" }
      if try_ps then
        st.ps_misses = (st.ps_misses or 0) + 1
        if st.ps_misses == 2 then
          log.info(string.format("%s doesn't answer play status; checking it less often", s.name))
        end
      end
    end
  end
  st.polled = true
  if not ps then
    st.fails = st.fails + 1
    log.debug(string.format("%s (%s) did not answer (%d)", s.name, s.ip, st.fails))
    return false
  end
  st.fails = 0
  st.playback = ps.playback
  if ps.submode ~= nil or ps.source ~= nil then
    st.cp = (ps.source == "cp")
    st.cpname = ps.cpname
  end
  if ps.func then
    st.func = ps.func
  elseif st.poll_n == nil or st.poll_n % 5 == 0 then
    st.func = optional(st, "func", command.get_func, s.ip) or st.func
  end
  st.poll_n = (st.poll_n or 0) + 1
  if st.playback == "playing" then st.on = true end

  local vol = command.get_volume(s.ip)
  if vol then st.volume = math.floor(math.min(100, math.max(0, vol))) end
  local muted = optional(st, "mute", command.get_mute, s.ip)
  if muted ~= nil then st.muted = muted end
  local grp = optional(st, "group", command.get_group, s.ip)
  if grp then
    -- follower if grouped under a different speaker's MAC
    st.group_main = (grp.main_mac and grp.main_mac ~= s.key) and grp.main_mac or nil
  end

  if st.playback == "playing" then
    if st.cp then
      st.track = command.get_cp_info(s.ip)
    else
      st.track = optional(st, "trackinfo", command.get_track_info, s.ip)
    end
  else
    st.track = nil
  end

  -- shuffle / repeat / position only matter while something is playing
  if st.playback == "playing" then
    local sh = optional(st, "shuffle", command.get_shuffle, s.ip, st.cp)
    if sh ~= nil then st.shuffle = sh end
    local rp = optional(st, "repeat", command.get_repeat, s.ip, st.cp)
    if rp ~= nil then st.repeat_mode = rp end
    local pt = optional(st, "playtime", command.get_play_time, s.ip, st.cp)
    st.elapsed = pt and pt.elapsed or nil
  else
    st.elapsed = nil
  end

  -- EQ changes rarely: check it on the first poll and every 5th one after
  if EQ_PRESET_ID and st.poll_n % 5 == 1 then
    if not st.eq_presets then st.eq_presets = optional(st, "eqlist", command.get_eq_presets, s.ip) end
    local eq = optional(st, "eq", command.get_eq, s.ip)
    if eq then st.eq = eq end
  end
  return true
end

--- grouped followers report "Unknown / stop": show (and control) the group leader instead
local function mirror_groups(device, list, by_key)
  for _, s in ipairs(list) do
    local st = state_for(device, s.key)
    local leader = st.group_main and by_key[st.group_main]
    local lst = leader and state_for(device, leader.key)
    if lst and is_reachable(lst) then
      st.leader_ip, st.leader_name = leader.ip, leader.name
      st.playback, st.track, st.cp, st.cpname = lst.playback, lst.track, lst.cp, lst.cpname
      st.shuffle, st.repeat_mode, st.elapsed = lst.shuffle, lst.repeat_mode, lst.elapsed
      if st.playback == "playing" then st.on = true end
    else
      st.leader_ip, st.leader_name = nil, nil
    end
  end
end

--- Re-check only some speakers (plus their group leader / followers) right after a command,
--- so the card updates without waiting for the next full poll.
--- poll several speakers at the same time (one slow/timing-out speaker no longer delays the rest)
--- @return table key -> true if the speaker answered
local function poll_parallel(device, speakers)
  local results = {}
  if #speakers == 0 then return results end
  local tx, rx = cosock.channel.new()
  for _, s in ipairs(speakers) do
    cosock.spawn(function()
      local ok, answered = pcall(poll_speaker, device, s)
      if not ok then log.error(string.format("poll failed for %s: %s", s.name, tostring(answered))) end
      tx:send({ key = s.key, answered = ok and answered })
    end, "poll " .. s.name)
  end
  for _ = 1, #speakers do
    local r = rx:receive()
    if r then results[r.key] = r.answered end
  end
  return results
end

local function refresh_some(device, keys)
  local list = get_speakers(device)
  local by_key = {}
  for _, s in ipairs(list) do by_key[s.key] = s end

  -- widen to the whole group: leaders of the targets and followers of those leaders
  local want = {}
  for k in pairs(keys) do
    want[k] = true
    local gm = state_for(device, k).group_main
    if gm then want[gm] = true end
  end
  for _, s in ipairs(list) do
    local gm = state_for(device, s.key).group_main
    if gm and want[gm] then want[s.key] = true end
  end

  local to_poll = {}
  for _, s in ipairs(list) do
    if want[s.key] then table.insert(to_poll, s) end
  end
  poll_parallel(device, to_poll)
  mirror_groups(device, list, by_key)
  for idx, s in ipairs(list) do
    if want[s.key] then emit_speaker(device, idx, s) end
  end
  emit_main(device)
end

local function poll_all(device)
  local need_rescan = false
  local list = get_speakers(device)
  local by_key = {}
  local answered = poll_parallel(device, list)
  for _, s in ipairs(list) do
    if not answered[s.key] and state_for(device, s.key).fails >= 2 then
      need_rescan = true -- maybe the speaker got a new IP from DHCP
    end
    by_key[s.key] = s
  end

  mirror_groups(device, list, by_key)

  for idx, s in ipairs(list) do emit_speaker(device, idx, s) end
  emit_main(device)
  if need_rescan then
    rescan(device, false)
  end
end

local function schedule_polling(device)
  local old = device:get_field(F_POLL_TIMER)
  if old then device.thread:cancel_timer(old) end
  local interval = tonumber(device.preferences and device.preferences.pollInterval) or DEFAULT_POLL
  interval = math.max(15, interval)
  device:set_field(F_POLL_TIMER, device.thread:call_on_schedule(interval, function() poll_all(device) end, "poll"))

  if not device:get_field(F_SCAN_TIMER) then
    device:set_field(F_SCAN_TIMER, device.thread:call_on_schedule(PERIODIC_RESCAN, function()
      reset_emitted(device) -- re-send everything once every 30 min in case an event was dropped
      rescan(device, true)
      poll_all(device)
    end, "rescan"))
  end
end

---------------------------------------------------------------------------------------------------
-- command handling
---------------------------------------------------------------------------------------------------

--- speakers a command applies to: all reachable ones for "main", otherwise the one component
local function targets(device, cmd)
  local list = get_speakers(device)
  local out = {}
  if cmd.component == "main" then
    for idx, s in ipairs(list) do
      local st = state_for(device, s.key)
      if not st.polled or is_reachable(st) then table.insert(out, { idx = idx, s = s, st = st }) end
    end
  else
    local idx = tonumber(string.match(cmd.component or "", "^speaker(%d+)$"))
    if idx and list[idx] then
      table.insert(out, { idx = idx, s = list[idx], st = state_for(device, list[idx].key) })
    end
  end
  return out
end

--- followup: optional list of delays (seconds) after which the targeted speakers are re-checked
local function for_targets(fn, followup)
  return function(_, device, cmd)
    local keys = {}
    for _, t in ipairs(targets(device, cmd)) do
      local ok, err = pcall(fn, t.s, t.st, cmd)
      if not ok then log.error(string.format("command failed for %s: %s", t.s.name, tostring(err))) end
      forget_component(device, "speaker" .. t.idx) -- always report state back after a command
      emit_speaker(device, t.idx, t.s)
      keys[t.s.key] = true
    end
    forget_component(device, "main")
    emit_main(device)
    for _, delay in ipairs(followup or {}) do
      device.thread:call_with_delay(delay, function() refresh_some(device, keys) end, "followup")
    end
  end
end

local handle_on = for_targets(function(s, st)
  if command.power(s.ip, true) then st.on = true end
end, { 2 })

local handle_off = for_targets(function(s, st)
  if command.power(s.ip, false) then
    st.on = false
    st.playback = "stopped"
  end
end, { 2 })

--- playback/track commands for a grouped follower go to its leader; on "All Speakers" the
--- follower is skipped so the leader doesn't get the command twice (e.g. skipping 2 tracks)
local function group_control(fn, followup)
  return for_targets(function(s, st, cmd)
    if st.leader_ip and cmd.component == "main" then return end
    fn(st.leader_ip or s.ip, st, cmd)
  end, followup or { 1.5 })
end

local handle_play = group_control(function(ip, st)
  if command.playback(ip, "resume", st.cp) then
    st.playback, st.on = "playing", true
  end
end)

local handle_pause = group_control(function(ip, st)
  if command.playback(ip, "pause", st.cp) then st.playback = "paused" end
end)

local handle_stop = group_control(function(ip, st)
  if command.playback(ip, "pause", st.cp) then st.playback = "stopped" end
end)

local handle_next = group_control(function(ip, st)
  if command.trick(ip, "next", st.cp) then st.playback = "playing" end
end, { 1.5, 5 })

local handle_previous = group_control(function(ip, st)
  if command.trick(ip, "previous", st.cp) then st.playback = "playing" end
end, { 1.5, 5 })

local handle_input_source = for_targets(function(s, st, cmd)
  local func = command.SOURCE_TO_FUNC[cmd.args.mode or ""]
  if not func then
    log.warn("unsupported input source: " .. tostring(cmd.args.mode))
    return
  end
  if command.set_func(s.ip, func) then st.func = func end
end, { 2 })

local handle_shuffle = group_control(function(ip, st, cmd)
  local on = cmd.args.shuffle == "enabled"
  if command.set_shuffle(ip, on, st.cp) then st.shuffle = on end
end)

local handle_repeat = group_control(function(ip, st, cmd)
  local mode = cmd.args.playbackRepeatMode
  if command.set_repeat(ip, mode, st.cp) then st.repeat_mode = mode end
end)

-- EQ is per speaker (not sent to the group leader)
local handle_eq_preset = for_targets(function(s, st, cmd)
  local want = string.lower(cmd.args.preset or "")
  for _, p in ipairs(st.eq_presets or {}) do
    if string.lower(p.name) == want then
      if command.set_eq_preset(s.ip, p.index) then
        st.eq = { index = p.index, name = p.name }
        st.poll_n = 0 -- re-read the EQ on the follow-up check
      end
      return
    end
  end
  log.warn(string.format("%s has no EQ preset %s", s.name, tostring(cmd.args.preset)))
end, { 1.5 })

local function set_mute(want)
  return for_targets(function(s, st)
    local m = command.set_mute(s.ip, want)
    if m ~= nil then st.muted = m end
  end)
end

local function set_vol(s, st, level)
  local v = command.set_volume(s.ip, level)
  if v then
    st.volume = math.floor(math.min(100, math.max(0, v)))
    st.muted = false
  end
end

local handle_set_volume = for_targets(function(s, st, cmd)
  set_vol(s, st, cmd.args.volume)
end)

local function step_volume(delta)
  return for_targets(function(s, st)
    local current = st.volume or command.get_volume(s.ip)
    if current then set_vol(s, st, current + delta) end
  end)
end

local handle_notification = for_targets(function(s, _, cmd)
  if cmd.args and cmd.args.uri then
    log.info(string.format("announcement for %s (%s): uri=%s", s.name, s.ip, tostring(cmd.args.uri)))
    local muted = command.get_mute(s.ip)
    if muted then command.set_mute(s.ip, false) end
    local ok, result, err, sent = command.play_url(s.ip, cmd.args.uri)
    log.info(string.format("announcement -> %s: ok=%s speaker_result=%s err=%s sent=%s",
      s.name, tostring(ok), tostring(result), tostring(err), tostring(sent)))
  end
end)

local function handle_refresh(_, device, cmd)
  reset_emitted(device) -- a manual refresh re-sends every value
  poll_all(device)      -- report status first (the app waits for it) ...
  if cmd.component == "main" then
    rescan(device, false) -- ... then look for new speakers / IP changes
  end
end

---------------------------------------------------------------------------------------------------
-- lifecycle
---------------------------------------------------------------------------------------------------

local function take_pending(device)
  if pending_speakers and device.device_network_id == HUB_DNI then
    local list = get_speakers(device)
    for _, f in ipairs(pending_speakers) do merge_speaker(device, list, f) end
    save_speakers(device, list)
    pending_speakers = nil
  end
end

local function device_added(_, device)
  take_pending(device)
end

local function device_init(driver, device)
  log.info("init Samsung speaker group")
  reset_emitted(device)
  remember_hub_ip(driver)
  take_pending(device)
  do
    local list = get_speakers(device)
    if dedupe(list) then save_speakers(device, list) else log_rename_body(device, list) end
  end
  ensure_profile(device)
  emit_supported_commands(device)
  emit_main(device)
  schedule_polling(device)

  -- never block init on the network: first poll/scan run in the background
  device.thread:call_with_delay(2, function()
    if #get_speakers(device) == 0 or #manual_ips(device) > 0 then rescan(device, true) end
    poll_all(device)
  end)
end

local function info_changed(_, device, _, args)
  -- profile may have changed (components added) -> re-emit everything from cache
  reset_emitted(device)
  emit_supported_commands(device)
  emit_all(device)

  local old = (args and args.old_st_store and args.old_st_store.preferences) or {}
  local new = device.preferences or {}

  if old.resetSpeakers ~= nil and old.resetSpeakers ~= new.resetSpeakers then
    log.info("resetting speaker list")
    save_speakers(device, {})
    device:set_field(F_STATE, {})
    device.thread:call_with_delay(1, function()
      rescan(device, true)
      ensure_profile(device)
      poll_all(device)
    end)
    return
  end

  if old.pollInterval ~= new.pollInterval then schedule_polling(device) end
  if old.excludedIps ~= new.excludedIps then
    local list = get_speakers(device)
    if prune_excluded(device, list) then
      save_speakers(device, list)
      ensure_profile(device)
      emit_all(device)
    end
  end
  if old.speakerIps ~= new.speakerIps or old.excludedIps ~= new.excludedIps then
    device.thread:call_with_delay(1, function()
      rescan(device, true)
      poll_all(device)
    end)
  end
end

local function discovery_handler(driver, _, should_continue)
  log.info("discovery started")
  remember_hub_ip(driver)
  for _, d in ipairs(driver:get_devices()) do
    if d.device_network_id == HUB_DNI then
      -- already have the group device: just look for new speakers / IP changes
      d.thread:call_with_delay(0, function()
        rescan(d, true)
        poll_all(d)
      end)
      return
    end
  end

  if not should_continue() then return end
  local found = find_speakers()
  if #found == 0 then
    log.warn("no speakers found automatically; creating the group device anyway so speaker IPs can be entered in its settings")
  end
  pending_speakers = found
  local n = math.max(1, math.min(#found, MAX_SPEAKERS))
  driver:try_create_device({
    type = "LAN",
    device_network_id = HUB_DNI,
    label = "Samsung Speakers",
    profile = PROFILE_PREFIX .. n,
    manufacturer = "Samsung",
    model = "Multiroom Speaker Group",
    vendor_provided_label = "Samsung Audio Group",
  })
  log.info("discovery finished")
end

local capability_handlers = {
  [capabilities.switch.ID] = {
    [capabilities.switch.commands.on.NAME] = handle_on,
    [capabilities.switch.commands.off.NAME] = handle_off,
  },
  [capabilities.refresh.ID] = {
    [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
  },
  [capabilities.mediaPlayback.ID] = {
    [capabilities.mediaPlayback.commands.play.NAME] = handle_play,
    [capabilities.mediaPlayback.commands.pause.NAME] = handle_pause,
    [capabilities.mediaPlayback.commands.stop.NAME] = handle_stop,
  },
  [capabilities.mediaTrackControl.ID] = {
    [capabilities.mediaTrackControl.commands.nextTrack.NAME] = handle_next,
    [capabilities.mediaTrackControl.commands.previousTrack.NAME] = handle_previous,
  },
  [capabilities.audioMute.ID] = {
    [capabilities.audioMute.commands.mute.NAME] = set_mute(true),
    [capabilities.audioMute.commands.unmute.NAME] = set_mute(false),
  },
  [capabilities.audioVolume.ID] = {
    [capabilities.audioVolume.commands.volumeUp.NAME] = step_volume(VOL_STEP),
    [capabilities.audioVolume.commands.volumeDown.NAME] = step_volume(-VOL_STEP),
    [capabilities.audioVolume.commands.setVolume.NAME] = handle_set_volume,
  },
  [capabilities.mediaInputSource.ID] = {
    [capabilities.mediaInputSource.commands.setInputSource.NAME] = handle_input_source,
  },
  [capabilities.mediaPlaybackShuffle.ID] = {
    [capabilities.mediaPlaybackShuffle.commands.setPlaybackShuffle.NAME] = handle_shuffle,
  },
  [capabilities.mediaPlaybackRepeat.ID] = {
    [capabilities.mediaPlaybackRepeat.commands.setPlaybackRepeatMode.NAME] = handle_repeat,
  },
  [capabilities.audioNotification.ID] = {
    [capabilities.audioNotification.commands.playTrack.NAME] = handle_notification,
    [capabilities.audioNotification.commands.playTrackAndResume.NAME] = handle_notification,
    [capabilities.audioNotification.commands.playTrackAndRestore.NAME] = handle_notification,
  },
}

if EQ_PRESET_ID then
  capability_handlers[EQ_PRESET_ID] = { setPreset = handle_eq_preset }
end

local driver = Driver("samsung-audio-group", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    added = device_added,
    init = device_init,
    infoChanged = info_changed,
  },
  capability_handlers = capability_handlers,
})

driver:run()
