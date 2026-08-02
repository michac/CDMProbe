-- RenderLab.lua — THE CLEAN-SLATE RENDER LAB (`/cdmp rt lab`).
--
-- WHY THIS FILE EXISTS, AND WHY IT SHARES NOTHING.
-- The cue ring's rotation reads wrong in play: the spin stalls, then races, then stalls
-- again, forever.  Six builds chased it.  Every hypothesis so far has been about OUR
-- scaffolding — the spin period, the echo's counter-rotation, an alpha bug in the
-- dialling rig, a path-dependence between two ways of reaching the same rung — and three
-- of those were wrong.  A SavedVariables capture of every widget field on both paths
-- found exactly one differing field (`popPlaying`) and byte-identical settled state, so
-- it is not widget configuration and not pop residue.
--
-- So this stops theorising about our implementation and asks whether the artefact is
-- inherent to the IDEA: two counter-rotating additive green rings.  Three subagents,
-- blind to this repository, each wrote one implementation from the same pinned brief
-- (same sprite, same colour, 40 px inner / 60 px outer, opposite directions) with
-- periods / blend mode / draw layers / easing left free.  Read the result like an
-- experiment:
--   all three surge  -> the artefact is in the concept, the art, or the animation API,
--                       and no amount of fixing Renderer.lua will help;
--   none surge       -> the artefact is ours, and diffing their shape against ours
--                       localises it immediately;
--   some surge       -> whatever differs between them IS the mechanism.
--
-- ISOLATION IS THE EXPERIMENT.  This file shares no helper with RenderTest.lua, draws no
-- cue, and never touches Renderer.lua — a lab that borrowed our rig would be measuring
-- our rig again.  The small duplications below (icon art, the caption row) are therefore
-- deliberate, not an oversight.  It is also all disposable: when the question is answered
-- this file, the three RenderLab*.lua and their four .toc lines are one `git rm`.
--
-- The panels carry REAL Warlock spell art because the cue's washout problem only exists
-- against busy art — a flat backdrop flatters every implementation equally.

local ADDON, ns = ...

local LAB_N = 3
local TITLES = { "A1 minimal", "A2 wow-developer", "A3 detailed" }

-- Long-standing Warlock spellIDs; the texture resolves regardless of known/spec, and
-- `C_Spell.GetSpellTexture` hands back nil for any dud (we fall back to a dark fill).
local ART_SPELLS = { 105174, 686, 30146 }
local ICON_DARK = { 0.12, 0.13, 0.16, 1 }

local PANEL = 48          -- the panel every implementation is handed, in logical px
local ZOOM = 2            -- `rt lab N` magnifies ONE panel; geometry stays identical
local ROW_X = { -190, 0, 190 }
local PANEL_Y = 40

local lab   -- { container, panels[], titles[], descs[], called[] }

local function build()
  if lab then return lab end
  local container = CreateFrame("Frame", "CDMProbeRenderLab", UIParent)
  container:SetSize(660, 280)
  container:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
  container:SetFrameStrata("HIGH")
  lab = { container = container, panels = {}, titles = {}, descs = {}, called = {} }

  for i = 1, LAB_N do
    local panel = CreateFrame("Frame", nil, container)
    panel:SetSize(PANEL, PANEL)
    local edge = panel:CreateTexture(nil, "BACKGROUND")
    edge:SetPoint("TOPLEFT", panel, "TOPLEFT", -1, 1)
    edge:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 1, -1)
    edge:SetColorTexture(0.40, 0.40, 0.46, 1)
    local fill = panel:CreateTexture(nil, "BACKGROUND", nil, 1)
    fill:SetAllPoints(panel)
    local tex = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(ART_SPELLS[i])
    if tex then
      fill:SetTexture(tex)
      fill:SetTexCoord(0.07, 0.93, 0.07, 0.93)   -- trim the stock icon border
    else
      fill:SetColorTexture(ICON_DARK[1], ICON_DARK[2], ICON_DARK[3], ICON_DARK[4])
    end
    lab.panels[i] = panel

    -- The captions live on the CONTAINER, not on the panel: `rt lab N` scales the panel
    -- to magnify the rings, and a caption riding it would blow up with them.
    local title = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    local desc = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetJustifyH("CENTER")
    desc:SetPoint("TOP", title, "BOTTOM", 0, -3)
    desc:SetTextColor(0.66, 0.72, 0.66)
    lab.titles[i], lab.descs[i] = title, desc
  end
  return lab
end

-- Call one implementation, ONCE per session.  The harness owns the caching so the agents'
-- code did not have to be idempotent, and each call is pcall'd so a thrower names its own
-- panel instead of taking the addon down mid-`/reload`.
local function invoke(i, panel)
  if lab.called[i] then return end
  lab.called[i] = true
  local fn = ns.RenderLabImpl and ns.RenderLabImpl[i]
  if type(fn) ~= "function" then
    lab.called[i] = "missing"
    return
  end
  local ok, err = pcall(fn, panel)
  if not ok then
    lab.called[i] = "error"
    ns.Printf("|cffff6666rt lab: implementation %d threw|r — %s", i, tostring(err))
  end
end

local function caption(i)
  if lab.called[i] == "missing" then return "|cffff6666not loaded|r" end
  if lab.called[i] == "error" then return "|cffff6666threw — see chat|r" end
  local info = ns.RenderLabInfo and ns.RenderLabInfo[i]
  return type(info) == "string" and info or "(no description)"
end

local function show(only)
  build()
  -- No existing cues on screen: the lab is judged against a clean field.
  if ns._renderTestRig then ns._renderTestRig.container:Hide() end

  for i = 1, LAB_N do
    local panel, title, desc = lab.panels[i], lab.titles[i], lab.descs[i]
    if only and i ~= only then
      panel:Hide(); title:Hide(); desc:Hide()
    else
      local x = only and 0 or ROW_X[i]
      panel:SetScale(only and ZOOM or 1)
      panel:ClearAllPoints()
      -- Anchored through the scale: a scaled child's offsets are in ITS OWN units, so
      -- divide, or the magnified panel walks off centre.
      local s = only and ZOOM or 1
      panel:SetPoint("CENTER", lab.container, "CENTER", x / s, PANEL_Y / s)
      panel:Show()
      title:ClearAllPoints()
      title:SetPoint("TOP", lab.container, "CENTER", x, -40)
      title:SetText(TITLES[i])
      title:Show()
      desc:SetWidth(only and 460 or 176)
      desc:SetText(caption(i))
      desc:Show()
      invoke(i, panel)          -- AFTER sizing/positioning/showing: the brief promised that
      desc:SetText(caption(i))  -- ...and re-read, in case the call is the thing that set it
    end
  end
  lab.container:Show()
end

-- `/cdmp rt lab [1|2|3]` — three blind implementations of the spinning ring, or one of
-- them magnified.  Reached from ns.RenderTest so `/cdmp rt off` still tears the whole
-- render test down through the one existing door.
function ns.RenderLab(which)
  local only = tonumber(which)
  if only and (only < 1 or only > LAB_N) then only = nil end
  show(only)
  ns.Heading("rt lab — three blind implementations of the spinning ring")
  for i = 1, LAB_N do
    if not only or i == only then
      ns.Printf("  |cff88ff88%s|r — %s", TITLES[i], caption(i))
    end
  end
  if only then
    ns.Printf("magnified %dx (geometry unchanged) — |cffffffff/cdmp rt lab|r for all three", ZOOM)
  else
    ns.Print("|cffffffff/cdmp rt lab 1|2|3|r for one panel magnified · "
      .. "|cffffffff/cdmp rt off|r to clear")
  end
  ns.Print("watch each panel: does the spin stall and race, or run steady?")
end

-- Any other `rt` view drops the lab.  Cheap and total: hiding the container hides every
-- ring, and nothing here has a timer of its own.
function ns.RenderLabHide()
  if lab then lab.container:Hide() end
end
