-- HudDriver.lua — the LIVE W4 pipeline driver, THE `/cdmp hud` HUD.
--
-- WHAT THIS IS.  The whole W4 refactor built the pipeline bottom-up and verified each
-- stage off-game; this is the thing that RUNS them in sequence on the live client:
--
--     State.Build  ->  Coach:Compute  ->  Binder:Bind(guidance, layout)  ->  Renderer:Draw
--       (pulse)         (Guidance)          (DrawList)                         (pixels)
--
-- This IS the HUD now: the W4 cutover retired the old HudChrome/HudBoard/HudScore engine
-- and reclaimed `/cdmp hud` for the pipeline.  The transitional `hud2` alias and its two
-- one-shot login migrations were dropped in v0.32.34; nothing is called `hud2` any more.
-- `/cdmp hud` toggles it; `/cdmp hud off` clears it, leaving Blizzard's UI pixel-clean.
--
-- THE TRIGGER (reuse the poll cadence).  A dedicated ~10 Hz ticker rebuilds the pulse
-- and redraws.  It Acquire()s State's event INGESTION (override/history/combat +
-- napkin/keybinds) via State's ref-counted lifecycle, and Release()s it when off.
-- Event-driven + napkin-scheduled wakeups stay a later optimisation, exactly as State's
-- header frames it.  The live Layout is re-scanned each tick (cheap — a handful of
-- frames); a RefreshLayout-hook-driven refresh is that same later optimisation.
--
-- THE TWO SEAMS wired here (the fixtures faked them in the Phase-2/4 tests):
--   * Coach cfg.shardCost  = ns.ShardCost      the live HoG-cost reader.
--   * Binder cfg.keybindFor = ns.HudBinds.Get  the live action-bar keybind scan.
--
-- COMBAT-SAFE.  State.Build is Secret-Value-guarded; Coach/Binder are pure; the Renderer
-- only creates + points OUR OWN textures (never a protected action).  The tick is pcall'd
-- anyway — a throw in a ticker is silent and must never wedge the client.
local ADDON, ns = ...

ns.HudDriver = {}
local D = ns.HudDriver

D.on = false
D.ticker = nil

-- HUD-on predicate the HudProcGlow hooks read (the native-proc-glow dim is gated on it,
-- since hooksecurefunc hooks can never be uninstalled).
function ns.HudOn() return D.on end
D.lastCues = 0        -- diagnostics: cues drawn on the last tick
D.lastError = nil     -- diagnostics: last tick error text (nil = clean)

local TICK_PERIOD = 0.1   -- ~10 Hz, matching State's poll + the old HUD's cadence

-- The three persistent pipeline instances, built once on first enable.  Pure factories,
-- so re-use is free and holds the Renderer's frame/texture pool + handle registry.
local function ensureInstances()
  if not D.coach then
    D.coach = ns.Coach.New({ shardCost = ns.ShardCost })
  end
  if not D.binder then
    -- No keybindFor seam live: keybinds come from STATE (stitched onto the layout in
    -- tick()), the single resolver.  The seam stays a test-only injection point.
    D.binder = ns.Binder.New({})
  end
  if not D.renderer then
    D.renderer = ns.Renderer.New()
  end
end

--------------------------------------------------------------------------------
-- One pipeline pass: pulse -> guidance -> drawList -> pixels.
--------------------------------------------------------------------------------
-- Build(false): does NOT drain State's pending-events delta (the Coach reads `history`,
-- not `events`, so the driver never needs the drain — the bounded `pending` ring just
-- keeps the last N events).
-- One-shot chat notice when the resolved spec is UNSUPPORTED (HUD goes passive), so going
-- dark isn't silent.  Latched per distinct specID: a Demo->Aff->Demo->Aff swap notices Aff
-- once until the resolution changes away and back.  Supported specs stay quiet (ActiveSpec
-- present clears the latch) — Demonology never announces itself.
local function maybeNotifyUnsupported()
  if ns.ActiveSpec ~= nil then
    D.notifiedSpecID = nil   -- supported / unresolved: re-arm for a later swap to passive
    return
  end
  local id = ns.detectedSpecID
  if id == nil or id == D.notifiedSpecID then return end
  D.notifiedSpecID = id
  ns.Printf("HUD |cffff8080passive|r — no profile for %s (spec %d); "
    .. "only Demonology is supported. |cffffffff/cdmp hud status|r for details.",
    ns.detectedSpecName or "this spec", id)
end

local function tick()
  maybeNotifyUnsupported()
  local pulse = ns.State.Build(false)
  local guidance = D.coach:Compute(pulse)
  -- Live Layout + registry from the same icon-viewer walk (Phase 5a).  Register every
  -- handle -> frame so the Renderer can anchor a cue dot inside its icon corner.
  local layout, registry = ns.HudLayout.Scan()
  -- VIRTUAL ENTRIES — our own icons for the rotation buttons the CDM tracks nowhere
  -- (State synthesised the rows; HudVirtual pools the frames).  They merge in as just
  -- another Layout entry + registry frame under a NEGATIVE handle, so the Binder and the
  -- Renderer below are unchanged and cannot tell them apart — that is the seam's whole
  -- success criterion (docs/virtual-cdm-plan.md).  Merged BEFORE the keybind stitch, which
  -- skips them harmlessly: `pulse.cooldowns` has no negative keys, and HudVirtual.Sync has
  -- already resolved their keybind off the base spellID.
  local vLayout, vRegistry = ns.HudVirtual.Sync(pulse)
  for cid, entry in pairs(vLayout) do layout[cid] = entry end
  for cid, frame in pairs(vRegistry) do registry[cid] = frame end
  -- STITCH State's keybind onto the layout by cooldownID (P5d fix).  State already
  -- resolved a keybind per cooldown off the CDM database id — the single, correct
  -- resolver — so the cue hint uses THAT rather than the Binder re-deriving it from a
  -- divergent base id (which missed HoG/Dreadstalkers while State got them right).
  local cds = pulse.cooldowns or {}
  for cid, entry in pairs(layout) do
    local cd = cds[cid]
    if cd then entry.keybind = cd.keybind end
  end
  for handle, frame in pairs(registry) do D.renderer:Register(handle, frame) end
  local drawList = D.binder:Bind(guidance, layout)
  D.renderer:Draw(drawList)
  -- Our own icons read the SAME DrawList the Renderer just drew: a cue on their negative
  -- handle raises them out of their resting dim.  After Draw, so the two never disagree.
  ns.HudVirtual.Reflect(drawList)
  D.lastCues = drawList.cues and #drawList.cues or 0
  -- Re-hook newly-pooled CDM frames + re-apply the native-proc-glow dim (idempotent,
  -- cheap — a per-instance flag skips already-hooked frames).
  if ns.HudProcGlow then ns.HudProcGlow.Install() end
  -- Decision log — append one greppable line on any decision change.  Inside the
  -- pcall'd tick, so a logging throw can never wedge the HUD.
  if ns.DecisionLog then ns.DecisionLog.Record(pulse, guidance, drawList) end
end

local function safeTick()
  local ok, err = pcall(tick)
  if ok then
    D.lastError = nil
  else
    D.lastError = tostring(err)   -- surfaced by `/cdmp hud status`, never spammed
  end
end

--------------------------------------------------------------------------------
-- Enable / disable
--------------------------------------------------------------------------------
function ns.SetHud(on)
  on = on and true or false
  ns.db = ns.db or {}
  ns.db.hud = on
  if on == D.on then return end
  D.on = on
  if on then
    ensureInstances()
    ns.State.Acquire()                    -- ingestion live (State's ref-counted lifecycle)
    if ns.HudProcGlow then ns.HudProcGlow.Install() end  -- dim the native proc glow (hooks + one pass)
    if not D.ticker then D.ticker = C_Timer.NewTicker(TICK_PERIOD, safeTick) end
    safeTick()                            -- draw immediately, don't wait a tick
    ns.Print("HUD |cff88ff88ON|r — the W4 pipeline (State -> Coach -> Binder -> Renderer). "
      .. "|cffffffff/cdmp hud off|r to clear.")
  else
    if D.ticker then D.ticker:Cancel(); D.ticker = nil end
    if D.renderer then pcall(D.renderer.Draw, D.renderer, {}) end  -- clear every dot/panel/pip
    pcall(ns.HudVirtual.Clear)                                     -- ...and our own icons
    if ns.HudProcGlow then pcall(ns.HudProcGlow.Restore) end       -- native proc glow back to full alpha
    ns.State.Release()
    ns.Print("HUD |cffff8080OFF|r — pipeline overlay cleared.")
  end
end

--------------------------------------------------------------------------------
-- Layout inspection (Phase 5a) — dump the live Layout + registry, draws nothing.
--------------------------------------------------------------------------------
local function dumpLayout()
  local layout, registry = ns.HudLayout.Scan()
  -- The keybind the cue will actually use comes from STATE (stitched by cooldownID), so
  -- show that, not a re-lookup — this is the row to read when a key is missing.
  local cds = ns.State.Build(false).cooldowns or {}
  ns.Heading("HUD live Layout (icon viewers -> cooldownID -> spellID + State keybind)")
  local ids = {}
  for cid in pairs(layout) do ids[#ids + 1] = cid end
  table.sort(ids)
  if #ids == 0 then
    return ns.Print("  |cffff4040no icons|r — are the Cooldown Manager viewers enabled/shown?")
  end
  for _, cid in ipairs(ids) do
    local e = layout[cid]
    local frame = registry[cid]
    local kb = cds[cid] and cds[cid].keybind
    ns.Printf("  cd=%d  spellID=%s (%s)  key=%s  frame=%s",
      cid, tostring(e.spellID), (e.spellID and ns.SpellName(e.spellID)) or "?",
      kb and ("|cff88ff88" .. kb .. "|r") or "|cff808080none|r",
      frame and "|cff88ff88bound|r" or "|cffff4040nil|r")
  end
  ns.Printf("  %d displayed icon(s). |cff808080key=none|r = State resolved no bind (unbound / unresolvable).", #ids)
end

--------------------------------------------------------------------------------
-- Status readout
--------------------------------------------------------------------------------
local function status()
  ns.Heading("HUD (W4 pipeline driver) status")
  ns.Printf("  state: %s   ingestion consumers: %d",
    D.on and "|cff88ff88ON|r" or "|cffff8080OFF|r",
    ns.State.consumers or 0)
  -- Which spec resolved, and whether it carries a profile (Phase 5).  ns.ActiveSpec set =>
  -- a registered spec is driving the pipeline; nil => passive (detected but no profile).
  if ns.ActiveSpec then
    ns.Printf("  spec: %s |cff88ff88(profile active)|r", ns.detectedSpecName or "?")
  else
    ns.Printf("  spec: %s |cffff8080— no profile, HUD passive|r", ns.detectedSpecName or "?")
  end
  ns.Printf("  last tick: %d cue(s) drawn%s", D.lastCues,
    D.lastError and ("   |cffff4040error:|r " .. D.lastError) or "   |cff88ff88clean|r")
  ns.Print("  |cffffffff/cdmp hud layout|r dumps the live Layout.")
end

--------------------------------------------------------------------------------
-- Command
--------------------------------------------------------------------------------
-- THE `/cdmp hud` command (reclaimed at the W4 cutover; the transitional alias that carried
-- muscle memory across it was dropped in v0.32.34).
local function hudCommand(rest)
  rest = (rest or ""):lower()
  if rest:find("layout") then return dumpLayout() end
  if rest:find("status") then return status() end
  if rest:find("off") then return ns.SetHud(false) end
  if rest:find("on") then return ns.SetHud(true) end
  ns.SetHud(not D.on)
end
ns.RegisterCommand("hud",
  "the HUD — the W4 pipeline (State -> Coach -> Binder -> Renderer). 'hud on|off' set it; 'hud layout' dumps the live Layout; 'hud status' the readout.",
  hudCommand)

-- /cdmp reset — turn the HUD off.  (The old engine + the probe that also hung off this
-- command are gone; the HUD is the only "experiment" left to reset.)
ns.RegisterCommand("reset", "turn the HUD off", function()
  if D.on then ns.SetHud(false) end
end)

-- Restore on login (wrap the existing chain).
local prevOnLogin = ns.OnLogin
function ns.OnLogin()
  if prevOnLogin then prevOnLogin() end
  -- `ns.db.hud` is the pipeline's enable BOOL (reclaimed at the W4 cutover from the retired
  -- old engine, which stored a SETTINGS TABLE under the same key).  The table-shaped value is
  -- still dropped on sight — it is a type confusion, not a version we can read.
  -- (The two one-shot migrations of the W4-era keys that lived here were removed in
  --  v0.32.34, verified folded: neither key remains in SavedVariables.)
  if ns.db and type(ns.db.hud) == "table" then ns.db.hud = nil end
  if ns.db and ns.db.hud then
    C_Timer.After(1.0, function() ns.SetHud(true) end)
  end
end
