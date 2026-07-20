-- HudState.lua — the STATE machine: readiness edges, proc presence, the shard
-- gate, and the empty-board recede.  M3a said who each icon IS; this says what
-- it's DOING.  Covers §0.5.8.3 rows #5 (ready accent + recede), #2 (Demonic Core
-- proc-glow) and #3 (Demonic Art proc-glow).
--
-- Nothing here reads a secret.  Every signal comes from an OBSERVED EDGE.
--
--------------------------------------------------------------------------------
-- The mechanism: TriggerAlertEvent is one choke point for every edge we want
--------------------------------------------------------------------------------
-- Source: Blizzard_CooldownViewer/CooldownViewer.lua @ build 68453.
-- `CooldownViewerItemMixin:TriggerAlertEvent(event)` (:483) is invoked as
-- `self:TriggerAlertEvent(...)` — a DYNAMIC method lookup on the item instance —
-- from all six alert paths:
--
--   Available     :500    ready RISING edge      -> #5
--   OnCooldown   :1068    ready FALLING edge     -> #5
--   OnAuraApplied :612    proc gained            -> #2, #3
--   OnAuraRemoved :622    proc lost              -> #2, #3
--   ChargeGained  :608    (M4)
--   PandemicTime  :556    (§7 open question)
--
-- Decisively: the user's alert CONFIGURATION is checked INSIDE the body
-- (`self.alertsByEvent[event]`), after the call.  So the method is invoked
-- unconditionally and our hook fires even for spells the user has configured no
-- alert on.  One hook per item instance = every edge, precisely, with no polling
-- and no secret read.
--
-- The trap we avoided: `OnCooldownDone` CANNOT be hooked the obvious way.
-- `CooldownViewerCooldownItemMixin:OnLoad` does
-- `self:GetCooldownFrame():SetScript("OnCooldownDone", GenerateClosure(self.OnCooldownDone, self))`
-- (:700) — the closure captures the FUNCTION REFERENCE at OnLoad, so a later
-- `hooksecurefunc(item, "OnCooldownDone", ...)` is never reached from the script
-- path.  It would have shipped as a silent no-op.  (If we ever want it, it has to
-- be `item.Cooldown:HookScript("OnCooldownDone", ...)`.)  Given the choke point,
-- we don't need it.
--
-- Item methods are Mixin()-copied onto EACH frame, so — exactly as in HudTint —
-- the hook goes on the item INSTANCE, guarded once per frame.
--
--------------------------------------------------------------------------------
-- Layered presence, honestly reported
--------------------------------------------------------------------------------
-- 1. EDGE  — the aura alert events above.  Precise, config-independent, primary.
-- 2. LEVEL — `item:IsShown()` at bind time, for initial sync.  Only valid if the
--            viewer actually hides inactive items: `ShouldBeShown()` (:311)
--            returns true IMMEDIATELY when `not allowHideWhenInactive` or `not
--            hideWhenInactive`, so with that setting off IsShown is CONSTANT-TRUE
--            and a glow driven off it would latch on permanently — worse than no
--            glow.  So it is capability-checked, never assumed.
-- 3. POLL  — a throttled backstop over the same boolean, only when level reads
--            are available.
--
-- `/cdmp hud status` reports which of these is live rather than pretending.
local ADDON, ns = ...

ns.HudState = {
  presence = {},          -- registry key -> bool (last observed aura level)
  override = {},          -- base spellID -> override spellID (live transforms)
  glowing  = {},          -- source spellID -> strength currently applied
  shards   = nil,         -- last readable soul-shard count (nil = unreadable)
  levelOK  = nil,         -- nil = not yet probed; true/false = IsShown usable
  hooks    = 0,
  fires    = { available = 0, oncd = 0, applied = 0, removed = 0,
               charge = 0, pandemic = 0, other = 0, secret = 0, override = 0 },
  lastEdge = {},          -- source spellID -> "aura-event" | "override" | "poll"
}
local S = ns.HudState

local LOW_SHARDS   = 3      -- "board quiet" only below the SPEND threshold
local RECEDE_DELAY = 0.5    -- debounce; long enough not to strobe between GCDs
local RECEDE_MULT  = 0.25   -- LOUD PASS: match HudChrome RECEDE_MIN (was 0.45)
local POLL_PERIOD  = 0.1    -- ~10 Hz level backstop (a boolean read, no secret)

local function hudOn() return ns.Hud and ns.Hud.on end

--------------------------------------------------------------------------------
-- Soul shards — the §0.5.8.4 softening gate
--------------------------------------------------------------------------------
-- Readable AND branchable even in restricted combat (notes.md §1, confirmed
-- empirically).  Still guarded: if it ever turns secret we degrade to "unknown"
-- and simply stop softening, rather than tainting on a comparison.
local function readShards()
  if not (Enum and Enum.PowerType) then return nil end
  local ok, n = pcall(UnitPower, "player", Enum.PowerType.SoulShards)
  if not ok or ns.IsSecret(n) or type(n) ~= "number" then return nil end
  return n
end

--------------------------------------------------------------------------------
-- Registry helpers
--------------------------------------------------------------------------------

-- Every registry entry whose BASE spell matches (Diabolic Ritual is tracked
-- TWICE under two cooldownIDs — notes.md §2 correction 2 — so this is a list,
-- and presence is OR'd across them).
local function entriesForSpell(spellID)
  local out = {}
  if type(spellID) ~= "number" or not ns.Hud then return out end
  for key, e in pairs(ns.Hud.items) do
    if e.baseSpellID == spellID or e.spellID == spellID then
      out[#out + 1] = { key = key, entry = e }
    end
  end
  return out
end

local function sourcePresent(spellID)
  for _, r in ipairs(entriesForSpell(spellID)) do
    if S.presence[r.key] then return true end
  end
  return false
end

--------------------------------------------------------------------------------
-- Glow resolution
--------------------------------------------------------------------------------

local function strengthFor(rule)
  if rule.softenAbove and S.shards and S.shards >= rule.softenAbove then
    return 0.45     -- soften, don't clear: the proc is real, the cap outranks it
  end
  return 1.0
end

-- The one icon-viewer item for a base spellID (nil if that spell isn't drawn).
local function iconItemFor(spellID)
  for _, r in ipairs(entriesForSpell(spellID)) do
    if ns.Hud.IsIconViewer(r.entry.viewer) then return r.entry.item end
  end
  return nil
end

-- The icon a LIVE spell override has landed on, if any — the precise #3 trigger.
local function transformedItem()
  for base, over in pairs(S.override) do
    if over then
      local item = iconItemFor(base)
      if item then return item, base end
    end
  end
  return nil
end

-- Re-evaluate every proc rule from current presence + override + shard state.
-- Idempotent, so it's safe to call from any edge.
function S.RefreshGlows()
  if not hudOn() or not ns.SpecProcGlow then return end
  for sourceID, rule in pairs(ns.SpecProcGlow) do
    local item, on
    if rule.transform then
      -- The override event is the ONLY trigger for #3, deliberately.  Diabolic
      -- Ritual's buff is present for most of the ACCUMULATION, not just once an
      -- Art is armed, so glowing off its mere presence would be a false positive
      -- that's lit nearly all the time.  The presence edge is still recorded and
      -- reported in `hud status` as CORROBORATION — so the in-game pass can see
      -- whether the two agree — but it never drives the glow.
      item = transformedItem()
      on = item ~= nil
      if not item then item = iconItemFor(rule.target) end
    else
      item = iconItemFor(rule.target)
      on = sourcePresent(sourceID)
    end
    if item then
      if on then
        local st = strengthFor(rule)
        ns.HudChrome.SetGlow(item, true, st, rule.group)
        S.glowing[sourceID] = st
      else
        ns.HudChrome.SetGlow(item, false)
        S.glowing[sourceID] = nil
      end
    end
  end
  S.EvaluateBoard()
end

--------------------------------------------------------------------------------
-- Empty-board recede — §0.5.8.3 #5
--------------------------------------------------------------------------------
-- Shards low AND nothing glowing -> debounce -> dim OUR chrome (never Blizzard's
-- icons).  Wakes instantly on any proc or ready edge, so it can't strobe between
-- GCDs: only the sleep is delayed, never the wake.
local recedeTimer

local function quiet()
  if next(S.glowing) ~= nil then return false end
  -- Out of combat there is genuinely nothing to press, whatever the shard count
  -- — that's the plainest "empty board" there is.  (InCombatLockdown is readable
  -- and branchable; it is not combat *state*, it's the secure-API lockdown flag.)
  if not InCombatLockdown() then return true end
  if S.shards == nil then return false end     -- unknown -> never recede
  return S.shards < LOW_SHARDS
end

local function arm()
  if recedeTimer then return end
  recedeTimer = C_Timer.NewTimer(RECEDE_DELAY, function()
    recedeTimer = nil
    if hudOn() and quiet() then ns.HudChrome.SetRecede(RECEDE_MULT) end
  end)
end

local function disarm()
  if recedeTimer then recedeTimer:Cancel(); recedeTimer = nil end
end

function S.EvaluateBoard()
  if not hudOn() then return end
  if quiet() then
    arm()
  else
    disarm()
    ns.HudChrome.SetRecede(1.0)
  end
end

-- An edge just fired: un-recede NOW (wake is never delayed), then RE-ARM the
-- quiet check.  v0.7.0 shipped this as cancel-and-brighten with no re-arm, so
-- the first ready edge or proc killed the recede permanently — the board woke
-- once and never slept again.  Waking must always leave the sleep timer running
-- if we're already quiet again; that asymmetry (instant wake, debounced sleep)
-- is the whole anti-strobe design, and it only works if the sleep re-arms.
function S.Wake()
  disarm()
  ns.HudChrome.SetRecede(1.0)
  S.EvaluateBoard()          -- re-arms when still quiet; no recursion (the
                             -- else-branch disarms rather than calling Wake)
end

--------------------------------------------------------------------------------
-- The alert hook
--------------------------------------------------------------------------------

local function keyFor(item)
  if not ns.Hud then return nil end
  for key, e in pairs(ns.Hud.items) do
    if e.item == item then return key, e end
  end
  return nil
end

local function onAlert(item, event)
  if not hudOn() then return end
  local A = Enum and Enum.CooldownViewerAlertEventType
  if not A then return end
  -- A Secret Value must never be compared; if the event arg is ever restricted
  -- we count it and do nothing, rather than taint on the ==.
  if ns.IsSecret(event) then S.fires.secret = S.fires.secret + 1 return end

  if event == A.Available then
    S.fires.available = S.fires.available + 1
    ns.HudChrome.SetReady(item, true)
    ns.HudChrome.Settle(item)                 -- [V4]: one-shot, the urgent instant
    S.Wake()
  elseif event == A.OnCooldown then
    S.fires.oncd = S.fires.oncd + 1
    ns.HudChrome.SetReady(item, false)
  elseif event == A.OnAuraApplied or event == A.OnAuraRemoved then
    local applied = (event == A.OnAuraApplied)
    if applied then S.fires.applied = S.fires.applied + 1
    else S.fires.removed = S.fires.removed + 1 end
    local key, e = keyFor(item)
    if key then
      S.presence[key] = applied
      if e and e.baseSpellID then S.lastEdge[e.baseSpellID] = "aura-event" end
      S.RefreshGlows()
      if applied then S.Wake() end
    end
  elseif event == A.ChargeGained then
    S.fires.charge = S.fires.charge + 1       -- M4
  elseif event == A.PandemicTime then
    S.fires.pandemic = S.fires.pandemic + 1   -- §7
  else
    S.fires.other = S.fires.other + 1
  end
end

-- One hook per item INSTANCE (the methods are Mixin()-copied, so a hook on the
-- shared mixin table would miss every already-created frame).  hooksecurefunc
-- can never be undone, so the callback is gated on ns.Hud.on.
function S.Install(item)
  if item.__hudStateHooked then return end
  if not ns.HasMethod(item, "TriggerAlertEvent") then return end
  item.__hudStateHooked = true
  S.hooks = S.hooks + 1
  hooksecurefunc(item, "TriggerAlertEvent", function(self, event)
    local ok = pcall(onAlert, self, event)
    if not ok then S.fires.other = S.fires.other + 1 end
  end)
end

--------------------------------------------------------------------------------
-- Level (IsShown) — capability check + initial sync + poll backstop
--------------------------------------------------------------------------------

-- Is `item:IsShown()` actually a presence signal on this item?  Only when the
-- viewer is set to hide inactive items; otherwise ShouldBeShown() short-circuits
-- to true and the read means nothing (CooldownViewer.lua:311).
local function levelUsable(item)
  if item.allowHideWhenInactive == false or item.allowHideWhenInactive == nil then return false end
  if not item.hideWhenInactive then return false end
  return true
end

-- Seed presence from the level read where it's meaningful.  Never writes a
-- `false` from an unusable read — an unavailable level leaves presence to edges.
function S.SyncLevels()
  if not hudOn() then return end
  local anyUsable = false
  for key, e in pairs(ns.Hud.items) do
    if not ns.Hud.IsIconViewer(e.viewer) and e.item then
      if levelUsable(e.item) then
        anyUsable = true
        local ok, shown = pcall(e.item.IsShown, e.item)
        if ok and not ns.IsSecret(shown) then
          if S.presence[key] ~= (shown and true or false) then
            S.presence[key] = shown and true or false
            if e.baseSpellID then S.lastEdge[e.baseSpellID] = "level" end
          end
        end
      end
    end
  end
  S.levelOK = anyUsable
end

local pollTicker

local function poll()
  if not hudOn() or not S.levelOK then return end
  local changed = false
  for key, e in pairs(ns.Hud.items) do
    if not ns.Hud.IsIconViewer(e.viewer) and e.item and levelUsable(e.item) then
      local ok, shown = pcall(e.item.IsShown, e.item)
      if ok and not ns.IsSecret(shown) then
        shown = shown and true or false
        if S.presence[key] ~= shown then
          S.presence[key] = shown
          if e.baseSpellID then S.lastEdge[e.baseSpellID] = "poll" end
          changed = true
        end
      end
    end
  end
  if changed then S.RefreshGlows() end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:SetScript("OnEvent", function(_, event, a1, a2)
  if not hudOn() then return end
  if event == "COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED" then
    -- (baseSpellID, overrideSpellID).  THIS is Demonic Art, observed precisely:
    -- CooldownViewer.lua:1593 — the viewer hands us exactly which button
    -- transformed, so #3 doesn't have to infer "something is armed".
    S.fires.override = S.fires.override + 1
    if type(a1) == "number" and not ns.IsSecret(a1) then
      S.override[a1] = (type(a2) == "number" and not ns.IsSecret(a2)) and a2 or nil
      S.lastEdge[a1] = "override"
      -- The identity chrome re-reads the base spell, so a transform must not
      -- blank the keybind (the finding-3 bug) — re-attach to refresh the text.
      if ns.Hud.RefreshKeybinds then ns.Hud.RefreshKeybinds() end
      S.RefreshGlows()
      S.Wake()
    end
  elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
    S.shards = readShards()
    S.EvaluateBoard()          -- combat state is half of "is the board quiet?"
  elseif event == "UNIT_POWER_UPDATE" or event == "UNIT_POWER_FREQUENT" then
    if a1 ~= "player" then return end
    local n = readShards()
    if n ~= S.shards then
      S.shards = n
      S.RefreshGlows()          -- re-evaluates softening + the board
    end
  end
end)

function S.Start()
  S.shards = readShards()
  ev:RegisterEvent("COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED")
  ev:RegisterEvent("PLAYER_REGEN_DISABLED")
  ev:RegisterEvent("PLAYER_REGEN_ENABLED")
  ev:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
  ev:RegisterUnitEvent("UNIT_POWER_FREQUENT", "player")
  S.SyncLevels()
  if not pollTicker then pollTicker = C_Timer.NewTicker(POLL_PERIOD, poll) end
  S.RefreshGlows()
end

function S.Stop()
  ev:UnregisterAllEvents()
  if pollTicker then pollTicker:Cancel(); pollTicker = nil end
  if recedeTimer then recedeTimer:Cancel(); recedeTimer = nil end
  wipe(S.presence)
  wipe(S.override)
  wipe(S.glowing)
  ns.HudChrome.SetRecede(1.0)
end

--------------------------------------------------------------------------------
-- Status block (folded into `/cdmp hud status`)
--------------------------------------------------------------------------------
function S.PrintStatus()
  ns.Heading("  state — M3b (readiness + procs)")
  ns.Printf("   alert hooks: %d item(s)   edges: Available=%d OnCooldown=%d AuraApplied=%d AuraRemoved=%d  (charge=%d pandemic=%d other=%d |cffff4040secret=%d|r)",
    S.hooks, S.fires.available, S.fires.oncd, S.fires.applied, S.fires.removed,
    S.fires.charge, S.fires.pandemic, S.fires.other, S.fires.secret)
  ns.Printf("   spell-override events: %d   shards: %s   recede: %.2f",
    S.fires.override, S.shards and tostring(S.shards) or "|cffff4040unreadable|r",
    ns.HudChrome.GetRecede())
  ns.Printf("   level reads (item:IsShown): %s",
    S.levelOK == true and "|cff88ff88available|r (viewer hides inactive items)"
      or (S.levelOK == false and "|cffffd100unavailable|r — hideWhenInactive is off, so IsShown is constant-true; running on EDGES ONLY"
      or "not probed"))
  -- Is item.isActive readable?  If so it is a strictly better level read than
  -- IsShown (it's the very thing ShouldBeShown consults) and M3c can upgrade.
  local probe = "no items"
  for _, e in pairs(ns.Hud.items) do
    if e.item then probe = ns.Describe(e.item.isActive) break end
  end
  ns.Printf("   probe: item.isActive = %s  |cff808080(readable => better level source, M3c)|r", probe)
  for sourceID, rule in pairs(ns.SpecProcGlow or {}) do
    local st = S.glowing[sourceID]
    ns.Printf("   glow %s: %s   last edge: %s",
      rule.label or tostring(sourceID),
      st and string.format("|cff88ff88ON|r (strength %.2f)", st) or "|cff808080off|r",
      S.lastEdge[sourceID] or S.lastEdge[rule.target] or "|cff808080none yet|r")
  end
end
