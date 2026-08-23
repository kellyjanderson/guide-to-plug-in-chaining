-- Guide to Plug-In Chaining: Automatic Aligned Layer-Mode Combiner
--
-- USER WORKFLOW
--   1. Select 3-8 source tracks containing independently processed copies of the same audio.
--   2. Run this script.
--   3. Choose a combine mode and strength.
--   4. The script:
--        - chooses the topmost selected track as the reference,
--        - invokes 01_aligner.lua automatically on one audio anchor item per selected track,
--        - stem-renders each aligned source track so splits/gaps become one continuous PCM item,
--        - routes those normalized stems into the Layer Mode Combiner JSFX,
--        - renders one new combined stereo track,
--        - deletes temporary work tracks,
--        - leaves the original selected source tracks muted.
--
-- IMPORTANT
--   * The alignment stage is non-destructive. Its one-sample timing corrections may exist as
--     literal timeline gaps; the stem render converts those gaps into zero-valued PCM samples.
--   * The earliest audio item on each selected source track is used as that track's alignment
--     anchor. This matches the intended workflow of independently processed copies of the same
--     source. More general multi-item initial alignment can be added later.
--   * The JSFX engine supports up to 8 stereo branches.
--   * Photo-derived nonlinear modes are creative operators and are not forensic-neutral.
--
-- Requires these files beside this script:
--   01_aligner.lua
--   02_layer_mode_combiner.jsfx

local MAX_BRANCHES = 8
local STEM_RENDER_STEREO = 40788 -- Track: Render tracks to stereo stem tracks (and mute originals)

local MODES = {
  mean=0,
  add=1,
  median=2,
  ["trimmed mean"]=3,
  trimmed=3,
  difference=4,
  subtract=5,
  ["min magnitude"]=6,
  min=6,
  ["max magnitude"]=7,
  max=7,
  lighten=8,
  darken=9,
  multiply=10,
  screen=11,
  overlay=12,
  ["hard light"]=13,
  hardlight=13,
  ["soft light"]=14,
  softlight=14,
  exclusion=15,
  consensus=16,
}

local MODE_NAMES = {
  [0]="Mean", [1]="Add", [2]="Median", [3]="Trimmed Mean", [4]="Difference",
  [5]="Subtract", [6]="Min Magnitude", [7]="Max Magnitude", [8]="Lighten",
  [9]="Darken", [10]="Multiply", [11]="Screen", [12]="Overlay", [13]="Hard Light",
  [14]="Soft Light", [15]="Exclusion", [16]="Consensus"
}

local function script_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("^(.*[\\/])") or ""
end

local function msg(s)
  reaper.ShowConsoleMsg(tostring(s) .. "\n")
end

local function selected_tracks()
  local tracks = {}
  for i=0,reaper.CountSelectedTracks(0)-1 do
    tracks[#tracks+1] = reaper.GetSelectedTrack(0,i)
  end
  table.sort(tracks, function(a,b)
    return reaper.GetMediaTrackInfo_Value(a,"IP_TRACKNUMBER") < reaper.GetMediaTrackInfo_Value(b,"IP_TRACKNUMBER")
  end)
  return tracks
end

local function track_name(tr)
  local _, name = reaper.GetTrackName(tr, "")
  return name ~= "" and name or ("Track " .. math.floor(reaper.GetMediaTrackInfo_Value(tr,"IP_TRACKNUMBER")))
end

local function first_audio_item(tr)
  local best, bestPos
  for i=0,reaper.CountTrackMediaItems(tr)-1 do
    local item = reaper.GetTrackMediaItem(tr,i)
    local take = reaper.GetActiveTake(item)
    if take and not reaper.TakeIsMIDI(take) then
      local pos = reaper.GetMediaItemInfo_Value(item,"D_POSITION")
      if not best or pos < bestPos then best,bestPos=item,pos end
    end
  end
  return best
end

local function clear_item_selection()
  for i=0,reaper.CountMediaItems(0)-1 do
    reaper.SetMediaItemSelected(reaper.GetMediaItem(0,i), false)
  end
end

local function clear_track_selection()
  for i=0,reaper.CountTracks(0)-1 do
    reaper.SetTrackSelected(reaper.GetTrack(0,i), false)
  end
end

local function select_only_tracks(tracks)
  clear_track_selection()
  for _,tr in ipairs(tracks) do reaper.SetTrackSelected(tr,true) end
end

local function choose_mode()
  local ok, values = reaper.GetUserInputs(
    "Aligned Layer-Mode Combiner",
    2,
    "Mode (median/mean/trimmed/consensus/etc),Strength 0-1",
    "median,1.0"
  )
  if not ok then return nil end
  local modeText, strengthText = values:match("^%s*(.-)%s*,%s*(.-)%s*$")
  if not modeText then return nil, "Enter values as: mode,strength" end
  modeText = modeText:lower():gsub("_"," "):gsub("%-"," "):gsub("%s+"," ")
  local mode = MODES[modeText]
  if mode == nil then
    return nil, "Unknown mode: " .. modeText .. "\nTry median, mean, trimmed, consensus, difference, multiply, screen, overlay, etc."
  end
  local strength = tonumber(strengthText) or 1.0
  strength = math.max(0, math.min(1, strength))
  return mode, strength
end

local function all_track_guids()
  local t = {}
  for i=0,reaper.CountTracks(0)-1 do
    local tr = reaper.GetTrack(0,i)
    local guid = reaper.GetTrackGUID(tr)
    t[guid]=true
  end
  return t
end

local function tracks_not_in(before)
  local out={}
  for i=0,reaper.CountTracks(0)-1 do
    local tr=reaper.GetTrack(0,i)
    if not before[reaper.GetTrackGUID(tr)] then out[#out+1]=tr end
  end
  return out
end

local function file_read(path)
  local f=io.open(path,"rb")
  if not f then return nil end
  local d=f:read("*a")
  f:close()
  return d
end

local function file_write(path,data)
  local f=io.open(path,"wb")
  if not f then return false end
  f:write(data)
  f:close()
  return true
end

local function ensure_jsfx_installed()
  local srcPath = script_dir() .. "02_layer_mode_combiner.jsfx"
  local data = file_read(srcPath)
  if not data then return nil, "Could not read " .. srcPath end

  local resource = reaper.GetResourcePath()
  local sep = package.config:sub(1,1)
  local effectsDir = resource .. sep .. "Effects" .. sep .. "GuideToPluginChaining"
  reaper.RecursiveCreateDirectory(effectsDir,0)
  local dst = effectsDir .. sep .. "LayerModeCombiner"
  if not file_write(dst,data) then return nil, "Could not install JSFX engine to " .. dst end
  return "JS: GuideToPluginChaining/LayerModeCombiner"
end

local function prepare_alignment_items(tracks)
  clear_item_selection()
  local anchors={}
  for i,tr in ipairs(tracks) do
    local item=first_audio_item(tr)
    if not item then return nil, "No audio item found on " .. track_name(tr) end
    anchors[#anchors+1]=item
    reaper.SetMediaItemSelected(item,true)
  end
  return anchors
end

local function run_aligner()
  local path = script_dir() .. "01_aligner.lua"
  local f=io.open(path,"rb")
  if not f then return false, "Could not find aligner beside combiner: " .. path end
  f:close()
  local ok, err = pcall(dofile,path)
  if not ok then return false, "Aligner failed: " .. tostring(err) end
  return true
end

local function render_tracks_to_stems(sourceTracks)
  select_only_tracks(sourceTracks)
  local before=all_track_guids()
  reaper.Main_OnCommand(STEM_RENDER_STEREO,0)
  local newTracks=tracks_not_in(before)
  if #newTracks ~= #sourceTracks then
    return nil, string.format("Expected %d rendered stem tracks, but found %d new tracks.",#sourceTracks,#newTracks)
  end
  table.sort(newTracks, function(a,b)
    return reaper.GetMediaTrackInfo_Value(a,"IP_TRACKNUMBER") < reaper.GetMediaTrackInfo_Value(b,"IP_TRACKNUMBER")
  end)
  return newTracks
end

local function make_bus(branches, mode, strength, fxName)
  local idx=reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx,true)
  local bus=reaper.GetTrack(0,idx)
  reaper.GetSetMediaTrackInfo_String(bus,"P_NAME","__COMBINER_WORK_BUS",true)
  reaper.SetMediaTrackInfo_Value(bus,"I_NCHAN",math.max(2,#branches*2))

  for i,tr in ipairs(branches) do
    reaper.SetMediaTrackInfo_Value(tr,"B_MAINSEND",0)
    reaper.SetMediaTrackInfo_Value(tr,"B_MUTE",0)
    local send=reaper.CreateTrackSend(tr,bus)
    reaper.SetTrackSendInfo_Value(tr,0,send,"I_SRCCHAN",0) -- stereo source ch 1/2
    reaper.SetTrackSendInfo_Value(tr,0,send,"I_DSTCHAN",(i-1)*2)
    reaper.SetTrackSendInfo_Value(tr,0,send,"D_VOL",1.0)
  end

  local fx=reaper.TrackFX_AddByName(bus,fxName,false,-1)
  if fx < 0 then return nil,"Could not instantiate "..fxName end

  -- JSFX sliders are exposed as normalized parameters.
  reaper.TrackFX_SetParamNormalized(bus,fx,0,(#branches-2)/(MAX_BRANCHES-2)) -- active branches 2..8
  reaper.TrackFX_SetParamNormalized(bus,fx,1,mode/16)
  reaper.TrackFX_SetParamNormalized(bus,fx,2,strength)
  if mode==16 then reaper.TrackFX_SetParamNormalized(bus,fx,3,0.5) end -- consensus threshold
  reaper.TrackFX_SetParamNormalized(bus,fx,4,0.5) -- "Divide by branches" midpoint by default
  return bus
end

local function render_bus(bus, mode)
  select_only_tracks({bus})
  local before=all_track_guids()
  reaper.Main_OnCommand(STEM_RENDER_STEREO,0)
  local created=tracks_not_in(before)
  if #created ~= 1 then return nil,"Could not identify the final combined render track." end
  local out=created[1]
  reaper.GetSetMediaTrackInfo_String(out,"P_NAME","Combined - "..MODE_NAMES[mode],true)
  return out
end

local sourceTracks=selected_tracks()
if #sourceTracks < 3 then
  reaper.MB("Select at least 3 source tracks. The topmost selected track is the alignment reference.","Aligned Layer-Mode Combiner",0)
  return
end
if #sourceTracks > MAX_BRANCHES then
  reaper.MB("The current combiner supports at most "..MAX_BRANCHES.." stereo branches.","Aligned Layer-Mode Combiner",0)
  return
end

local mode,strengthOrErr=choose_mode()
if mode==nil then
  if strengthOrErr then reaper.MB(strengthOrErr,"Aligned Layer-Mode Combiner",0) end
  return
end
local strength=strengthOrErr

local fxName,fxErr=ensure_jsfx_installed()
if not fxName then reaper.MB(fxErr,"Aligned Layer-Mode Combiner",0); return end

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

local ok,err=prepare_alignment_items(sourceTracks)
if not ok then
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Combiner aborted",-1)
  reaper.MB(err,"Aligned Layer-Mode Combiner",0)
  return
end

ok,err=run_aligner()
if not ok then
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Combiner aborted",-1)
  reaper.MB(err,"Aligned Layer-Mode Combiner",0)
  return
end

local stems,stemErr=render_tracks_to_stems(sourceTracks)
if not stems then
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Combiner aborted",-1)
  reaper.MB(stemErr,"Aligned Layer-Mode Combiner",0)
  return
end

local bus,busErr=make_bus(stems,mode,strength,fxName)
if not bus then
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Combiner aborted",-1)
  reaper.MB(busErr,"Aligned Layer-Mode Combiner",0)
  return
end

local output,outErr=render_bus(bus,mode)
if not output then
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Combiner aborted",-1)
  reaper.MB(outErr,"Aligned Layer-Mode Combiner",0)
  return
end

-- Temporary rendered branches and bus are no longer needed: the final stem is independent.
for _,tr in ipairs(stems) do reaper.DeleteTrack(tr) end
reaper.DeleteTrack(bus)

-- User-requested final state: originals muted, combined result selected and audible.
for _,tr in ipairs(sourceTracks) do reaper.SetMediaTrackInfo_Value(tr,"B_MUTE",1) end
clear_track_selection()
reaper.SetTrackSelected(output,true)
reaper.SetMediaTrackInfo_Value(output,"B_MUTE",0)

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Align and combine selected tracks - "..MODE_NAMES[mode],-1)

msg(string.format("Combined %d tracks with %s at %.0f%% strength. Original source tracks are muted.",#sourceTracks,MODE_NAMES[mode],strength*100))
