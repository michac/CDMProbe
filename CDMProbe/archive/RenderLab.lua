-- RenderLab.lua — THE RENDER LAB (`/cdmp rt lab`): panels on screen, and a RECORDER.
--
-- WHY THIS FILE EXISTS.
-- The cue ring's rotation reads wrong in play: the spin stalls, then races, then stalls
-- again, forever.  Six builds chased it, and every hypothesis was about our own
-- scaffolding — the spin period, the echo's counter-rotation, an alpha bug in the dialling
-- rig, a path-dependence between two routes to the same rung.  Three were wrong.  A
-- SavedVariables capture of every widget field on both paths found exactly one differing
-- field (`popPlaying`) and byte-identical settled state, so it is neither widget
-- configuration nor pop residue.
--
-- ROUND 1 (2026-08-01) asked whether the artefact is inherent to the IDEA.  Three
-- subagents, blind to this repository, each implemented two counter-rotating green rings
-- from one pinned brief.  VERDICT: it is not.  A2 and A3 — the two faithful readings, both
-- a single centred sprite spun by a looping Rotation animation — ran STEADY.  (A1 misread
-- "ring" as a necklace of orbiting sprites on a per-frame OnUpdate; its result is
-- discounted.)  So the concept, the art and the animation API are cleared, and the
-- artefact is ours.  Round 1's implementations are in git history at v0.32.72.
--
-- ROUND 2 walks the distance from A2's steady ring to Renderer.lua's surging one, ONE
-- difference per panel, with A2 itself as the control:
--
--   1  A2 control        6s/9s counter-rotating, no breathe, anchored once.  KNOWN STEADY.
--   2  B1 shipped nums   12.0s, echo locked in phase, light split .45/.55 — and nothing
--                        else.  Also closes round 1's one confound: A2 ran at 6s/9s, the
--                        Renderer runs at 12.0s, so "counter-rotation is fine" was only
--                        ever established at A2's periods.
--   3  B2 + breathe      B1 + the Alpha BOUNCE group Renderer.lua puts on the SAME texture.
--   4  B3 + 10Hz restate B1 + a ticker re-asserting size/anchor/colour every 0.1s, as
--                        `R:setDotGlow` does on every pipeline tick.
--
-- THE RECORDER IS THE POINT OF THIS ROUND.  A Rotation animation exposes `GetProgress()`,
-- so "does the spin surge" does not have to be a judgement from the chair — it is the
-- deviation between where the ring ACTUALLY is and where a uniform spin would have put it,
-- in degrees.  One command arms everything: `/cdmp rt lab` draws the panels AND samples
-- every rotation under them at 20 Hz, into `CDMProbeDB.rtlab`.  Play or just watch, then
-- `/reload` and run `uv run python -m wowkb.cdmp rtlab`.  Nothing is typed during the run
-- and nothing has to be eyeballed to get the number — the eye and the instrument are two
-- independent readings of the same panel, which is exactly what this problem has lacked.
--
-- ⚠ It records RAW (t, progress) samples and does the analysis on the desktop, the same
-- split as the decision log and `flight`: a capture can be re-analysed, a verdict computed
-- in Lua at 20 Hz cannot.
--
-- ISOLATION IS STILL THE EXPERIMENT.  This file shares no helper with RenderTest.lua, draws
-- no cue, and never touches Renderer.lua — a lab that borrowed our rig would be measuring
-- our rig again.  The small duplications below are deliberate.  It is also all disposable:
-- when the question is answered this file, the RenderLab*.lua panels, their .toc lines and
-- `cmd_rtlab` are one `git rm`.

local ADDON, ns = ...

local TITLES = { "A2 control 6/9s", "B1 shipped numbers", "B2 + breathe", "B3 + 10Hz restate" }
local LAB_N = #TITLES

-- Long-standing Warlock spellIDs; the texture resolves regardless of known/spec, and
-- `C_Spell.GetSpellTexture` hands back nil for any dud (we fall back to a dark fill).
-- Real spell art because the cue's washout only exists against BUSY art — a flat backdrop
-- flatters every implementation equally.
local ART_SPELLS = { 105174, 686, 30146, 1122 }
local ICON_DARK = { 0.12, 0.13, 0.16, 1 }

local PANEL = 48          -- the panel every implementation is handed, in logical px
local ZOOM = 2            -- `rt lab N` magnifies ONE panel; geometry stays identical
local ROW_X = { -255, -85, 85, 255 }
local PANEL_Y = 40

local SAMPLE_HZ = 20
local SAMPLE_SECS = 24    -- two full turns at the shipped 12.0s period

local lab   -- { container, panels[], titles[], descs[], called[] }
local rec   -- the live recording: { ticker, rings, t, p, fps, n }

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
    -- The icon art sits on BACKGROUND so ANY draw layer an implementation picks is above
    -- it — the panel must not silently decide a panel's layering for it.
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

-- Call one implementation, ONCE per session.  The harness owns the caching so the panels'
-- code does not have to be idempotent, and each call is pcall'd so a thrower names itself
-- instead of taking the addon down mid-`/reload`.
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

--------------------------------------------------------------------------------
-- THE RECORDER
--------------------------------------------------------------------------------

local function safe(obj, method)
  local fn = obj and obj[method]
  if type(fn) ~= "function" then return nil end
  local ok, v = pcall(fn, obj)
  if ok then return v end
  return nil
end

-- Walk a panel for every animatable region and collect its Rotation / Alpha animations.
-- DELIBERATELY GENERIC — it asks the widgets, not the code that made them, so it measures
-- a panel that never agreed to be measured (and would measure the live Renderer's rings
-- unchanged, if that is ever wanted).
local function collect(frame, panelIndex, out, depth)
  local regions = { frame:GetRegions() }
  for _, r in ipairs(regions) do
    if safe(r, "GetObjectType") == "Texture" then
      -- ⚠ BOTH of these return their members as VARARGS, so they must be packed at the
      -- call site.  A `safe()`-style single-value read would hand back the FIRST group and
      -- a widget's `type()` is "table", so it would sail through any is-this-a-list check
      -- and then iterate to nothing.
      local okg, groups = pcall(function() return { r:GetAnimationGroups() } end)
      for _, grp in ipairs(okg and groups or {}) do
        local oka, anims = pcall(function() return { grp:GetAnimations() } end)
        for _, anim in ipairs(oka and anims or {}) do
          local kind = safe(anim, "GetObjectType")
          if kind == "Rotation" or kind == "Alpha" then
            local w = safe(r, "GetWidth")
            out[#out + 1] = {
              anim = anim,
              panel = panelIndex,
              kind = kind,
              size = w and math.floor(w + 0.5) or 0,
              secs = safe(anim, "GetDuration") or 0,
              degrees = kind == "Rotation" and (safe(anim, "GetDegrees") or 0) or 0,
              looping = safe(grp, "GetLooping") or "?",
            }
          end
        end
      end
    end
  end
  if depth > 0 then
    for _, child in ipairs({ frame:GetChildren() }) do
      collect(child, panelIndex, out, depth - 1)
    end
  end
end

local function stopRecording()
  if rec and rec.ticker then rec.ticker:Cancel() end
  rec = nil
end

-- Flush what we have into SavedVariables.  Called on every tick rather than only at the
-- end, so a `/reload` part-way through a run still yields a readable capture — a recorder
-- that only pays out on clean completion is one you lose runs to.
local function flush()
  if not ns.db or not rec then return end
  local rings = {}
  for i, r in ipairs(rec.rings) do
    rings[i] = { panel = r.panel, title = TITLES[r.panel], kind = r.kind, size = r.size,
                 secs = r.secs, degrees = r.degrees, looping = r.looping,
                 info = ns.RenderLabInfo and ns.RenderLabInfo[r.panel] or nil }
  end
  ns.db.rtlab = {
    captured = date("%Y-%m-%d %H:%M:%S"),
    hz = SAMPLE_HZ, secs = SAMPLE_SECS, n = rec.n,
    rings = rings, t = rec.t, p = rec.p, fps = rec.fps,
  }
end

local function startRecording()
  stopRecording()
  local rings = {}
  for i = 1, LAB_N do collect(lab.panels[i], i, rings, 1) end
  if #rings == 0 then return 0 end
  rec = { rings = rings, t = {}, p = {}, fps = {}, n = 0, t0 = GetTime() }
  for i = 1, #rings do rec.p[i] = {} end
  local ticks = SAMPLE_HZ * SAMPLE_SECS
  rec.ticker = C_Timer.NewTicker(1 / SAMPLE_HZ, function()
    if not rec then return end
    local n = rec.n + 1
    rec.n = n
    rec.t[n] = math.floor((GetTime() - rec.t0) * 10000 + 0.5) / 10000
    rec.fps[n] = math.floor((GetFramerate() or 0) + 0.5)
    for i, r in ipairs(rec.rings) do
      local prog = safe(r.anim, "GetProgress")
      -- `false` is a real answer (a stopped animation) and must not read as 0 progress.
      rec.p[i][n] = type(prog) == "number"
        and math.floor(prog * 100000 + 0.5) / 100000 or -1
    end
    flush()
    if n >= ticks then
      stopRecording()
      ns.Print("|cff88ff88rt lab: recording complete|r — |cffffffff/reload|r, then "
        .. "|cffffffffuv run python -m wowkb.cdmp rtlab|r")
    end
  end, ticks)
  return #rings
end

--------------------------------------------------------------------------------

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
      local s = only and ZOOM or 1
      panel:SetScale(s)
      panel:ClearAllPoints()
      -- Anchored THROUGH the scale: a scaled child's offsets are in its own units, so
      -- divide, or the magnified panel walks off centre.
      panel:SetPoint("CENTER", lab.container, "CENTER", x / s, PANEL_Y / s)
      panel:Show()
      title:ClearAllPoints()
      title:SetPoint("TOP", lab.container, "CENTER", x, -40)
      title:SetText(TITLES[i])
      title:Show()
      desc:SetWidth(only and 500 or 158)
      desc:SetText(caption(i))
      desc:Show()
      invoke(i, panel)          -- AFTER sizing/positioning/showing: the brief promised that
      desc:SetText(caption(i))  -- ...and re-read, in case the call is what set it
    end
  end
  lab.container:Show()
end

-- `/cdmp rt lab [1|2|3|4]` — ONE COMMAND: draw the panels and arm the recorder.  Reached
-- from ns.RenderTest so `/cdmp rt off` still tears the whole render test down through the
-- one existing door.
function ns.RenderLab(which)
  local only = tonumber(which)
  if only and (only < 1 or only > LAB_N) then only = nil end
  show(only)
  ns.Heading("rt lab — walking A2's steady ring toward the Renderer's")
  for i = 1, LAB_N do
    if not only or i == only then
      ns.Printf("  |cff88ff88%d %s|r — %s", i, TITLES[i], caption(i))
    end
  end
  if only then
    ns.Printf("magnified %dx (geometry unchanged) — |cffffffff/cdmp rt lab|r for all %d "
      .. "+ the recorder", ZOOM, LAB_N)
    return
  end
  local n = startRecording()
  if n == 0 then
    ns.Print("|cffff6666no rotation animations found|r — nothing to record")
  else
    ns.Printf("|cff88ff88recording|r %d animation(s) at %d Hz for %ds — just watch, "
      .. "type nothing", n, SAMPLE_HZ, SAMPLE_SECS)
    ns.Print("then |cffffffff/reload|r and |cffffffffuv run python -m wowkb.cdmp rtlab|r")
  end
  ns.Print("|cffffffff/cdmp rt lab 1-4|r magnifies one · |cffffffff/cdmp rt off|r clears")
end

-- Any other `rt` view drops the lab.  Cheap and total: hiding the container hides every
-- ring, and stopping the ticker is the only other thing running.
function ns.RenderLabHide()
  stopRecording()
  if lab then lab.container:Hide() end
end
