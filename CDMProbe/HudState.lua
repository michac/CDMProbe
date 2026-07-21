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
  -- `other` and `errors` are SPLIT (M3c-b B3).  Both were incremented into
  -- `other`: the unknown-alert-type else-branch AND the pcall failure sink in
  -- S.Install's hook.  A probe read other=47 in one session and there was no way
  -- to tell whether that was 47 unhandled event types (fine, informational) or
  -- 47 SWALLOWED HANDLER ERRORS (a bug we'd never see).  After this milestone
  -- `errors` should be 0; a non-zero count is a defect, not a curiosity.
  fires    = { available = 0, oncd = 0, applied = 0, removed = 0,
               charge = 0, pandemic = 0, other = 0, errors = 0,
               secret = 0, override = 0 },
  lastEdge = {},          -- source spellID -> "aura-event" | "override" | "poll"
  -- M3c-a — the dot score.
  score          = {},    -- registry key -> the HudScore result, for the row
  candidateSince = {},    -- registry key -> GetTime() when it first became a
                          -- ROTATION candidate; cleared when it stops being one
  readyAt        = {},    -- base spellID -> when we OBSERVED the ready edge
}
local S = ns.HudState

local LOW_SHARDS   = 3      -- "board quiet" only below the SPEND threshold
local RECEDE_DELAY = 0.5    -- debounce; long enough not to strobe between GCDs
local RECEDE_MULT  = 0.25   -- LOUD PASS: match HudChrome RECEDE_MIN (was 0.45)
local POLL_PERIOD  = 0.1    -- ~10 Hz level backstop (a boolean read, no secret)

-- How long an ability may sit as a live candidate before the dot promotes to
-- LATE.  Uniform across cadences ON PURPOSE, and precise for all of them: the
-- clock starts at the observed moment the ability BECAME a candidate, so LATE
-- needs no napkin and carries no estimate.  ~2 GCDs.
local LATE_AFTER   = 3.0
local SCORE_PERIOD = 0.25   -- drives the ROTATION -> LATE promotion + countdown

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
-- SPEND-SIDE ANTICIPATION — M3c-b B4
--------------------------------------------------------------------------------
-- "As soon as I start casting HoG it should assume those shards are consumed and
-- give me recommendations based on that state."  The shipped napkin only ghosts
-- INCOMING shards; this is the other half.  Unblocked by the probe:
-- UNIT_SPELLCAST_START read 52/52 readable, 0 secret.
--
-- ⚠ THE DOUBLE-DEDUCTION GUARD is required, not optional.  It is UNKNOWN whether
-- the client deducts the cost at cast START or at completion.  A naive
-- `live - cost` would subtract twice under the start-deduct behaviour and tell
-- the player they're broke.  So we never subtract the cost outright — we compute
-- from OBSERVED MOVEMENT:
--
--     spent     = max(0, atStart - live)      how much has ALREADY come off
--     remaining = max(0, cost - spent)        what is still owed
--     projected = live - remaining + generates
--
-- Correct under either behaviour: if the client already took it, `spent` covers
-- the cost and `remaining` is 0; if it hasn't, `spent` is 0 and we take it here.
--
-- ⚠ THE RESIDUAL ASSUMPTION the guard cannot cover: `atStart` must be sampled
-- BEFORE the deduction lands.  If the client deducts at cast start AND fires
-- UNIT_POWER_UPDATE ahead of UNIT_SPELLCAST_START, we baseline off the
-- already-reduced count, `spent` reads 0, and we subtract a second time.  The
-- symptom is a board that goes CONSERVATIVE mid-cast (a gate that should be open
-- reads shut) — never one that over-promises.  That is the safe direction, and
-- the summary line prints the projected figure beside the live one precisely so
-- the in-game pass can see the two disagree.
--
-- Everything derived from this is an ESTIMATE, and estimates render HOLLOW —
-- same rule as the napkin's SOON, same class of claim.
S.cast = nil            -- { spellID, cost, generates, atStart } while in flight

local function beginCast(spellID)
  if not (type(spellID) == "number" and not ns.IsSecret(spellID)) then return end
  local cost = ns.ShardCost(spellID) or 0
  local gen  = ns.SpecGhost(spellID) or 0
  if cost <= 0 and gen <= 0 then S.cast = nil return end
  S.cast = { spellID = spellID, cost = cost, generates = gen, atStart = S.shards }
  if S.Recompute then S.Recompute() end
end

local function endCast()
  if S.cast == nil then return end
  S.cast = nil
  if S.Recompute then S.Recompute() end
end

-- The shard figure the SCORER should read.  Returns (shards, projected) where
-- `projected` is true only when the estimate actually DIFFERS from the live
-- reading — i.e. only when a dot could have been moved by it, which is exactly
-- when the hollow confidence marker is owed.
function S.ProjectedShards()
  local live = S.shards
  if live == nil then return nil, false end       -- unreadable stays unreadable
  local c = S.cast
  if not (c and type(c.atStart) == "number") then return live, false end
  local spent     = math.max(0, c.atStart - live)
  local remaining = math.max(0, (c.cost or 0) - spent)
  local proj      = live - remaining + (c.generates or 0)
  proj = math.max(0, math.min(ns.SHARD_CAP or 5, proj))
  return proj, proj ~= live
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
-- Exported so HudScore can read the SAME presence the glow reads.  One source
-- of truth for "is this proc up" means the dot and the glow cannot disagree.
S.SourcePresent = sourcePresent

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
  -- Every input the scorer reads — proc presence, override, shards — has just
  -- been re-resolved, so this is the one place that has to drive the dots.  It's
  -- called from every aura edge, every shard change and every override, which is
  -- exactly the recompute set M3c-a needs; the ticker only adds the clock.
  if S.Recompute then S.Recompute() end
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
-- The dot score — M3c-a
--------------------------------------------------------------------------------
-- HudScore is a pure function of readable state; this is where that state gets
-- CLOCKED.  Two things live here rather than in the scorer because they need a
-- memory the scorer deliberately doesn't have:
--
--   * `candidateSince` — stamped the moment an ability first becomes
--     ROTATION-eligible, cleared when it stops.  This is what LATE is measured
--     from, and it is an OBSERVED timestamp, not an estimate — which is exactly
--     why LATE needs no napkin and can be trusted where the countdown can't.
--   * the dot itself — one SetDot per icon item, so the scorer never touches a
--     frame.
function S.Recompute()
  if not (hudOn() and ns.HudScore) then return end
  local now = GetTime()
  for key, e in pairs(ns.Hud.items) do
    if ns.Hud.IsIconViewer(e.viewer) and e.item then
      local ok, sc = pcall(ns.HudScore.For, key, e)
      if ok and sc then
        if sc.candidate then
          S.candidateSince[key] = S.candidateSince[key] or now
          local since = S.candidateSince[key]
          -- B6 — LATE MUST NOT ACCRUE OUT OF COMBAT.  The OOC probe caught Hand
          -- of Gul'dan at "LATE - waiting 7s" while standing in a city: LATE is a
          -- NAG, and a nag with nothing to nag about trains the player to ignore
          -- the channel entirely.  (InCombatLockdown is readable and branchable —
          -- it's the secure-API lockdown flag, not combat state; the same
          -- precedent quiet() already relies on above.)
          if InCombatLockdown() and (now - since) >= LATE_AFTER then
            sc.level = ns.HudScore.LEVELS.LATE
            sc.reasons[#sc.reasons + 1] = string.format("waiting %.0fs", now - since)
          end
        else
          S.candidateSince[key] = nil
        end
        S.score[key] = sc
        -- B4 — a dot promoted BECAUSE OF a projection renders HOLLOW.  Same
        -- confidence marker the napkin's SOON already uses, same rule: an
        -- ESTIMATE MUST NEVER LOOK LIKE AN OBSERVATION.  Only the promoted
        -- levels are marked — NEVER/AVAILABLE claim nothing to soften.
        local hollow = sc.projected and
          (sc.level == ns.HudScore.LEVELS.ROTATION or sc.level == ns.HudScore.LEVELS.LATE)
        -- SOON is a treatment on NEVER, never a level of its own: it brightens
        -- and counts down but claims nothing about pressability.
        pcall(ns.HudChrome.SetDot, e.item, e.viewer,
          (sc.soon and sc.level == ns.HudScore.LEVELS.NEVER) and "SOON" or sc.level,
          hollow)
      else
        S.score[key] = nil
        S.candidateSince[key] = nil
        pcall(ns.HudChrome.SetDot, e.item, e.viewer, nil)
      end
    end
  end
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
    -- GROUND TRUTH WINS.  The observed edge retires the napkin estimate outright:
    -- if CDR or a reset brought this up early, the dot goes ROTATION NOW whatever
    -- the countdown said.  The estimate is never allowed to outlive an observation.
    local _, e = keyFor(item)
    if e and e.baseSpellID then
      -- Clear under BOTH identities: SUCCEEDED files the napkin under whatever
      -- spellID actually went off, which is the OVERRIDE while a transform is
      -- armed.  Clearing only the base would leave a stale estimate behind.
      ns.HudNapkin.Clear(e.baseSpellID)
      if e.spellID and e.spellID ~= e.baseSpellID then ns.HudNapkin.Clear(e.spellID) end
      S.readyAt[e.baseSpellID] = GetTime()
    end
    S.Wake()
    S.Recompute()
  elseif event == A.OnCooldown then
    S.fires.oncd = S.fires.oncd + 1
    ns.HudChrome.SetReady(item, false)
    local _, e = keyFor(item)
    if e and e.baseSpellID then S.readyAt[e.baseSpellID] = nil end
    S.Recompute()
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
    if not ok then S.fires.errors = S.fires.errors + 1 end
  end)
end

--------------------------------------------------------------------------------
-- Level (IsShown) — capability check + initial sync + poll backstop
--------------------------------------------------------------------------------

-- Is `item:IsShown()` actually a presence signal on this item?  Only when the
-- viewer is set to hide inactive items; otherwise ShouldBeShown() short-circuits
-- to true and the read means nothing (CooldownViewer.lua:311).
local function levelUsable(item)
  -- Guarded like every other comparison in this file.  These are config fields
  -- rather than combat state so they're unlikely to be restricted — but this
  -- runs from `rebind()`, which is a hooksecurefunc callback in Blizzard's
  -- RefreshLayout path, so a throw here escapes into THEIR code rather than
  -- being contained.  Never compare a value you haven't asked about.
  local a, h = item.allowHideWhenInactive, item.hideWhenInactive
  if ns.IsSecret(a) or ns.IsSecret(h) then return false end
  if a == false or a == nil then return false end
  if not h then return false end
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
ev:SetScript("OnEvent", function(_, event, a1, a2, a3)
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
    if event == "PLAYER_REGEN_ENABLED" then
      -- B6's other half.  Leaving combat clears the candidate clocks so the next
      -- pull starts them FRESH — otherwise an ability that became a candidate as
      -- the last mob died carries a stale timestamp into the opener and promotes
      -- straight to LATE on the first frame of the fight.
      wipe(S.candidateSince)
      S.cast = nil
    end
    S.EvaluateBoard()          -- combat state is half of "is the board quiet?"
  elseif event == "UNIT_POWER_UPDATE" or event == "UNIT_POWER_FREQUENT" then
    if a1 ~= "player" then return end
    local n = readShards()
    if n ~= S.shards then
      S.shards = n
      S.RefreshGlows()          -- re-evaluates softening + the board
    end
  elseif event == "UNIT_SPELLCAST_START" then
    -- (unit, castGUID, spellID) — RegisterUnitEvent already filters to player.
    pcall(beginCast, a3)
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" or event == "UNIT_SPELLCAST_STOP"
      or event == "UNIT_SPELLCAST_INTERRUPTED" then
    -- The projection is retired by ANY end-of-cast, however it ended.  A cast
    -- that was interrupted spent nothing and a cast that landed has already
    -- moved the live counter, so in both cases the ground truth is now the
    -- readable one and the estimate has no business outliving it.
    pcall(endCast)
  end
end)

local scoreTicker

function S.Start()
  S.shards = readShards()
  ns.HudNapkin.Start()
  ev:RegisterEvent("COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED")
  ev:RegisterEvent("PLAYER_REGEN_DISABLED")
  ev:RegisterEvent("PLAYER_REGEN_ENABLED")
  ev:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
  ev:RegisterUnitEvent("UNIT_POWER_FREQUENT", "player")
  -- B4 — the spend side of anticipation.
  ev:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
  ev:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
  ev:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player")
  ev:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player")
  S.SyncLevels()
  if not pollTicker then pollTicker = C_Timer.NewTicker(POLL_PERIOD, poll) end
  -- One ticker, two jobs, both of which are pure CLOCK work the edges can't do:
  -- the ROTATION -> LATE promotion, and the napkin countdown ticking down in the
  -- row.  Everything else is still edge-driven.
  if not scoreTicker then
    scoreTicker = C_Timer.NewTicker(SCORE_PERIOD, function() pcall(S.Recompute) end)
  end
  S.RefreshGlows()
end

function S.Stop()
  ev:UnregisterAllEvents()
  if pollTicker then pollTicker:Cancel(); pollTicker = nil end
  if scoreTicker then scoreTicker:Cancel(); scoreTicker = nil end
  if recedeTimer then recedeTimer:Cancel(); recedeTimer = nil end
  ns.HudNapkin.Stop()
  S.cast = nil
  wipe(S.presence)
  wipe(S.override)
  wipe(S.glowing)
  wipe(S.score)
  wipe(S.candidateSince)
  wipe(S.readyAt)
  ns.HudChrome.SetRecede(1.0)
end

--------------------------------------------------------------------------------
-- Status block (folded into `/cdmp hud status`)
--------------------------------------------------------------------------------
function S.PrintStatus()
  ns.Heading("  state — M3b (readiness + procs) + M3c-a (the dot score)")
  ns.Printf("   alert hooks: %d item(s)   edges: Available=%d OnCooldown=%d AuraApplied=%d AuraRemoved=%d  (charge=%d pandemic=%d other=%d |cffff4040secret=%d|r)",
    S.hooks, S.fires.available, S.fires.oncd, S.fires.applied, S.fires.removed,
    S.fires.charge, S.fires.pandemic, S.fires.other, S.fires.secret)
  -- Split out of `other` (B3): `other` = an alert type we don't handle (benign),
  -- `errors` = the handler THREW and the pcall ate it (never benign).
  ns.Printf("   handler errors (swallowed by the hook's pcall): %s",
    S.fires.errors > 0 and string.format("|cffff4040%d|r — this is a BUG, not a curiosity", S.fires.errors)
      or "|cff88ff880|r")
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

  -- ── the score block ────────────────────────────────────────────────────────
  ns.Heading("  score — M3c-a (the dot)")
  -- Is the whole anticipation feature live?  Reported, never assumed: this is
  -- the milestones.md §7 standing assumption made visible.  CHECK IT IN A RAID —
  -- the dummy and the delve already say yes, and a raid is the untested context
  -- where the biggest win would silently go dark.
  ns.HudNapkin.PrintStatus()
  local counts, lit = {}, {}
  for key, sc in pairs(S.score) do
    counts[sc.level] = (counts[sc.level] or 0) + 1
    if sc.level == "ROTATION" or sc.level == "LATE" then
      local e = ns.Hud.items[key]
      local base = e and (e.baseSpellID or e.spellID)
      -- Name the LIVE identity (B1).  Naming the base here is what printed
      -- "Grimoire: Fel Ravager - up - use on cooldown" over a Devour Magic
      -- button; this line is the milestone's own exit measurement, so it has to
      -- report what is actually on screen.
      local id = (base and S.override[base]) or (e and e.spellID) or base
      lit[#lit + 1] = string.format("%s (%s)", (id and ns.SpellName(id)) or "?",
        ns.HudScore.Why(sc))
    end
  end
  ns.Printf("   levels: NEVER=%d AVAILABLE=%d |cff88ff88ROTATION=%d|r |cffffd100LATE=%d|r",
    counts.NEVER or 0, counts.AVAILABLE or 0, counts.ROTATION or 0, counts.LATE or 0)
  -- Strictness is the whole UX.  If this line routinely names 4+, the RULES are
  -- too loose — tighten HudScore before touching a single visual.
  ns.Printf("   lit now: %s", #lit > 0 and table.concat(lit, "  |  ") or "|cff808080nothing|r")
end
