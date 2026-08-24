-- Guide to Plug-In Chaining: Pairwise Multi-Track Aligner
--
-- USER WORKFLOW
--   1. Select 2 or more TRACKS.
--   2. The topmost selected track is the reference.
--   3. Each selected track must contain the same ordered sequence of audio items.
--   4. Run this script.
--
-- Pairing is by chronological item index:
--   reference item 1 <-> target item 1
--   reference item 2 <-> target item 2
--   ...
--
-- The item lists are snapshotted before any edits, so splits made during fine
-- alignment do not change later pairings.
--
-- Correction hierarchy per pair:
--   1. Coarse whole-item alignment by differentiated envelope correlation.
--   2. Local sample-lag measurements across the item.
--   3. Constant residual lag -> whole-item shift.
--   4. Insertable step-like drift -> split/reposition, leaving timeline silence.
--   5. Otherwise -> stretch-marker correction.
--
-- IMPORTANT
--   Take AudioAccessors are read in their own accessor time domain. Never pass
--   project-timeline item positions directly to GetAudioAccessorSamples().
--
-- This corrects timing/sample correspondence. It cannot undo arbitrary
-- frequency-dependent phase rotation introduced by processing.

local ANALYSIS_SECONDS = 8.0
local COARSE_MAX_LAG_SECONDS = 0.50
local ENV_BIN_SECONDS = 0.005
local LOCAL_WINDOW_SAMPLES = 2048
local LOCAL_SEARCH_MS = 10.0
local LOCAL_HOP_SECONDS = 0.20
local MIN_CORR = 0.12
local CONSTANT_MAD_SAMPLES = 0.75
local STEP_THRESHOLD_SAMPLES = 1.25
local MAX_STEP_SAMPLES = 64

local function project_sr()
  local sr = reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)
  if sr and sr > 0 then return sr end
  local ok, s = reaper.GetAudioDeviceInfo("SRATE")
  sr = ok and tonumber(s) or nil
  return (sr and sr > 0) and sr or 48000
end

local function selected_tracks()
  local t = {}
  for i = 0, reaper.CountSelectedTracks(0)-1 do
    t[#t+1] = reaper.GetSelectedTrack(0, i)
  end
  table.sort(t, function(a,b)
    return reaper.GetMediaTrackInfo_Value(a, "IP_TRACKNUMBER") < reaper.GetMediaTrackInfo_Value(b, "IP_TRACKNUMBER")
  end)
  return t
end

local function track_name(tr)
  local _, n = reaper.GetTrackName(tr, "")
  if n and n ~= "" then return n end
  return "Track " .. tostring(math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER")))
end

local function active_audio_take(item)
  local take = reaper.GetActiveTake(item)
  if take and not reaper.TakeIsMIDI(take) then return take end
  return nil
end

local function audio_items_on_track(tr)
  local out = {}
  for i = 0, reaper.CountTrackMediaItems(tr)-1 do
    local item = reaper.GetTrackMediaItem(tr, i)
    if active_audio_take(item) then out[#out+1] = item end
  end
  table.sort(out, function(a,b)
    local pa = reaper.GetMediaItemInfo_Value(a, "D_POSITION")
    local pb = reaper.GetMediaItemInfo_Value(b, "D_POSITION")
    if pa == pb then
      return reaper.GetMediaItemInfo_Value(a, "D_LENGTH") < reaper.GetMediaItemInfo_Value(b, "D_LENGTH")
    end
    return pa < pb
  end)
  return out
end

local function median(v)
  local t = {}
  for i=1,#v do t[i]=v[i] end
  table.sort(t)
  if #t == 0 then return 0 end
  local m = math.floor((#t+1)/2)
  return (#t % 2 == 1) and t[m] or (t[m] + t[m+1]) * 0.5
end

local function mad(v, med)
  local d = {}
  for i=1,#v do d[i] = math.abs(v[i] - med) end
  return median(d)
end

local function clear_track_offsets(tracks)
  for _, tr in ipairs(tracks) do
    reaper.SetMediaTrackInfo_Value(tr, "D_PLAY_OFFSET", 0)
    reaper.SetMediaTrackInfo_Value(tr, "I_PLAY_OFFSET_FLAG", 0)
  end
end

local function accessor_bounds(aa)
  local a = reaper.GetAudioAccessorStartTime(aa)
  local b = reaper.GetAudioAccessorEndTime(aa)
  if not a or not b or b <= a then return nil end
  return a,b
end

local function read_mono(aa, start_time, ns, sr, ch)
  if not aa or ns < 1 then return nil end
  local a,b = accessor_bounds(aa)
  if not a then return nil end

  -- Avoid asking past the accessor boundary. GetAudioAccessorSamples can return
  -- "no audio" for an otherwise valid take when the requested block is outside.
  if start_time < a then return nil end
  local maxn = math.floor((b - start_time) * sr) - 1
  if maxn < 1 then return nil end
  ns = math.min(ns, maxn)
  if ns < 1 then return nil end

  local buf = reaper.new_array(ns * ch)
  local rv = reaper.GetAudioAccessorSamples(aa, sr, ch, start_time, ns, buf)
  if rv ~= 1 then return nil end

  local raw = buf.table()
  local mono = {}
  for i=0,ns-1 do
    local s = 0
    for c=0,ch-1 do s = s + (raw[i*ch+c+1] or 0) end
    mono[i+1] = s / ch
  end
  return mono
end

local function take_channels(take)
  local src = reaper.GetMediaItemTake_Source(take)
  local ch = reaper.GetMediaSourceNumChannels(src)
  return math.max(1, math.min(2, ch or 1))
end

local function envelope(item, take, sr)
  local aa = reaper.CreateTakeAudioAccessor(take)
  if not aa then return nil end
  local a,b = accessor_bounds(aa)
  if not a then reaper.DestroyAudioAccessor(aa); return nil end

  local duration = math.min(ANALYSIS_SECONDS, b-a)
  local ns = math.floor(duration * sr) - 1
  local ch = take_channels(take)
  local mono = read_mono(aa, a, ns, sr, ch)
  reaper.DestroyAudioAccessor(aa)
  if not mono or #mono < 4 then return nil end

  local bin = math.max(1, math.floor(ENV_BIN_SECONDS * sr))
  local nbin = math.floor(#mono / bin)
  if nbin < 3 then return nil end

  local e = {}
  for bi=0,nbin-1 do
    local s = 0
    local base = bi * bin
    for k=1,bin do s = s + math.abs(mono[base+k] or 0) end
    e[#e+1] = s / bin
  end

  -- Differentiate so constant room/noise energy contributes less to matching.
  local d = {}
  for i=2,#e do d[#d+1] = e[i] - e[i-1] end
  return d
end

local function corr_vec(a,b,lag)
  local ia = math.max(1, 1-lag)
  local ib = math.max(1, 1+lag)
  local n = math.min(#a-ia+1, #b-ib+1)
  if n < 16 then return -1 end
  local ab,aa,bb = 0,0,0
  for k=0,n-1 do
    local x,y = a[ia+k], b[ib+k]
    ab = ab + x*y
    aa = aa + x*x
    bb = bb + y*y
  end
  if aa <= 1e-30 or bb <= 1e-30 then return -1 end
  return ab / math.sqrt(aa*bb)
end

local function coarse_lag(refEnv, tgtEnv)
  local maxlag = math.floor(COARSE_MAX_LAG_SECONDS / ENV_BIN_SECONDS)
  local bestL,bestC = 0,-1
  for lag=-maxlag,maxlag do
    local c = corr_vec(refEnv,tgtEnv,lag)
    if c > bestC then bestL,bestC = lag,c end
  end
  return bestL * ENV_BIN_SECONDS, bestC
end

local function normalized_corr(ref,tgt,offset,n)
  local sx,sy,sxx,syy,sxy = 0,0,0,0,0
  for i=1,n do
    local x = ref[i]
    local y = tgt[i+offset]
    if x == nil or y == nil then return 0 end
    sx=sx+x; sy=sy+y
    sxx=sxx+x*x; syy=syy+y*y; sxy=sxy+x*y
  end
  local num = sxy - sx*sy/n
  local dx = sxx - sx*sx/n
  local dy = syy - sy*sy/n
  if dx <= 1e-20 or dy <= 1e-20 then return 0 end
  return num / math.sqrt(dx*dy)
end

local function estimate_local_lag(refAA,tgtAA,refStart,tgtStart,local_center,sr,refCh,tgtCh)
  local search = math.max(1, math.floor(LOCAL_SEARCH_MS * 0.001 * sr))
  local n = LOCAL_WINDOW_SAMPLES
  local half = (n * 0.5) / sr

  local refTime = refStart + local_center - half
  local tgtTime = tgtStart + local_center - half - search/sr
  local ref = read_mono(refAA, refTime, n, sr, refCh)
  local tgt = read_mono(tgtAA, tgtTime, n + 2*search + 2, sr, tgtCh)
  if not ref or not tgt or #ref < n or #tgt < n + 2*search then return nil end

  local bestLag,bestAbs,bestCorr = 0,-1,0
  for lag=-search,search,8 do
    local c = normalized_corr(ref,tgt,search+lag,n)
    local ac = math.abs(c)
    if ac > bestAbs then bestLag,bestAbs,bestCorr = lag,ac,c end
  end

  local lo = math.max(-search,bestLag-10)
  local hi = math.min(search,bestLag+10)
  for lag=lo,hi do
    local c = normalized_corr(ref,tgt,search+lag,n)
    local ac = math.abs(c)
    if ac > bestAbs then bestLag,bestAbs,bestCorr = lag,ac,c end
  end
  return bestLag,bestCorr
end

local function local_points(refItem,refTake,tgtItem,tgtTake,sr)
  local refAA = reaper.CreateTakeAudioAccessor(refTake)
  local tgtAA = reaper.CreateTakeAudioAccessor(tgtTake)
  if not refAA or not tgtAA then
    if refAA then reaper.DestroyAudioAccessor(refAA) end
    if tgtAA then reaper.DestroyAudioAccessor(tgtAA) end
    return {}
  end

  local ra,rb = accessor_bounds(refAA)
  local ta,tb = accessor_bounds(tgtAA)
  if not ra or not ta then
    reaper.DestroyAudioAccessor(refAA)
    reaper.DestroyAudioAccessor(tgtAA)
    return {}
  end

  local refCh = take_channels(refTake)
  local tgtCh = take_channels(tgtTake)
  local duration = math.min(rb-ra, tb-ta,
    reaper.GetMediaItemInfo_Value(refItem,"D_LENGTH"),
    reaper.GetMediaItemInfo_Value(tgtItem,"D_LENGTH"))

  local searchSec = LOCAL_SEARCH_MS * 0.001
  local half = (LOCAL_WINDOW_SAMPLES * 0.5) / sr
  local margin = half + searchSec + 0.002
  local pts = {}
  local t = margin
  while t < duration - margin do
    local lag,c = estimate_local_lag(refAA,tgtAA,ra,ta,t,sr,refCh,tgtCh)
    if lag and math.abs(c) >= MIN_CORR then
      pts[#pts+1] = { localTime=t, lag=lag, corr=c }
    end
    t = t + LOCAL_HOP_SECONDS
  end

  reaper.DestroyAudioAccessor(refAA)
  reaper.DestroyAudioAccessor(tgtAA)
  return pts
end

local function classify(points)
  local lags = {}
  for _,p in ipairs(points) do lags[#lags+1] = p.lag end
  local base = median(lags)
  if mad(lags,base) <= CONSTANT_MAD_SAMPLES then return "constant",base,{} end

  local steps = {}
  for i=2,#points do
    local d = points[i].lag - points[i-1].lag
    if math.abs(d) >= STEP_THRESHOLD_SAMPLES and math.abs(d) <= MAX_STEP_SAMPLES then
      steps[#steps+1] = { localTime=points[i].localTime, delta=d }
    end
  end
  if #steps > 0 and #steps <= 32 then return "steps",base,steps end
  return "stretch",base,{}
end

local function shift_item_samples(item,samples,sr)
  local p = reaper.GetMediaItemInfo_Value(item,"D_POSITION")
  reaper.SetMediaItemInfo_Value(item,"D_POSITION",p - samples/sr)
end

local function zero_fades(item)
  reaper.SetMediaItemInfo_Value(item,"D_FADEINLEN",0)
  reaper.SetMediaItemInfo_Value(item,"D_FADEOUTLEN",0)
  reaper.SetMediaItemInfo_Value(item,"D_FADEINLEN_AUTO",0)
  reaper.SetMediaItemInfo_Value(item,"D_FADEOUTLEN_AUTO",0)
end

local function apply_step_gaps(item,steps,base,sr)
  shift_item_samples(item,base,sr)
  local originalStart = reaper.GetMediaItemInfo_Value(item,"D_POSITION")
  local current = item
  local insertedSamples = 0
  table.sort(steps,function(a,b) return a.localTime < b.localTime end)

  for _,s in ipairs(steps) do
    -- Negative lag jump => target needs extra timeline duration inserted.
    if s.delta < 0 then
      local gapSamples = math.max(1, math.floor(-s.delta + 0.5))
      local splitTime = originalStart + s.localTime + insertedSamples/sr
      local right = reaper.SplitMediaItem(current, splitTime)
      if right then
        zero_fades(current)
        zero_fades(right)
        insertedSamples = insertedSamples + gapSamples
        local rp = reaper.GetMediaItemInfo_Value(right,"D_POSITION")
        reaper.SetMediaItemInfo_Value(right,"D_POSITION", rp + gapSamples/sr)
        current = right
      end
    end
  end
  return insertedSamples
end

local function apply_stretch(item,take,points,base,sr)
  if reaper.GetTakeNumStretchMarkers(take) > 0 then return false,"existing stretch markers" end
  shift_item_samples(item,base,sr)

  local len = reaper.GetMediaItemInfo_Value(item,"D_LENGTH")
  local offs = reaper.GetMediaItemTakeInfo_Value(take,"D_STARTOFFS")
  local rate = reaper.GetMediaItemTakeInfo_Value(take,"D_PLAYRATE")
  reaper.SetMediaItemTakeInfo_Value(take,"B_PPITCH",1)
  reaper.SetTakeStretchMarker(take,-1,0,offs)
  reaper.SetTakeStretchMarker(take,-1,len,offs+len*rate)

  local last = -1
  for _,p in ipairs(points) do
    local lp = p.localTime
    if lp > 0.002 and lp < len-0.002 and lp-last > 0.04 then
      local residual = (p.lag-base)/sr
      reaper.SetTakeStretchMarker(take,-1,lp,offs+lp*rate+residual*rate)
      last = lp
    end
  end
  return true
end

local function align_pair(refItem,tgtItem,sr)
  local refTake = active_audio_take(refItem)
  local tgtTake = active_audio_take(tgtItem)
  if not refTake or not tgtTake then return false,"missing audio take" end

  local refEnv = envelope(refItem,refTake,sr)
  local tgtEnv = envelope(tgtItem,tgtTake,sr)
  if not refEnv then return false,"could not read reference audio" end
  if not tgtEnv then return false,"could not read target audio" end

  local lagSec, coarseScore = coarse_lag(refEnv,tgtEnv)
  local refPos = reaper.GetMediaItemInfo_Value(refItem,"D_POSITION")
  reaper.SetMediaItemInfo_Value(tgtItem,"D_POSITION",refPos-lagSec)

  local pts = local_points(refItem,refTake,tgtItem,tgtTake,sr)
  if #pts < 3 then
    return true,string.format("coarse %+0.3f ms (score %.3f); no reliable fine correction",lagSec*1000,coarseScore)
  end

  local strategy,base,steps = classify(pts)
  if strategy == "constant" then
    shift_item_samples(tgtItem,base,sr)
    return true,string.format("coarse %+0.3f ms; residual %+0.3f samples",lagSec*1000,-base)
  elseif strategy == "steps" then
    local insertable = false
    for _,s in ipairs(steps) do if s.delta < 0 then insertable=true; break end end
    if insertable then
      local inserted = apply_step_gaps(tgtItem,steps,base,sr)
      return true,string.format("coarse %+0.3f ms; inserted %d sample(s) of timeline silence",lagSec*1000,inserted)
    end
  end

  local ok,why = apply_stretch(tgtItem,tgtTake,pts,base,sr)
  if ok then
    return true,string.format("coarse %+0.3f ms; stretch correction from %d measurements",lagSec*1000,#pts)
  end
  return true,string.format("coarse %+0.3f ms; fine correction skipped (%s)",lagSec*1000,why or "unknown")
end

local tracks = selected_tracks()
if #tracks < 2 then
  reaper.MB("Select at least two tracks. The topmost selected track is the reference.","Pairwise Multi-Track Aligner",0)
  return
end

-- Snapshot every track's original ordered audio-item list BEFORE making edits.
local lists = {}
local expected
for i,tr in ipairs(tracks) do
  lists[i] = audio_items_on_track(tr)
  expected = expected or #lists[i]
  if #lists[i] ~= expected then
    reaper.MB(
      string.format("Track item counts do not match.\n\nReference: %d audio items\n%s: %d audio items",expected,track_name(tr),#lists[i]),
      "Pairwise Multi-Track Aligner",0)
    return
  end
end

if expected == 0 then
  reaper.MB("The selected tracks contain no audio items.","Pairwise Multi-Track Aligner",0)
  return
end

local sr = project_sr()
local report = {
  "Pairwise Multi-Track Aligner",
  string.format("Reference: %s | %d clips | %.0f Hz",track_name(tracks[1]),expected,sr)
}
local failures = 0

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)
clear_track_offsets(tracks)

for ti=2,#tracks do
  local targetName = track_name(tracks[ti])
  local okCount = 0
  local bad = {}
  for idx=1,expected do
    local ok,detail = align_pair(lists[1][idx],lists[ti][idx],sr)
    if ok then
      okCount = okCount + 1
    else
      failures = failures + 1
      bad[#bad+1] = string.format("clip %d: %s",idx,detail or "unknown error")
    end
  end
  report[#report+1] = string.format("%s: %d/%d clip pairs processed",targetName,okCount,expected)
  for _,line in ipairs(bad) do report[#report+1] = "  "..line end
end

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Pairwise align selected tracks",-1)
reaper.ShowConsoleMsg(table.concat(report,"\n").."\n")

if failures > 0 then
  reaper.MB(string.format("Alignment finished with %d clip-pair read/alignment failure(s). See the REAPER console for details.",failures),"Pairwise Multi-Track Aligner",0)
end
