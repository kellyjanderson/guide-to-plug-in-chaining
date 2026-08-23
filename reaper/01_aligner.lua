-- Guide to Plug-In Chaining: Unified Aligner
--
-- Select 2+ AUDIO items. The FIRST selected item is the reference.
--
-- Purpose:
--   Put independently processed copies of the same source onto a common timebase
--   before median/consensus combining.
--
-- Correction hierarchy:
--   1. Clear REAPER track playback offsets on selected-item tracks.
--   2. Coarse whole-item alignment using differentiated amplitude-envelope correlation.
--   3. Local sample-lag measurements across the overlap.
--   4. Constant integer/fractional lag -> whole-item shift when possible.
--   5. Smooth drift -> stretch-marker time warp (least number of markers needed).
--   6. Step-like delay -> split/reposition item segments, leaving actual timeline silence.
--
-- IMPORTANT ABOUT "ZERO SAMPLE STUFFING":
--   REAPER ReaScript can non-destructively split/move item segments and create stretch
--   markers, but it cannot insert an isolated PCM zero *inside an existing source file*
--   without generating new media. Therefore this script's non-destructive equivalent is
--   to leave timeline gaps where an inserted missing sample would exist. A future
--   render-to-new-source mode can perform literal periodic zero-sample stuffing.
--
-- This aligns time/sample correspondence. It does NOT undo arbitrary frequency-dependent
-- phase rotation caused by processors.

local ANALYSIS_SECONDS = 10.0
local COARSE_MAX_LAG_SECONDS = 2.0
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
  if not sr or sr <= 0 then
    local ok, s = reaper.GetAudioDeviceInfo("SRATE")
    sr = ok and tonumber(s) or 48000
  end
  return sr
end

local function selected_items()
  local t = {}
  for i = 0, reaper.CountSelectedMediaItems(0)-1 do
    t[#t+1] = reaper.GetSelectedMediaItem(0, i)
  end
  return t
end

local function active_take(item)
  local take = reaper.GetActiveTake(item)
  if take and not reaper.TakeIsMIDI(take) then return take end
end

local function median(v)
  local t = {}
  for i=1,#v do t[i]=v[i] end
  table.sort(t)
  if #t == 0 then return 0 end
  local m = math.floor((#t+1)/2)
  return (#t % 2 == 1) and t[m] or (t[m]+t[m+1])*0.5
end

local function mad(v, med)
  local d = {}
  for i=1,#v do d[i]=math.abs(v[i]-med) end
  return median(d)
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

local function read_mono(accessor, start_time, ns, sr, ch)
  local buf = reaper.new_array(ns * ch)
  local rv = reaper.GetAudioAccessorSamples(accessor, sr, ch, start_time, ns, buf)
  if rv <= 0 then return nil end
  local raw = buf.table()
  local mono = {}
  for i=0,ns-1 do
    local s=0
    for c=0,ch-1 do s=s+(raw[i*ch+c+1] or 0) end
    mono[i+1]=s/ch
  end
  return mono
end

local function envelope(item, take, sr)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = math.min(reaper.GetMediaItemInfo_Value(item, "D_LENGTH"), ANALYSIS_SECONDS)
  if len <= 0 then return nil end
  local src = reaper.GetMediaItemTake_Source(take)
  local ch = math.max(1, math.min(2, reaper.GetMediaSourceNumChannels(src)))
  local ns = math.floor(len*sr)
  local aa = reaper.CreateTakeAudioAccessor(take)
  if not aa then return nil end
  local mono = read_mono(aa, pos, ns, sr, ch)
  reaper.DestroyAudioAccessor(aa)
  if not mono then return nil end
  local bin = math.max(1, math.floor(ENV_BIN_SECONDS*sr))
  local e={}
  for b=0,math.floor(ns/bin)-1 do
    local s=0
    for k=1,bin do s=s+math.abs(mono[b*bin+k] or 0) end
    e[#e+1]=s/bin
  end
  local d={}
  for i=2,#e do d[#d+1]=e[i]-e[i-1] end
  return d
end

local function corr_vec(a,b,lag)
  local ia=math.max(1,1-lag)
  local ib=math.max(1,1+lag)
  local n=math.min(#a-ia+1,#b-ib+1)
  if n < 16 then return -1 end
  local ab,aa,bb=0,0,0
  for k=0,n-1 do
    local x,y=a[ia+k],b[ib+k]
    ab=ab+x*y; aa=aa+x*x; bb=bb+y*y
  end
  if aa<=0 or bb<=0 then return -1 end
  return ab/math.sqrt(aa*bb)
end

local function coarse_lag(refEnv,tgtEnv)
  local maxlag=math.floor(COARSE_MAX_LAG_SECONDS/ENV_BIN_SECONDS)
  local bestL,bestC=0,-1
  for lag=-maxlag,maxlag do
    local c=corr_vec(refEnv,tgtEnv,lag)
    if c>bestC then bestL,bestC=lag,c end
  end
  return bestL*ENV_BIN_SECONDS,bestC
end

local function normalized_corr(ref,tgt,offset,n)
  local sx,sy,sxx,syy,sxy=0,0,0,0,0
  for i=1,n do
    local x=ref[i]
    local y=tgt[i+offset]
    sx=sx+x; sy=sy+y
    sxx=sxx+x*x; syy=syy+y*y; sxy=sxy+x*y
  end
  local num=sxy-sx*sy/n
  local dx=sxx-sx*sx/n
  local dy=syy-sy*sy/n
  if dx<=1e-20 or dy<=1e-20 then return 0 end
  return num/math.sqrt(dx*dy)
end

local function estimate_local_lag(refAA,tgtAA,center,sr,refCh,tgtCh)
  local search=math.max(1,math.floor(LOCAL_SEARCH_MS*0.001*sr))
  local n=LOCAL_WINDOW_SAMPLES
  local start=center-(n*0.5)/sr
  local ref=read_mono(refAA,start,n,sr,refCh)
  local tgt=read_mono(tgtAA,start-search/sr,n+2*search,sr,tgtCh)
  if not ref or not tgt then return nil end
  local bestLag,bestAbs,bestCorr=0,-1,0
  for lag=-search,search,8 do
    local c=normalized_corr(ref,tgt,search+lag,n)
    local a=math.abs(c)
    if a>bestAbs then bestLag,bestAbs,bestCorr=lag,a,c end
  end
  for lag=math.max(-search,bestLag-10),math.min(search,bestLag+10) do
    local c=normalized_corr(ref,tgt,search+lag,n)
    local a=math.abs(c)
    if a>bestAbs then bestLag,bestAbs,bestCorr=lag,a,c end
  end
  return bestLag,bestCorr
end

local function local_points(refItem,refTake,item,take,sr)
  local refSrc=reaper.GetMediaItemTake_Source(refTake)
  local tgtSrc=reaper.GetMediaItemTake_Source(take)
  local refCh=math.max(1,math.min(2,reaper.GetMediaSourceNumChannels(refSrc)))
  local tgtCh=math.max(1,math.min(2,reaper.GetMediaSourceNumChannels(tgtSrc)))
  local refAA=reaper.CreateTakeAudioAccessor(refTake)
  local tgtAA=reaper.CreateTakeAudioAccessor(take)
  if not refAA or not tgtAA then
    if refAA then reaper.DestroyAudioAccessor(refAA) end
    if tgtAA then reaper.DestroyAudioAccessor(tgtAA) end
    return {}
  end
  local r0=reaper.GetMediaItemInfo_Value(refItem,"D_POSITION")
  local r1=r0+reaper.GetMediaItemInfo_Value(refItem,"D_LENGTH")
  local t0=reaper.GetMediaItemInfo_Value(item,"D_POSITION")
  local t1=t0+reaper.GetMediaItemInfo_Value(item,"D_LENGTH")
  local a,b=math.max(r0,t0),math.min(r1,t1)
  local pts={}
  local t=a+0.05
  while t<b-0.05 do
    local lag,c=estimate_local_lag(refAA,tgtAA,t,sr,refCh,tgtCh)
    if lag and math.abs(c)>=MIN_CORR then pts[#pts+1]={time=t,lag=lag,corr=c} end
    t=t+LOCAL_HOP_SECONDS
  end
  reaper.DestroyAudioAccessor(refAA)
  reaper.DestroyAudioAccessor(tgtAA)
  return pts
end

local function classify(points)
  local lags={}
  for _,p in ipairs(points) do lags[#lags+1]=p.lag end
  local base=median(lags)
  if mad(lags,base)<=CONSTANT_MAD_SAMPLES then return "constant",base,{} end
  local steps={}
  for i=2,#points do
    local d=points[i].lag-points[i-1].lag
    if math.abs(d)>=STEP_THRESHOLD_SAMPLES and math.abs(d)<=MAX_STEP_SAMPLES then
      steps[#steps+1]={time=points[i].time,delta=d}
    end
  end
  if #steps>0 and #steps<=16 then return "steps",base,steps end
  return "stretch",base,{}
end

local function shift_item(item,samples,sr)
  local p=reaper.GetMediaItemInfo_Value(item,"D_POSITION")
  reaper.SetMediaItemInfo_Value(item,"D_POSITION",p-samples/sr)
end

local function apply_step_gaps(item,steps,base,sr)
  shift_item(item,base,sr)
  local current=item
  local accumulated=0
  table.sort(steps,function(a,b) return a.time<b.time end)
  for _,s in ipairs(steps) do
    -- A negative local-lag jump means the target effectively needs more time inserted.
    -- Only insertion is lossless. Positive jumps would require deletion/overlap, so skip them.
    if s.delta < 0 then
      local gap=(-s.delta)/sr
      local split=s.time+accumulated
      local right=reaper.SplitMediaItem(current,split)
      if right then
        local rp=reaper.GetMediaItemInfo_Value(right,"D_POSITION")
        reaper.SetMediaItemInfo_Value(right,"D_POSITION",rp+gap)
        accumulated=accumulated+gap
        current=right
      end
    end
  end
end

local function apply_stretch(item,take,points,base,sr)
  if reaper.GetTakeNumStretchMarkers(take)>0 then return false,"existing stretch markers" end
  shift_item(item,base,sr)
  local pos0=reaper.GetMediaItemInfo_Value(item,"D_POSITION")
  local len=reaper.GetMediaItemInfo_Value(item,"D_LENGTH")
  local offs=reaper.GetMediaItemTakeInfo_Value(take,"D_STARTOFFS")
  local rate=reaper.GetMediaItemTakeInfo_Value(take,"D_PLAYRATE")
  reaper.SetMediaItemTakeInfo_Value(take,"B_PPITCH",1)
  reaper.SetTakeStretchMarker(take,-1,0,offs)
  reaper.SetTakeStretchMarker(take,-1,len,offs+len*rate)
  local last=-1
  for _,p in ipairs(points) do
    local lp=p.time-pos0
    if lp>0.002 and lp<len-0.002 and lp-last>0.04 then
      local residual=(p.lag-base)/sr
      reaper.SetTakeStretchMarker(take,-1,lp,offs+lp*rate+residual*rate)
      last=lp
    end
  end
  return true
end

local items=selected_items()
if #items<2 then
  reaper.MB("Select at least two audio items. The FIRST selected item is the reference.","Unified Aligner",0)
  return
end
local refItem=items[1]
local refTake=active_take(refItem)
if not refTake then reaper.MB("Reference item must contain audio.","Unified Aligner",0); return end

local sr=project_sr()
local refEnv=envelope(refItem,refTake,sr)
if not refEnv then reaper.MB("Could not read reference audio.","Unified Aligner",0); return end

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)
clear_track_offsets(items)
local refPos=reaper.GetMediaItemInfo_Value(refItem,"D_POSITION")
local report={"Unified Aligner", "Reference: "..(reaper.GetTakeName(refTake) or "item")}

for i=2,#items do
  local item=items[i]
  local take=active_take(item)
  if take then
    local env=envelope(item,take,sr)
    if env then
      local lagSec,score=coarse_lag(refEnv,env)
      reaper.SetMediaItemInfo_Value(item,"D_POSITION",refPos-lagSec)
      local pts=local_points(refItem,refTake,item,take,sr)
      local name=reaper.GetTakeName(take) or ("item "..i)
      if #pts>=3 then
        local strategy,base,steps=classify(pts)
        if strategy=="constant" then
          shift_item(item,base,sr)
          report[#report+1]=string.format("%s: coarse %+0.3f ms; constant residual %+0.3f samples",name,lagSec*1000,-base)
        elseif strategy=="steps" then
          local insertable=0
          for _,s in ipairs(steps) do if s.delta<0 then insertable=insertable+1 end end
          if insertable>0 then
            apply_step_gaps(item,steps,base,sr)
            report[#report+1]=string.format("%s: coarse %+0.3f ms; %d lossless gap insertion(s); %d measured steps",name,lagSec*1000,insertable,#steps)
          else
            local ok,why=apply_stretch(item,take,pts,base,sr)
            report[#report+1]=ok and string.format("%s: coarse %+0.3f ms; stretch warp (%d points)",name,lagSec*1000,#pts) or string.format("%s: skipped fine alignment (%s)",name,why or "unknown")
          end
        else
          local ok,why=apply_stretch(item,take,pts,base,sr)
          report[#report+1]=ok and string.format("%s: coarse %+0.3f ms; stretch warp (%d points)",name,lagSec*1000,#pts) or string.format("%s: skipped fine alignment (%s)",name,why or "unknown")
        end
      else
        report[#report+1]=string.format("%s: coarse %+0.3f ms (score %.3f); insufficient reliable fine points",name,lagSec*1000,score)
      end
    end
  end
end

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Unified track/item/sample alignment",-1)
reaper.ShowConsoleMsg(table.concat(report,"\n").."\n")
