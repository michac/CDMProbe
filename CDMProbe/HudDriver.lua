-- HudDriver.lua — the LIVE W4 pipeline driver (Phase 5c), behind `/cdmp hud2`.
--
-- WHAT THIS IS (docs/w4-phase5-cutover-plan.md 5c).  The whole W4 refactor built the
-- pipeline bottom-up and verified each stage off-game; this is the first thing that
-- RUNS them in sequence on the live client:
--
--     State.Build  ->  Coach:Compute  ->  Binder:Bind(guidance, layout)  ->  Renderer:Draw
--       (pulse)         (Guidance)          (DrawList)                         (pixels)
--
-- It runs ALONGSIDE the old `/cdmp hud` engine (cutover decision 1: flag-first parallel
-- run, delete only once proven), so it draws its own overlay without touching HudChrome/
-- HudBoard/HudScore.  `/cdmp hud2` toggles it; `/cdmp hud2 off` clears it, leaving
-- Blizzard's UI pixel-clean.  The old HUD is retired at the 5e cutover, not here.
--
-- THE TRIGGER (cutover decision: reuse the poll cadence).  A dedicated ~10 Hz ticker
-- rebuilds the pulse and redraws — matching the old engine's cadence.  It does NOT share
-- the statelog ring: it Acquire()s State's event INGESTION (override/history/combat +
-- napkin/keybinds) without turning on disk recording (State's ref-counted lifecycle).
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
-- Build(false): a DIAGNOSTIC build that does NOT drain State's pending-events delta
-- (the Coach reads `history`, not `events`, so the driver never needs the drain — and
-- leaving it lets the statelog session, if also running, still see the delta).
local function tick()
  local pulse = ns.State.Build(false)
  local guidance = D.coach:Compute(pulse)
  -- Live Layout + registry from the same icon-viewer walk (Phase 5a).  Register every
  -- handle -> frame so the Renderer can anchor a cue dot inside its icon corner.
  local layout, registry = ns.HudLayout.Scan()
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
  D.lastCues = drawList.cues and #drawList.cues or 0
  -- HUD2 decision log — append one greppable line on any decision change.  Inside the
  -- pcall'd tick, so a logging throw can never wedge the HUD.
  if ns.Hud2Log then ns.Hud2Log.Record(pulse, guidance, drawList) end
end

local function safeTick()
  local ok, err = pcall(tick)
  if ok then
    D.lastError = nil
  else
    D.lastError = tostring(err)   -- surfaced by `/cdmp hud2 status`, never spammed
  end
end

--------------------------------------------------------------------------------
-- Enable / disable
--------------------------------------------------------------------------------
function ns.SetHud2(on)
  on = on and true or false
  ns.db = ns.db or {}
  ns.db.hud2 = on
  if on == D.on then return end
  D.on = on
  if on then
    ensureInstances()
    ns.State.Acquire()                    -- ingestion live, WITHOUT the statelog ring
    if not D.ticker then D.ticker = C_Timer.NewTicker(TICK_PERIOD, safeTick) end
    safeTick()                            -- draw immediately, don't wait a tick
    ns.Print("HUD2 |cff88ff88ON|r — the W4 pipeline (State -> Coach -> Binder -> Renderer), "
      .. "running |cffffd100alongside|r the old HUD. |cffffffff/cdmp hud2 off|r to clear.")
  else
    if D.ticker then D.ticker:Cancel(); D.ticker = nil end
    if D.renderer then pcall(D.renderer.Draw, D.renderer, {}) end  -- clear every dot/panel/pip
    ns.State.Release()
    ns.Print("HUD2 |cffff8080OFF|r — pipeline overlay cleared.")
  end
end

--------------------------------------------------------------------------------
-- Layout inspection (Phase 5a) — dump the live Layout + registry, draws nothing.
--------------------------------------------------------------------------------
local function dumpLayout()
  local layout, registry = ns.HudLayout.Scan()
  -- The keybind the cue will actually use comes from STATE (stitched by cooldownID), so
  -- show that, not a re-lookup — this is the row to read when a key is missing.
  local cds = (ns.State and ns.State.Build) and (ns.State.Build(false).cooldowns or {}) or {}
  ns.Heading("HUD2 live Layout (icon viewers -> cooldownID -> spellID + State keybind)")
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
  ns.Heading("HUD2 (W4 pipeline driver) status")
  ns.Printf("  state: %s   ingestion consumers: %d   recording(statelog): %s",
    D.on and "|cff88ff88ON|r" or "|cffff8080OFF|r",
    ns.State.consumers or 0, ns.State.recording and "yes" or "no")
  ns.Printf("  last tick: %d cue(s) drawn%s", D.lastCues,
    D.lastError and ("   |cffff4040error:|r " .. D.lastError) or "   |cff88ff88clean|r")
  ns.Print("  |cffffffff/cdmp hud2 layout|r dumps the live Layout; runs alongside |cffffffff/cdmp hud|r.")
end

--------------------------------------------------------------------------------
-- Command
--------------------------------------------------------------------------------
ns.RegisterCommand("hud2",
  "the W4 pipeline HUD (State -> Coach -> Binder -> Renderer), a flag-gated PARALLEL run beside /cdmp hud (Phase 5c). 'hud2 on|off' set it; 'hud2 layout' dumps the live Layout; 'hud2 status' the readout.",
  function(rest)
    rest = (rest or ""):lower()
    if rest:find("layout") then return dumpLayout() end
    if rest:find("status") then return status() end
    if rest:find("off") then return ns.SetHud2(false) end
    if rest:find("on") then return ns.SetHud2(true) end
    ns.SetHud2(not D.on)
  end)

-- Fold into /cdmp reset ("turn every experiment off"), wrapping the existing chain.
local prevReset = ns.commands.reset and ns.commands.reset.fn
ns.RegisterCommand("reset", "turn every experiment off (HUD + HUD2 + probe/log off)", function(rest)
  if D.on then ns.SetHud2(false) end
  if prevReset then prevReset(rest) end
end)

-- Restore on login (wrap the existing chain), mirroring the old HUD's restore.
local prevOnLogin = ns.OnLogin
function ns.OnLogin()
  if prevOnLogin then prevOnLogin() end
  if ns.db and ns.db.hud2 then
    C_Timer.After(1.0, function() ns.SetHud2(true) end)
  end
end
