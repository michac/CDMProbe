-- HudDriver.lua — the LIVE W4 pipeline driver, THE `/cdmp hud` HUD.
--
-- WHAT THIS IS.  The whole W4 refactor built the pipeline bottom-up and verified each
-- stage off-game; this is the thing that RUNS them in sequence on the live client:
--
--     State.Build  ->  Coach:Compute  ->  Binder:Bind(guidance, layout)  ->  Renderer:Draw
--       (pulse)         (Guidance)          (DrawList)                         (pixels)
--
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
D.lastKeys = 0        -- diagnostics: key hints drawn on the last tick (Phase 3's 2nd channel)
D.lastError = nil     -- diagnostics: last tick error text (nil = clean)
-- The last DrawList the Renderer was actually handed.  ⚠ DIAGNOSTIC ONLY — nothing in the
-- pipeline reads it.  It exists because `hud layout` could not answer the question it
-- claims to ("the row to read when a key is missing"): it printed STATE's keybind, which is
-- upstream of both the Binder and the Renderer, so a key that resolved but never reached
-- the screen looked identical to one that drew fine.  Now the dump can say which stage
-- dropped it.
D.lastDraw = nil

local TICK_PERIOD = 0.1   -- ~10 Hz, matching State's poll cadence

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
-- How many specs actually carry a profile is READ OFF THE REGISTRY, never restated in
-- prose: this notice claimed "only Demonology is supported" for months after Destruction
-- registered, because a sentence has no way to notice a new `ns.RegisterSpec` call.
local function profileCount()
  local n = 0
  for _ in pairs(ns.Specs or {}) do n = n + 1 end
  return n
end

local function maybeNotifyUnsupported()
  if ns.ActiveSpec ~= nil then
    D.notifiedSpecID = nil   -- supported / unresolved: re-arm for a later swap to passive
    return
  end
  local id = ns.detectedSpecID
  if id == nil or id == D.notifiedSpecID then return end
  D.notifiedSpecID = id
  local n = profileCount()
  ns.Printf("HUD |cffff8080passive|r — no profile for %s (spec %d); %d spec%s registered. "
    .. "|cffffffff/cdmp hud status|r for details.",
    ns.detectedSpecName or "this spec", id, n, n == 1 and " is" or "s are")
end

-- One-shot chat notice when the active spec brain resolves a build fact the player would
-- want to argue with — today, Destruction's hero tree.  The brain publishes
-- `spec.heroResolution` ("<hero>|<how>") from its Context; announcing is the DRIVER's job
-- because Context is pure by contract and runs at 10 Hz.
--
-- ⚠ THE LATCH IS DELIBERATELY NEVER CLEARED.  TRAIT_CONFIG_UPDATED fires several times for
-- one loadout swap (and on login), so re-arming it on invalidation would print the same
-- unchanged hero tree three or four times in a row.  Latching on the RESOLUTION STRING
-- means the line fires on a real CHANGE of the answer, which is what it is for.
local function maybeNotifyHero()
  local spec = ns.ActiveSpec
  local res = spec and spec.heroResolution
  if res == nil or res == D.notifiedHero then return end
  D.notifiedHero = res
  local hero, how = res:match("^([^|]*)|(.*)$")
  ns.Printf("%s: hero tree = |cffffffff%s|r (%s)",
    ns.detectedSpecName or "spec", hero or res, how or "?")
end

local function tick()
  maybeNotifyUnsupported()
  local pulse = ns.State.Build(false)
  local guidance = D.coach:Compute(pulse)
  maybeNotifyHero()          -- after Compute: the brain's Context is what publishes it
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
  D.lastKeys = drawList.keybinds and #drawList.keybinds or 0
  D.lastDraw = drawList
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
-- ⚠ TWO KEYBIND COLUMNS, AND THE PAIR IS THE POINT.  `key=` is what STATE resolved down
-- the rung ladder; `drew=` is what the LAST TICK's DrawList actually carried for that
-- handle.  They sit side by side because this dump claims to be "the row to read when a
-- key is missing" and, showing State alone, it could not be: a key that resolved and then
-- fell out of the Binder looked exactly like one that drew fine.  Reading the pair:
--   key=X drew=X   resolved and drawn — if it is not on screen, it is OCCLUDED
--   key=X drew=—   the Binder dropped it: the driver's keybind STITCH missed this cid
--   key=none       State resolved no bind at all (genuinely unbound, or the ladder failed)
local function dumpLayout()
  local layout, registry = ns.HudLayout.Scan()
  -- The keybind the chrome will actually use comes from STATE (stitched by cooldownID), so
  -- show that, not a re-lookup.
  local cds = ns.State.Build(false).cooldowns or {}
  -- …and what the Renderer was last HANDED, keyed the same way.
  local drew, cued = {}, {}
  local last = D.lastDraw
  for _, k in ipairs((last and last.keybinds) or {}) do drew[k.anchorTo] = k.keybind end
  for _, c in ipairs((last and last.cues) or {}) do cued[c.anchorTo] = c.emphasis end
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
    ns.Printf("  cd=%d  spellID=%s (%s)  key=%s  drew=%s%s  frame=%s",
      cid, tostring(e.spellID), (e.spellID and ns.SpellName(e.spellID)) or "?",
      kb and ("|cff88ff88" .. kb .. "|r") or "|cff808080none|r",
      drew[cid] and ("|cff88ff88" .. drew[cid] .. "|r") or "|cffff4040—|r",
      cued[cid] and ("  cue=|cffffcc00" .. tostring(cued[cid]) .. "|r") or "",
      frame and "|cff88ff88bound|r" or "|cffff4040nil|r")
  end
  ns.Printf("  %d displayed icon(s). |cff808080key=none|r = State resolved no bind; "
    .. "|cffff4040drew=—|r = it never reached the DrawList.", #ids)
  if not last then
    ns.Print("  |cffffcc00drew= is blank for every row: no tick has run yet|r — "
      .. "is |cffffffff/cdmp hud|r on?")
  end
end

--------------------------------------------------------------------------------
-- Roster coverage (Phase 4) — does the CDM track every id the spec DECLARES?
--------------------------------------------------------------------------------
-- Two surfaces over one report (`ns.Coverage.Get`), mirroring `dumpLayout` above and the
-- `hud layout` subcommand precedent: a one-line summary on `status`, and the full per-id
-- table on its own subcommand.  The summary is RED only when something is genuinely
-- blind — a report that shouts every login is a report nobody reads.
--
-- ⚠ "reported eligible", NEVER "cannot fire".  `GetValidAlertTypes` was measured
-- UNDER-REPORTING (cid 164597 listed `PandemicTime` only, then raised an `OnAuraApplied`
-- in the same session), so it is a LOWER BOUND on what a row can raise.  The footer says
-- so on every dump; `ns.ReadValidAlertTypes`' own header carries the same rule and this
-- readout must not contradict it.
local VERDICT_TAG = {
  blind     = "|cffff4040BLIND|r    ",
  unknown   = "|cffffcc00unknown|r  ",
  virtual   = "|cff88ccffour icon|r ",
  expected  = "|cff808080override|r ",
  unlearned = "|cff808080unlearn'd|r",
  ok        = "|cff88ff88tracked|r  ",
}

local function coverageSummary(rep)
  if not rep.ok then
    return string.format("  roster coverage: |cff808080not scanned (%s)|r",
      rep.reason or "unavailable")
  end
  local c = rep.counts
  local blind = (c.blind > 0)
    and string.format(" · |cffff4040%d BLIND|r", c.blind)
    or  " · 0 blind"
  return string.format("  roster coverage: %d tracked · %d our own icons · %d override-only%s%s%s%s"
    .. "   |cffffffff(/cdmp hud coverage)|r",
    c.ok, c.virtual, c.expected,
    (c.unlearned or 0) > 0 and string.format(" · %d unlearned", c.unlearned) or "",
    blind,
    c.unknown > 0 and string.format(" · |cffffcc00%d unknown|r", c.unknown) or "",
    rep.stale and "   |cff808080(stale)|r" or "")
end

local function dumpCoverage()
  local rep = ns.Coverage.Get()
  ns.Heading("Roster coverage — every id the spec DECLARES vs what the CDM tracks")
  if not rep.ok then
    -- ⚠ THE WHOLESALE GUARD, SURFACED.  An empty scan is a refused read, not a blind
    -- roster, so there is deliberately no per-id table to show here.
    ns.Printf("  |cff808080no report: %s|r", rep.reason or "unavailable")
    if rep.reason == "cdm-empty" then
      ns.Print("  the CDM database read back EMPTY — that is a refused read, not a blind "
        .. "roster. Are the Cooldown Manager viewers enabled?")
    elseif rep.reason == "in-combat" then
      ns.Print("  scanned out of combat only (the struct reads go secret in a pull). "
        .. "Drop combat and ask again.")
    end
    return
  end
  for _, e in ipairs(rep.entries) do
    -- The CLIENT's name, plus the roster's own label when it says something different —
    -- the aliases ("Ruination (alt ID, unconfirmed)", "Immolate (cast-id alias)") carry
    -- the author's reason for declaring the id at all, which is the whole context for
    -- reading its verdict.
    local name = ns.SpellName(e.spellID) or "?"
    local label = (e.label and e.label ~= name) and ("   |cff808080" .. e.label .. "|r") or ""
    ns.Printf("  %s %-7d %s%s%s",
      VERDICT_TAG[e.verdict] or e.verdict, e.spellID, name, label,
      e.known == false and "   |cff808080(not talented in this build)|r"
        or (e.known == nil and "   |cffffcc00(knownness unreadable)|r" or ""))
    for _, r in ipairs(e.rows) do
      local alerts
      if r.alerts then
        alerts = #r.alerts > 0 and table.concat(r.alerts, ", ") or "(none)"
      else
        alerts = "|cffffcc00<" .. (r.alertsError or "unreadable") .. ">|r"
      end
      ns.Printf("      cd=%d %s via %s   reported eligible: %s",
        r.cooldownID, r.category or "?", r.via, alerts)
    end
  end
  local c = rep.counts
  ns.Printf("  %d declared · %d tracked · %d our own icons · %d by-design absent · %s%s"
    .. "   (%d CDM row(s) scanned%s)",
    c.total, c.ok, c.virtual, c.expected + (c.unlearned or 0),
    (c.blind > 0) and ("|cffff4040" .. c.blind .. " BLIND|r") or "0 blind",
    c.unknown > 0 and (" · |cffffcc00" .. c.unknown .. " unknown|r") or "",
    rep.scanned,
    (rep.unreadableRows or 0) > 0 and (", " .. rep.unreadableRows .. " refused their fields")
      or "")
  ns.Print("  |cff808080'reported eligible' is a LOWER BOUND: GetValidAlertTypes "
    .. "under-reports (cid 164597 listed PandemicTime only, then raised an OnAuraApplied "
    .. "in the same session). It never says 'cannot fire'.|r")
  if c.blind > 0 then
    ns.Print("  |cff808080BLIND means the character HAS this ability and the CDM tracks it "
      .. "nowhere. Ids they do NOT have read `unlearn'd`, and ids whose knownness would not "
      .. "read say `unknown` — neither is an alarm.|r")
  end
  if rep.stale then
    ns.Print("  |cffffcc00stale|r — this is the last out-of-combat scan; we do not rescan "
      .. "in a pull.")
  end
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
  -- TWO CHANNELS since Phase 3, and they are counted apart on purpose.  `cue(s)` is
  -- DECISIONS — it dropped when the empty-cue trick went away, and that drop is the phase
  -- working, not a regression.  `key hint(s)` is the chrome that used to be folded into it.
  ns.Printf("  last tick: %d cue(s) + %d key hint(s) drawn%s", D.lastCues, D.lastKeys,
    D.lastError and ("   |cffff4040error:|r " .. D.lastError) or "   |cff88ff88clean|r")
  -- THE §3.10 CAPABILITY VERDICT.  `item.auraDataUnit` / `item.PandemicIcon` are widget
  -- INTERNALS, not API: no deprecation, no error, and if Blizzard stops writing them they
  -- read nil forever — indistinguishable from "no aura".  So the check is on the WRITER
  -- METHODS and its failure has to be loud, or the DoT line silently drops back to the
  -- alert latch (which cannot clear itself) with nothing on screen to say so.  ABSENT here
  -- is the rule-17b fallback working as designed: a FINDING, not a bug.
  local rows, unit, window = ns.State.AuraFrameCapability()
  if rows == 0 then
    ns.Print("  aura-frame read: |cff808080no item frames|r (are the CDM viewers shown?)")
  else
    local function half(n, name)
      return (n == rows and "|cff88ff88" or (n == 0 and "|cffff4040" or "|cffffcc00"))
        .. n .. "/" .. rows .. "|r " .. name
    end
    ns.Printf("  aura-frame read: %s, %s%s",
      half(unit, "auraDataUnit"), half(window, "pandemic writers"),
      (unit == 0 or window == 0)
        and "   |cffff4040the internals moved — DoT is on the edge-latch fallback|r" or "")
  end
  -- THE KEYBIND CACHE, because its failure mode is silent and was field-found the hard
  -- way: an empty action-bar scan used to be cached as authoritative, so every icon ran
  -- keyless with nothing anywhere saying why (v0.32.50).  `bound=0` is the tell.
  local bs = ns.HudBinds and ns.HudBinds.stats
  if bs then
    ns.Printf("  keybinds: %s%d bound|r / %d slot(s), %d scan(s)%s%s%s",
      (bs.bound == 0) and "|cffff4040" or "|cff88ff88", bs.bound, bs.slots, bs.scans,
      bs.retried > 0 and ("   retried " .. bs.retried .. "x") or "",
      bs.deferred > 0 and ("   deferred " .. bs.deferred .. "x (combat)") or "",
      ns.HudBinds.dirty and "   |cffffcc00rescan owed|r" or "")
    if bs.bound == 0 then
      ns.Print("    |cffff4040no bindings resolved|r — every key hint will be blank. "
        .. "If this persists out of combat, the bar scan is not seeing your bars.")
    end
  end
  -- ROSTER COVERAGE — the Phase-4 probe.  It replaces the visibility `pulse.dropped` gave
  -- us (a declared id the CDM tracks NOWHERE is invisible to every other readout), so it
  -- belongs on the one line the player already reads.  Cheap: cached per build.
  ns.Print(coverageSummary(ns.Coverage.Get()))
  ns.Print("  |cffffffff/cdmp hud layout|r dumps the live Layout; "
    .. "|cffffffff/cdmp hud coverage|r the roster-coverage table.")
end

--------------------------------------------------------------------------------
-- Command
--------------------------------------------------------------------------------
local function hudCommand(rest)
  rest = (rest or ""):lower()
  if rest:find("coverage") then return dumpCoverage() end
  if rest:find("layout") then return dumpLayout() end
  if rest:find("status") then return status() end
  if rest:find("off") then return ns.SetHud(false) end
  if rest:find("on") then return ns.SetHud(true) end
  ns.SetHud(not D.on)
end
ns.RegisterCommand("hud",
  "the HUD — the W4 pipeline (State -> Coach -> Binder -> Renderer). 'hud on|off' set it; 'hud layout' dumps the live Layout; 'hud coverage' the roster-coverage table; 'hud status' the readout.",
  hudCommand)

-- /cdmp reset — turn the HUD off.  The HUD is the only thing left to reset.
ns.RegisterCommand("reset", "turn the HUD off", function()
  if D.on then ns.SetHud(false) end
end)

-- Restore on login (wrap the existing chain).
local prevOnLogin = ns.OnLogin
function ns.OnLogin()
  if prevOnLogin then prevOnLogin() end
  -- `ns.db.hud` is the pipeline's enable BOOL.  An older build stored a SETTINGS TABLE
  -- under the same key, so a table-shaped value is dropped on sight — it is a type
  -- confusion, not a version we can read.
  if ns.db and type(ns.db.hud) == "table" then ns.db.hud = nil end
  if ns.db and ns.db.hud then
    C_Timer.After(1.0, function() ns.SetHud(true) end)
  end
end
