-- Guide to Plug-In Chaining: Pairwise Multi-Track Aligner
--
-- USER WORKFLOW
--   1. Select 2 or more TRACKS.
--   2. The topmost selected track is the reference.
--   3. Each selected track contains the same ordered sequence of audio items.
--   4. Run this script.
--
-- Pairing is by chronological item index. Processing is incremental so the UI
-- remains responsive. A progress window shows the current pair and a Cancel button.
-- Cancelling stops between clip pairs and leaves completed work intact; one Undo
-- restores the entire partial run.

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

local UI_W, UI_H = 560, 185
local BTN_X, BTN_Y, BTN_W, BTN_H = 430, 130, 100, 34

local function project_sr()
  local sr = reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)
  if sr and sr > 0 then return sr end
  local ok, s = reaper.GetAudioDeviceInfo("SRATE")
  sr = ok and tonumber(s) or nil
  return (sr and sr > 0) and sr or 48000
end

local function selected_tracks()
  local t = {}
  for i=0,reaper.CountSelectedTracks(0)-1 do
    t[#t+1] = reaper.GetSelectedTrack(0,i)
  end
  table.sort(t,function(a,b)
    return reaper.GetMediaTrackInfo_Value(a,"IP_TRACKNUMBER") < reaper.GetMediaTrackInfo_Value(b,"IP_TRACKNUMBER")
  end)
  return t
end

local function track_name(tr)
  local _,n = reaper.GetTrackName(tr,"")
  if n and n ~= "" then return n end
  return "Track "..tostring(math.floor(reaper.GetMediaTrackInfo_Value(tr,"IP_TRACKNUMBER")))
end

local function active_audio_take(item)
  local take = reaper.GetActiveTake(item)
  if take and not reaper.TakeIsMIDI(take) then return take end
end

local function audio_items_on_track(tr)
  local out = {}
  for i=0,reaper.CountTrackMediaItems(tr)-1 do
    local item = reaper.GetTrackMediaItem(tr,i)
    if active_audio_take(item) then out[#out+1] = item end
  end
  table.sort(out,function(a,b)
    local pa = reaper.GetMediaItemInfo_Value(a,"D_POSITION")
    local pb = reaper.GetMediaItemInfo_Value(b,"D_POSITION")
    if pa == pb then
      return reaper.GetMediaItemInfo_Value(a,"D_LENGTH") < reaper.GetMediaItemInfo_Value(b,"D_LENGTH")
    end
    return pa < pb
  end)
  return out
end

local function median(v)
  local t = {}
  for i=1,#v do t[i]=v[i] end
  table.sort(t)
  if #t==0 then return 0 end
  local m=math.floor((#t+1)/2)
  return (#t%2==1) and t[m] or (t[m]+t[m+1])*0.5
end

local function mad(v,med)
  local d={}
  for i=1,#v do d[i]=math.abs(v[i]-med) end
  return median(d)
end

local function clear_track_offsets(tracks)
  for _,tr in ipairs(tracks) do
    reaper.SetMediaTrackInfo_Value(tr,"D_PLAY_OFFSET",0)
    reaper.SetMediaTrackInfo_Value(tr,"I_PLAY_OFFSET_FLAG",0)
  end
end

local function read_track_mono(track,start_time,ns,sr)
  if ns < 1 then return nil,"zero-length request" end
  local aa = reaper.CreateTrackAudioAccessor(track)
  if not aa then return nil,"CreateTrackAudioAccessor failed" end

  local a = reaper.GetAudioAccessorStartTime(aa)
  local b = reaper.GetAudioAccessorEndTime(aa)
  if not a or not b or b <= a then
    reaper.DestroyAudioAccessor(aa)
    return nil,"invalid accessor bounds"
  end

  if start_time < a then start_time = a end
  local available = math.floor((b-start_time)*sr) - 1
  ns = math.min(ns,available)
  if ns < 1 then
    reaper.DestroyAudioAccessor(aa)
    return nil,string.format("request outside track audio bounds (%.6f..%.6f)",a,b)
  end

  local ch = 2
  local buf = reaper.new_array(ns*ch)
  local rv = reaper.GetAudioAccessorSamples(aa,sr,ch,start_time,ns,buf)
  reaper.DestroyAudioAccessor(aa)
  if rv ~= 1 then
    return nil,string.format("GetAudioAccessorSamples returned %s at %.6f",tostring(rv),start_time)
  end

  local raw = buf.table()
  local mono={}
  for i=0,ns-1 do
    mono[i+1] = ((raw[i*2+1] or 0) + (raw[i*2+2] or 0))*0.5
  end
  return mono
end

local function differentiated_envelope(track,item,sr)
  local pos = reaper.GetMediaItemInfo_Value(item,"D_POSITION")
  local len = math.min(reaper.GetMediaItemInfo_Value(item,"D_LENGTH"),ANALYSIS_SECONDS)
  if len <= ENV_BIN_SECONDS*4 then return nil,"item too short" end

  local ns = math.max(1,math.floor(len*sr)-1)
  local mono,why = read_track_mono(track,pos,ns,sr)
  if not mono then return nil,why end

  local bin = math.max(1,math.floor(ENV_BIN_SECONDS*sr))
  local nbin = math.floor(#mono/bin)
  if nbin < 3 then return nil,"not enough envelope bins" end

  local env={}
  for bi=0,nbin-1 do
    local sum=0
    local base=bi*bin
    for k=1,bin do sum=sum+math.abs(mono[base+k] or 0) end
    env[#env+1]=sum/bin
  end

  local d={}
  for i=2,#env do d[#d+1]=env[i]-env[i-1] end
  return d
end

local function corr_vec(a,b,lag)
  local ia=math.max(1,1-lag)
  local ib=math.max(1,1+lag)
  local n=math.min(#a-ia+1,#b-ib+1)
  if n<16 then return -1 end
  local ab,aa,bb=0,0,0
  for k=0,n-1 do
    local x,y=a[ia+k],b[ib+k]
    ab=ab+x*y; aa=aa+x*x; bb=bb+y*y
  end
  if aa<=1e-30 or bb<=1e-30 then return -1 end
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
    if x==nil or y==nil then return 0 end
    sx=sx+x; sy=sy+y
    sxx=sxx+x*x; syy=syy+y*y; sxy=sxy+x*y
  end
  local num=sxy-sx*sy/n
  local dx=sxx-sx*sx/n
  local dy=syy-sy*sy/n
  if dx<=1e-20 or dy<=1e-20 then return 0 end
  return num/math.sqrt(dx*dy)
end

local function estimate_local_lag(refTrack,tgtTrack,center,sr)
  local search=math.max(1,math.floor(LOCAL_SEARCH_MS*0.001*sr))
  local n=LOCAL_WINDOW_SAMPLES
  local half=(n*0.5)/sr
  local refStart=center-half
  local tgtStart=center-half-search/sr

  local ref = read_track_mono(refTrack,refStart,n,sr)
  local tgt = read_track_mono(tgtTrack,tgtStart,n+2*search+2,sr)
  if not ref or not tgt or #ref<n or #tgt<n+2*search then return nil end

  local bestLag,bestAbs,bestCorr=0,-1,0
  for lag=-search,search,8 do
    local c=normalized_corr(ref,tgt,search+lag,n)
    local ac=math.abs(c)
    if ac>bestAbs then bestLag,bestAbs,bestCorr=lag,ac,c end
  end
  for lag=math.max(-search,bestLag-10),math.min(search,bestLag+10) do
    local c=normalized_corr(ref,tgt,search+lag,n)
    local ac=math.abs(c)
    if ac>bestAbs then bestLag,bestAbs,bestCorr=lag,ac,c end
  end
  return bestLag,bestCorr
end

local function local_points(refTrack,tgtTrack,refItem,tgtItem,sr)
  local r0=reaper.GetMediaItemInfo_Value(refItem,"D_POSITION")
  local r1=r0+reaper.GetMediaItemInfo_Value(refItem,"D_LENGTH")
  local t0=reaper.GetMediaItemInfo_Value(tgtItem,"D_POSITION")
  local t1=t0+reaper.GetMediaItemInfo_Value(tgtItem,"D_LENGTH")
  local a,b=math.max(r0,t0),math.min(r1,t1)

  local half=(LOCAL_WINDOW_SAMPLES*0.5)/sr
  local margin=half+LOCAL_SEARCH_MS*0.001+0.002
  local pts={}
  local t=a+margin
  while t<b-margin do
    local lag,c=estimate_local_lag(refTrack,tgtTrack,t,sr)
    if lag and math.abs(c)>=MIN_CORR then
      pts[#pts+1]={projectTime=t,localTime=t-t0,lag=lag,corr=c}
    end
    t=t+LOCAL_HOP_SECONDS
  end
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
      steps[#steps+1]={localTime=points[i].localTime,delta=d}
    end
  end
  if #steps>0 and #steps<=32 then return "steps",base,steps end
  return "stretch",base,{}
end

local function shift_item_samples(item,samples,sr)
  local p=reaper.GetMediaItemInfo_Value(item,"D_POSITION")
  reaper.SetMediaItemInfo_Value(item,"D_POSITION",p-samples/sr)
end

local function zero_fades(item)
  reaper.SetMediaItemInfo_Value(item,"D_FADEINLEN",0)
  reaper.SetMediaItemInfo_Value(item,"D_FADEOUTLEN",0)
  reaper.SetMediaItemInfo_Value(item,"D_FADEINLEN_AUTO",0)
  reaper.SetMediaItemInfo_Value(item,"D_FADEOUTLEN_AUTO",0)
end

local function apply_step_gaps(item,steps,base,sr)
  shift_item_samples(item,base,sr)
  local originalStart=reaper.GetMediaItemInfo_Value(item,"D_POSITION")
  local current=item
  local insertedSamples=0
  table.sort(steps,function(a,b) return a.localTime<b.localTime end)

  for _,s in ipairs(steps) do
    if s.delta<0 then
      local gapSamples=math.max(1,math.floor(-s.delta+0.5))
      local splitTime=originalStart+s.localTime+insertedSamples/sr
      local right=reaper.SplitMediaItem(current,splitTime)
      if right then
        zero_fades(current); zero_fades(right)
        insertedSamples=insertedSamples+gapSamples
        local rp=reaper.GetMediaItemInfo_Value(right,"D_POSITION")
        reaper.SetMediaItemInfo_Value(right,"D_POSITION",rp+gapSamples/sr)
        current=right
      end
    end
  end
  return insertedSamples
end

local function apply_stretch(item,take,points,base,sr)
  if reaper.GetTakeNumStretchMarkers(take)>0 then return false,"existing stretch markers" end
  shift_item_samples(item,base,sr)

  local len=reaper.GetMediaItemInfo_Value(item,"D_LENGTH")
  local offs=reaper.GetMediaItemTakeInfo_Value(take,"D_STARTOFFS")
  local rate=reaper.GetMediaItemTakeInfo_Value(take,"D_PLAYRATE")
  reaper.SetMediaItemTakeInfo_Value(take,"B_PPITCH",1)
  reaper.SetTakeStretchMarker(take,-1,0,offs)
  reaper.SetTakeStretchMarker(take,-1,len,offs+len*rate)

  local last=-1
  for _,p in ipairs(points) do
    local lp=p.localTime
    if lp>0.002 and lp<len-0.002 and lp-last>0.04 then
      local residual=(p.lag-base)/sr
      reaper.SetTakeStretchMarker(take,-1,lp,offs+lp*rate+residual*rate)
      last=lp
    end
  end
  return true
end

local function align_pair(refTrack,tgtTrack,refItem,tgtItem,sr)
  local tgtTake=active_audio_take(tgtItem)
  if not tgtTake then return false,"missing target audio take" end

  local refEnv,refWhy=differentiated_envelope(refTrack,refItem,sr)
  local tgtEnv,tgtWhy=differentiated_envelope(tgtTrack,tgtItem,sr)
  if not refEnv then return false,"could not read reference audio: "..tostring(refWhy) end
  if not tgtEnv then return false,"could not read target audio: "..tostring(tgtWhy) end

  local lagSec,score=coarse_lag(refEnv,tgtEnv)
  local tgtPos=reaper.GetMediaItemInfo_Value(tgtItem,"D_POSITION")
  reaper.SetMediaItemInfo_Value(tgtItem,"D_POSITION",tgtPos-lagSec)

  local pts=local_points(refTrack,tgtTrack,refItem,tgtItem,sr)
  if #pts<3 then
    return true,string.format("coarse %+0.3f ms; no reliable fine correction",lagSec*1000)
  end

  local strategy,base,steps=classify(pts)
  if strategy=="constant" then
    shift_item_samples(tgtItem,base,sr)
    return true,string.format("coarse %+0.3f ms; residual %+0.3f samples",lagSec*1000,-base)
  elseif strategy=="steps" then
    local insertable=false
    for _,s in ipairs(steps) do if s.delta<0 then insertable=true; break end end
    if insertable then
      local inserted=apply_step_gaps(tgtItem,steps,base,sr)
      return true,string.format("coarse %+0.3f ms; inserted %d sample(s) of timeline silence",lagSec*1000,inserted)
    end
  end

  local ok,why=apply_stretch(tgtItem,tgtTake,pts,base,sr)
  if ok then
    return true,string.format("coarse %+0.3f ms; stretch correction from %d measurements",lagSec*1000,#pts)
  end
  return true,string.format("coarse %+0.3f ms; fine correction skipped (%s)",lagSec*1000,why or "unknown")
end

-- -----------------------------------------------------------------------------
-- Job setup
-- -----------------------------------------------------------------------------
local tracks=selected_tracks()
if #tracks<2 then
  reaper.MB("Select at least two tracks. The topmost selected track is the reference.","Pairwise Multi-Track Aligner",0)
  return
end

local lists={}
local expected
for i,tr in ipairs(tracks) do
  lists[i]=audio_items_on_track(tr)
  expected=expected or #lists[i]
  if #lists[i]~=expected then
    reaper.MB(string.format("Track item counts do not match.\n\nReference: %d audio items\n%s: %d audio items",expected,track_name(tr),#lists[i]),"Pairwise Multi-Track Aligner",0)
    return
  end
end

if expected==0 then
  reaper.MB("The selected tracks contain no audio items.","Pairwise Multi-Track Aligner",0)
  return
end

local sr=project_sr()
local totalPairs=(#tracks-1)*expected
local donePairs=0
local okPairs=0
local failures=0
local targetIndex=2
local clipIndex=1
local cancelled=false
local finished=false
local lastMouseDown=false
local status="Starting..."
local report={
  "Pairwise Multi-Track Aligner",
  string.format("Reference: %s | %d clips | %d target track(s) | %.0f Hz",track_name(tracks[1]),expected,#tracks-1,sr)
}

reaper.Undo_BeginBlock()
clear_track_offsets(tracks)

gfx.init("Pairwise Multi-Track Aligner",UI_W,UI_H,0)
gfx.setfont(1,"Arial",16)

local function inside(x,y,w,h)
  return gfx.mouse_x>=x and gfx.mouse_x<=x+w and gfx.mouse_y>=y and gfx.mouse_y<=y+h
end

local function draw_ui()
  gfx.set(0.12,0.12,0.14,1); gfx.rect(0,0,UI_W,UI_H,1)

  gfx.set(0.95,0.95,0.97,1)
  gfx.x=20; gfx.y=15; gfx.drawstr("Pairwise Multi-Track Aligner")

  gfx.setfont(1,"Arial",13)
  gfx.set(0.78,0.80,0.84,1)
  gfx.x=20; gfx.y=45; gfx.drawstr(status)

  local frac = totalPairs>0 and donePairs/totalPairs or 0
  gfx.set(0.24,0.25,0.28,1); gfx.rect(20,78,510,24,1)
  gfx.set(0.20,0.55,0.95,1); gfx.rect(20,78,510*frac,24,1)
  gfx.set(1,1,1,1); gfx.x=245; gfx.y=82; gfx.drawstr(string.format("%.1f%%",frac*100))

  gfx.set(0.75,0.77,0.81,1)
  gfx.x=20; gfx.y=116
  gfx.drawstr(string.format("Processed %d / %d    Successful %d    Failed %d",donePairs,totalPairs,okPairs,failures))

  local hover=inside(BTN_X,BTN_Y,BTN_W,BTN_H)
  if hover then gfx.set(0.82,0.25,0.25,1) else gfx.set(0.62,0.18,0.18,1) end
  gfx.rect(BTN_X,BTN_Y,BTN_W,BTN_H,1)
  gfx.set(1,1,1,1); gfx.x=BTN_X+29; gfx.y=BTN_Y+8; gfx.drawstr("Cancel")

  gfx.update()
end

local function close_job(wasCancelled)
  if finished then return end
  finished=true
  cancelled=wasCancelled or false

  if gfx.quit then gfx.quit() end
  reaper.UpdateArrange()
  local label = cancelled and "Pairwise align selected tracks (cancelled)" or "Pairwise align selected tracks"
  reaper.Undo_EndBlock(label,-1)

  report[#report+1]=string.format("Processed %d/%d pairs; %d successful; %d failed%s",donePairs,totalPairs,okPairs,failures,cancelled and "; CANCELLED" or "")
  reaper.ShowConsoleMsg(table.concat(report,"\n").."\n")

  if cancelled then
    reaper.MB(string.format("Alignment cancelled after %d of %d clip pairs.\n\nCompleted edits were left in place. Use Undo to revert the whole run.",donePairs,totalPairs),"Pairwise Multi-Track Aligner",0)
  elseif failures>0 then
    reaper.MB(string.format("Alignment finished with %d clip-pair failure(s). See the REAPER console for details.",failures),"Pairwise Multi-Track Aligner",0)
  end
end

local function next_pair_indices()
  clipIndex=clipIndex+1
  if clipIndex>expected then
    clipIndex=1
    targetIndex=targetIndex+1
  end
end

local function process_one_pair()
  if targetIndex>#tracks then
    close_job(false)
    return
  end

  local targetName=track_name(tracks[targetIndex])
  status=string.format("%s — clip %d of %d",targetName,clipIndex,expected)
  draw_ui()

  local ok,detail=align_pair(tracks[1],tracks[targetIndex],lists[1][clipIndex],lists[targetIndex][clipIndex],sr)
  donePairs=donePairs+1
  if ok then
    okPairs=okPairs+1
  else
    failures=failures+1
    report[#report+1]=string.format("%s clip %d: %s",targetName,clipIndex,detail or "unknown error")
  end

  if donePairs%5==0 then reaper.UpdateArrange() end
  next_pair_indices()
end

local function loop()
  if finished then return end

  local ch=gfx.getchar()
  if ch<0 then
    close_job(true)
    return
  end

  local mouseDown=(gfx.mouse_cap & 1)==1
  if mouseDown and not lastMouseDown and inside(BTN_X,BTN_Y,BTN_W,BTN_H) then
    close_job(true)
    return
  end
  lastMouseDown=mouseDown

  process_one_pair()
  if not finished then
    draw_ui()
    reaper.defer(loop)
  end
end

-- Ensure an interrupted script still closes the Undo block.
reaper.atexit(function()
  if not finished then close_job(true) end
end)

draw_ui()
reaper.defer(loop)
