-- Coarse Track / Item Align
-- Select 2+ audio items. The first selected item is the reference.
-- This script:
--   1) clears selected tracks' media playback offsets
--   2) estimates whole-item lag by coarse envelope correlation
--   3) moves each target item so matching content lines up with the reference
-- It does NOT stretch, resample, or modify source media.

local ANALYSIS_SECONDS = 8.0
local MAX_LAG_SECONDS = 2.0
local ENV_BIN_SECONDS = 0.005

local function project_sr()
  local sr = reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)
  if not sr or sr <= 0 then
    local ok, s = reaper.GetAudioDeviceInfo("SRATE")
    sr = ok and tonumber(s) or 48000
  end
  return sr
end

local function selected_items()
  local out = {}
  for i = 0, reaper.CountSelectedMediaItems(0)-1 do
    out[#out+1] = reaper.GetSelectedMediaItem(0, i)
  end
  return out
end

local function active_take(item)
  local take = reaper.GetActiveTake(item)
  if take and not reaper.TakeIsMIDI(take) then return take end
end

local function clear_track_offsets(items)
  local seen = {}
  for _, item in ipairs(items) do
    local tr = reaper.GetMediaItemTrack(item)
    if tr and not seen[tr] then
      seen[tr] = true
      reaper.SetMediaTrackInfo_Value(tr, "D_PLAY_OFFSET", 0)
      reaper.SetMediaTrackInfo_Value(tr, "I_PLAY_OFFSET_FLAG", 0)
    end
  end
end

local function read_envelope(item, take, sr)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local dur = math.min(len, ANALYSIS_SECONDS)
  if dur <= 0 then return nil end

  local src = reaper.GetMediaItemTake_Source(take)
  local ch = math.max(1, math.min(2, reaper.GetMediaSourceNumChannels(src)))
  local ns = math.max(1, math.floor(dur * sr))
  local buf = reaper.new_array(ns * ch)
  local aa = reaper.CreateTakeAudioAccessor(take)
  if not aa then return nil end
  local rv = reaper.GetAudioAccessorSamples(aa, sr, ch, pos, ns, buf)
  reaper.DestroyAudioAccessor(aa)
  if rv <= 0 then return nil end

  local t = buf.table()
  local bin = math.max(1, math.floor(ENV_BIN_SECONDS * sr))
  local env = {}
  local nbin = math.floor(ns / bin)
  for b = 0, nbin-1 do
    local sum = 0
    for s = 0, bin-1 do
      local frame = b*bin + s
      local v = 0
      for c = 0, ch-1 do
        v = v + math.abs(t[frame*ch + c + 1] or 0)
      end
      sum = sum + v / ch
    end
    env[#env+1] = sum / bin
  end

  -- Differentiate the envelope to suppress constant noise-floor bias.
  local d = {}
  for i = 2, #env do d[#d+1] = env[i] - env[i-1] end
  return d
end

local function corr_at_lag(a, b, lag)
  local ia = math.max(1, 1-lag)
  local ib = math.max(1, 1+lag)
  local n = math.min(#a-ia+1, #b-ib+1)
  if n < 16 then return -1 end
  local sab, saa, sbb = 0, 0, 0
  for k = 0, n-1 do
    local x, y = a[ia+k], b[ib+k]
    sab = sab + x*y
    saa = saa + x*x
    sbb = sbb + y*y
  end
  if saa <= 0 or sbb <= 0 then return -1 end
  return sab / math.sqrt(saa*sbb)
end

local function best_lag(a, b)
  local maxlag = math.floor(MAX_LAG_SECONDS / ENV_BIN_SECONDS)
  local bestL, bestC = 0, -1
  for lag = -maxlag, maxlag do
    local c = corr_at_lag(a, b, lag)
    if c > bestC then bestC, bestL = c, lag end
  end
  return bestL * ENV_BIN_SECONDS, bestC
end

local items = selected_items()
if #items < 2 then
  reaper.MB("Select at least two audio items. The first selected item is the reference.", "Coarse Track / Item Align", 0)
  return
end

local refItem = items[1]
local refTake = active_take(refItem)
if not refTake then
  reaper.MB("The first selected item must contain audio.", "Coarse Track / Item Align", 0)
  return
end

local sr = project_sr()
local refEnv = read_envelope(refItem, refTake, sr)
if not refEnv then
  reaper.MB("Could not read reference audio.", "Coarse Track / Item Align", 0)
  return
end

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)
clear_track_offsets(items)

local refPos = reaper.GetMediaItemInfo_Value(refItem, "D_POSITION")
local report = {"Reference: " .. (reaper.GetTakeName(refTake) or "item")}

for i = 2, #items do
  local item = items[i]
  local take = active_take(item)
  if take then
    local env = read_envelope(item, take, sr)
    if env then
      local lag, score = best_lag(refEnv, env)
      local newPos = refPos - lag
      reaper.SetMediaItemInfo_Value(item, "D_POSITION", newPos)
      report[#report+1] = string.format("%s: lag %+0.3f ms, score %.3f", reaper.GetTakeName(take) or ("item "..i), lag*1000, score)
    end
  end
end

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Coarse track/item alignment", -1)
reaper.ShowConsoleMsg(table.concat(report, "\n") .. "\n")
