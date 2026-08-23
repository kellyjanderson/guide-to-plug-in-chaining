-- Adaptive Phase / Sample Align
-- Select 2+ audio items after coarse alignment. First selected item is the reference.
-- Strategy hierarchy:
--   A) constant lag -> whole-item sample shift (no resampling)
--   B) stable negative step(s) in lag -> split and insert real timeline gaps (silence)
--   C) smooth drift / mixed jumps -> stretch-marker warp with fractional timing
--
-- This aligns TIME / SAMPLE CORRESPONDENCE. It does not undo arbitrary
-- frequency-dependent phase rotation introduced by different plugins.
--
-- Existing stretch markers on a target cause that target to be skipped.

local WINDOW_SAMPLES = 2048
local SEARCH_MS = 8.0
local HOP_SECONDS = 0.25
local MIN_CORR = 0.12
local CONSTANT_MAD_SAMPLES = 0.75
local STEP_THRESHOLD_SAMPLES = 1.5
local MAX_GAP_STEP_SAMPLES = 32

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

local function median(v)
  local t = {}
  for i = 1, #v do t[i] = v[i] end
  table.sort(t)
  if #t == 0 then return 0 end
  local m = math.floor((#t+1)/2)
  if #t % 2 == 1 then return t[m] end
  return (t[m] + t[m+1]) * 0.5
end

local function mad(v, med)
  local d = {}
  for i = 1, #v do d[i] = math.abs(v[i] - med) end
  return median(d)
end

local function read_mono(accessor, start_time, ns, sr, ch)
  local buf = reaper.new_array(ns * ch)
  local rv = reaper.GetAudioAccessorSamples(accessor, sr, ch, start_time, ns, buf)
  if rv <= 0 then return nil end
  local raw = buf.table()
  local mono = {}
  for i = 0, ns-1 do
    local sum = 0
    for c = 0, ch-1 do sum = sum + (raw[i*ch+c+1] or 0) end
    mono[i+1] = sum / ch
  end
  return mono
end

local function normalized_corr(ref, tgt, offset, n)
  local sx, sy, sxx, syy, sxy = 0, 0, 0, 0, 0
  for i = 1, n do
    local x = ref[i]
    local y = tgt[i + offset]
    sx, sy = sx+x, sy+y
    sxx, syy, sxy = sxx+x*x, syy+y*y, sxy+x*y
  end
  local num = sxy - sx*sy/n
  local dx = sxx - sx*sx/n
  local dy = syy - sy*sy/n
  if dx <= 1e-20 or dy <= 1e-20 then return 0 end
  return num / math.sqrt(dx*dy)
end

local function estimate_lag(refAA, tgtAA, center, sr, refCh, tgtCh)
  local search = math.max(1, math.floor(SEARCH_MS * 0.001 * sr))
  local n = WINDOW_SAMPLES
  local start = center - (n * 0.5) / sr
  local ref = read_mono(refAA, start, n, sr, refCh)
  local tgt = read_mono(tgtAA, start - search/sr, n + search*2, sr, tgtCh)
  if not ref or not tgt then return nil end

  -- Coarse search every 8 samples.
  local bestLag, bestAbs, bestCorr = 0, -1, 0
  for lag = -search, search, 8 do
    local c = normalized_corr(ref, tgt, search + lag, n)
    local a = math.abs(c)
    if a > bestAbs then bestLag, bestAbs, bestCorr = lag, a, c end
  end

  -- Full-sample refinement around the coarse winner.
  local lo = math.max(-search, bestLag-10)
  local hi = math.min(search, bestLag+10)
  for lag = lo, hi do
    local c = normalized_corr(ref, tgt, search + lag, n)
    local a = math.abs(c)
    if a > bestAbs then bestLag, bestAbs, bestCorr = lag, a, c end
  end
  return bestLag, bestCorr
end

local function smooth_lags(points)
  local out = {}
  for i = 1, #points do
    local v = {}
    for j = math.max(1,i-1), math.min(#points,i+1) do v[#v+1] = points[j].lag end
    out[i] = median(v)
  end
  return out
end

local function classify(points)
  local lags = {}
  for _, p in ipairs(points) do lags[#lags+1] = p.lag end
  local med = median(lags)
  local spread = mad(lags, med)
  if spread <= CONSTANT_MAD_SAMPLES then return "constant", med, {} end

  local sm = smooth_lags(points)
  local gaps = {}
  local hasPositiveJump = false
  for i = 2, #sm do
    local d = sm[i] - sm[i-1]
    if d <= -STEP_THRESHOLD_SAMPLES and math.abs(d) <= MAX_GAP_STEP_SAMPLES then
      gaps[#gaps+1] = { index=i, samples=-d, time=points[i].time }
    elseif d >= STEP_THRESHOLD_SAMPLES then
      hasPositiveJump = true
    end
  end

  -- Gap mode is intentionally conservative: only use it when all major changes
  -- can be repaired by INSERTING silence. If we would need to delete/overlap
  -- samples, use stretch markers instead.
  if #gaps > 0 and not hasPositiveJump and #gaps <= 8 then
    return "gaps", med, gaps
  end
  return "stretch", med, {}
end

local function shift_item(item, lag_samples, sr)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", pos - lag_samples/sr)
end

local function insert_gaps(item, gaps, baseLag, sr)
  shift_item(item, baseLag, sr)
  local current = item
  local accumulated = 0
  table.sort(gaps, function(a,b) return a.time < b.time end)

  for _, g in ipairs(gaps) do
    local gapSec = g.samples / sr
    local splitTime = g.time + accumulated
    local right = reaper.SplitMediaItem(current, splitTime)
    if right then
      local rp = reaper.GetMediaItemInfo_Value(right, "D_POSITION")
      reaper.SetMediaItemInfo_Value(right, "D_POSITION", rp + gapSec)
      accumulated = accumulated + gapSec
      current = right
    end
  end
end

local function stretch_align(item, take, points, baseLag, sr)
  if reaper.GetTakeNumStretchMarkers(take) > 0 then return false, "existing stretch markers" end

  shift_item(item, baseLag, sr)
  local pos0 = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local startOffs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 1)

  -- Boundary markers keep the item's outer edges pinned.
  reaper.SetTakeStretchMarker(take, -1, 0.0, startOffs)
  reaper.SetTakeStretchMarker(take, -1, len, startOffs + len*rate)

  local lastPos = -1
  for _, p in ipairs(points) do
    local localPos = p.time - pos0
    if localPos > 0.002 and localPos < len-0.002 and localPos-lastPos > 0.01 then
      local residual = (p.lag - baseLag) / sr
      local srcPos = startOffs + localPos*rate + residual*rate
      reaper.SetTakeStretchMarker(take, -1, localPos, srcPos)
      lastPos = localPos
    end
  end
  return true
end

local items = selected_items()
if #items < 2 then
  reaper.MB("Select at least two audio items. Run coarse alignment first. The first selected item is the reference.", "Adaptive Phase Align", 0)
  return
end

local refItem = items[1]
local refTake = active_take(refItem)
if not refTake then
  reaper.MB("Reference item must contain audio.", "Adaptive Phase Align", 0)
  return
end

local sr = project_sr()
local refSrc = reaper.GetMediaItemTake_Source(refTake)
local refCh = math.max(1, math.min(2, reaper.GetMediaSourceNumChannels(refSrc)))
local refAA = reaper.CreateTakeAudioAccessor(refTake)
if not refAA then return end

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)
local report = {"Adaptive alignment, reference: " .. (reaper.GetTakeName(refTake) or "item")}

for i = 2, #items do
  local item = items[i]
  local take = active_take(item)
  if take then
    local src = reaper.GetMediaItemTake_Source(take)
    local ch = math.max(1, math.min(2, reaper.GetMediaSourceNumChannels(src)))
    local aa = reaper.CreateTakeAudioAccessor(take)
    if aa then
      local r0 = reaper.GetMediaItemInfo_Value(refItem, "D_POSITION")
      local r1 = r0 + reaper.GetMediaItemInfo_Value(refItem, "D_LENGTH")
      local t0 = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local t1 = t0 + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local startT, endT = math.max(r0,t0), math.min(r1,t1)
      local points = {}

      if endT > startT + 0.05 then
        local t = startT + 0.05
        while t < endT - 0.05 do
          local lag, corr = estimate_lag(refAA, aa, t, sr, refCh, ch)
          if lag and math.abs(corr) >= MIN_CORR then
            points[#points+1] = {time=t, lag=lag, corr=corr}
          end
          t = t + HOP_SECONDS
        end
      end

      if #points >= 3 then
        local strategy, baseLag, gaps = classify(points)
        local name = reaper.GetTakeName(take) or ("item "..i)
        if strategy == "constant" then
          shift_item(item, baseLag, sr)
          report[#report+1] = string.format("%s: constant shift %+0.3f samples", name, -baseLag)
        elseif strategy == "gaps" then
          insert_gaps(item, gaps, baseLag, sr)
          report[#report+1] = string.format("%s: shift %+0.3f samples + %d inserted gap(s)", name, -baseLag, #gaps)
        else
          local ok, why = stretch_align(item, take, points, baseLag, sr)
          if ok then
            report[#report+1] = string.format("%s: stretch-marker alignment from %d local measurements", name, #points)
          else
            report[#report+1] = string.format("%s: skipped (%s)", name, why or "unknown reason")
          end
        end
      else
        report[#report+1] = string.format("%s: insufficient reliable correlation points (%d)", reaper.GetTakeName(take) or ("item "..i), #points)
      end
      reaper.DestroyAudioAccessor(aa)
    end
  end
end

reaper.DestroyAudioAccessor(refAA)
reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Adaptive sample/phase alignment", -1)
reaper.ShowConsoleMsg(table.concat(report, "\n") .. "\n")
