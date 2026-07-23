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
  readyAt        = {},    -- base spellID -> when readiness was established
  -- M3d — WHERE the current readiness boolean came from, mirroring the
  -- `lastEdge` idiom for presence.  "edge" = an observed alert, "seed" = an
  -- out-of-combat client read.  Both are direct observations and both render
  -- SOLID; this exists so the readout can tell them apart, which is also what
  -- keeps M3c-b and M3d separable inside one release.
  readySource    = {},    -- registry key -> "edge" | "seed"
  -- Did the last seeding pass actually get anything?  REPORTED, never assumed —
  -- the OOC read has only been measured open-world, and if it also goes secret
  -- in some other out-of-combat context (an instance lobby, between pulls)
  -- seeding silently does less.  That has to show up here rather than be
  -- inferred later from a shrug.  Same standing risk the napkin carries.
  seed           = { passes = 0, blocked = 0, seeded = 0, ready = 0,
                     unreadable = 0, readable = nil, at = nil },
  -- M3c-c1 — the shard rail's smoothing input.  Whole shards stay the GATE
  -- everywhere a decision is made; fragments only move the partial segment.
  fragments    = nil,     -- 0..(fragmentsMax), nil = unreadable in this context
  fragmentsMax = nil,
  -- v0.16.3 — MANUAL single/AoE flag, set from a macro (`/cdmp single|multi`).
  -- We deliberately do NOT auto-detect: nameplate counting is Secret-Value-risky
  -- in restricted content and settings-dependent, so the player owns this bit
  -- outright.  Session-only (resets to single on /reload) so it can never get
  -- stuck in the wrong mode across a login.  false = single target, true = AoE.
  aoe          = false,
}
local S = ns.HudState

-- The SPEND threshold, in one place.  §0.5.8.4:715 keys the mode off it and
-- board-quiet keys off the same number under the old `LOW_SHARDS` name — its
-- comment already called it "the SPEND threshold".  Derived rather than
-- repeated, so the rail's mode and the board's quiet can never drift apart.
local SPEND_AT     = 3
local LOW_SHARDS   = SPEND_AT   -- "board quiet" only below the SPEND threshold
-- M4 — the BURST lead.  How early (in seconds) Tyrant coming up flips the mode to
-- BURST, so the capping rule starts HOLDING HoG before the window rather than at
-- it.  DISTINCT from N.SOON_LEAD (=3, the dot's anticipation lead) by design
-- (§0.5.8.6 correction 1: NOT §0.5.1's stale ~15s, which force-overcaps).
local HOLD_LEAD    = 5.0
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

-- The SAME power, read at fragment resolution — `UnitPower(..., true)` reports
-- 0..50 where the whole-shard read reports 0..5.  Documented client behaviour on
-- a power we already know is readable and branchable, and it is used for exactly
-- ONE thing: smoothing the rail's partial segment.  Nothing scores off it.
--
-- ⚠ UNRELATED to the unproven fragment heuristic in `ns.ShardCost`.  That one is
-- about a SPELL's reported *cost* coming back in fragments; this reads the
-- player's power directly.  They share a word and nothing else — do not later
-- "unify" them.
local function readFragments()
  if not (Enum and Enum.PowerType) then return nil end
  local ok, n = pcall(UnitPower, "player", Enum.PowerType.SoulShards, true)
  if not ok or ns.IsSecret(n) or type(n) ~= "number" then return nil end
  local ok2, m = pcall(UnitPowerMax, "player", Enum.PowerType.SoulShards, true)
  if not ok2 or ns.IsSecret(m) or type(m) ~= "number" or m <= 0 then return nil end
  return n, m
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
  -- M3e — §7.3 item 5 wants `shards N ->~M` with a REAL TIMESTAMP, so the
  -- predictive SPEND flip can be shown to land inside the cast rather than a
  -- beat after it.  Noted after S.cast is set, so the projection quoted here is
  -- the one the board is about to score against.
  if ns.HudLog then
    local proj = S.ProjectedShards()
    ns.HudLog.Note("cast", string.format("START %s  cost=%d gen=%d  shards %s ->~%s",
      ns.SpellName(spellID) or tostring(spellID), cost, gen,
      tostring(S.shards), tostring(proj)))
  end
  if S.Recompute then S.Recompute() end
end

local function endCast()
  if S.cast == nil then return end
  if ns.HudLog then
    ns.HudLog.Note("cast", string.format("END   %s  shards %s",
      ns.SpellName(S.cast.spellID) or tostring(S.cast.spellID), tostring(S.shards)))
  end
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
-- THE MODE SPINE — M3c-c1
--------------------------------------------------------------------------------
-- §0.5.8.4:713-716's ladder, minus BURST.  One computation, so the rail and the
-- terminal chrome can never disagree about what mode we are in.
--
-- Returns (mode, projected, isProjected); mode is "PREP"|"SPEND"|"GENERATE"|nil.
--
--   * nil  — shards are UNREADABLE.  Unknown is a first-class state everywhere
--            in this module and is never guessed; the rail renders an explicit
--            unknown rather than an empty bar, because an empty bar is a CLAIM.
--   * PREP — out of combat.  §0.5.8.2(a)'s "fourth resting state, NOT GENERATE".
--            §0.5.1's three-mode table never mentions it (see §0.5.8.8).  M3c-c2
--            hangs the opener queue off this, so it ships a milestone early and
--            gets exercised before anything depends on it.
--   * SPEND — keyed on PROJECTED, not live (§0.5.8.4:715).  The predictive
--            pre-flip is the point: by the time the cast lands you are already
--            reading "now dump".  Being early is never WRONG ABOUT WHAT YOU CAN
--            PRESS, which is the §0.5.8.2(c) test the instructional cues fail.
--
-- BURST sits BETWEEN PREP and SPEND (added by M4): `if tyrant ready-or-within-
-- HOLD_LEAD -> "BURST"`, HOLD_LEAD ~= 5s (§0.5.8.6 correction 1 — NOT §0.5.1's
-- stale ~15s, which force-overcaps).  Keyed on TYRANT ALONE — see S.Mode below
-- for why Dreadstalkers is an output of the window, not part of its trigger.
-- The manual single/AoE toggle.  `v` is truthy for AoE.  Recomputes so the
-- board reflects the flip immediately, and logs it so a pull's events show WHEN
-- you switched — an Implosion that lit is only sensible against the mode you
-- were in when it lit.
function S.SetAoE(v)
  v = v and true or false
  if S.aoe == v then return v end
  S.aoe = v
  if ns.HudLog then ns.HudLog.Note("aoe", v and "AoE (multi-target)" or "single-target") end
  if hudOn() then pcall(S.Recompute) end
  return v
end

-- Is a go-gate summon READY (ground truth) or about to be (best-guess estimate)?
-- Readiness off the SAME edge store the dot uses (S.readyAt, set by an observed
-- Available alert); the napkin fills the "soon" lead when it's on cooldown.  An
-- observed ready edge always wins — that is what keeps a wrong estimate safe.
local function readyOrSoon(spellID, lead)
  if spellID == nil then return false end
  if S.readyAt[spellID] then return true end
  local r = ns.HudNapkin and ns.HudNapkin.Remaining(spellID)
  return r ~= nil and r <= (lead or HOLD_LEAD)
end

function S.Mode()
  local projected, isProjected = S.ProjectedShards()
  if projected == nil then return nil, nil, false end
  if not InCombatLockdown() then return "PREP", projected, isProjected end
  -- [M4] BURST — the Tyrant window, keyed on TYRANT ALONE (Tyrant up or within
  -- HOLD_LEAD).  Dreadstalkers is deliberately NOT in the trigger any more: M4
  -- made it an OUTPUT of BURST (its dot reads "stage for Tyrant"), so folding it
  -- into the trigger would be circular — a staged-and-held Dreadstalkers would
  -- keep the window from ever opening.  Sits BETWEEN PREP and SPEND: the build-to-
  -- cap rule and the Dreadstalkers stage-hold both read this one mode.  Best-guess
  -- on the napkin clock (the §7.3 cast-readability assumption); safe because it
  -- only ever HOLDS, never presses, and a native ready alert is ground truth.
  if readyOrSoon(ns.SpecIDs and ns.SpecIDs.TYRANT, HOLD_LEAD) then
    return "BURST", projected, isProjected
  end
  if projected >= SPEND_AT then return "SPEND", projected, isProjected end
  return "GENERATE", projected, isProjected
end
S.SPEND_AT = SPEND_AT
S.HOLD_LEAD = HOLD_LEAD

-- Everything the rail draws, computed in ONE place so HudChrome stays a painter.
-- `fill` is the smoothed figure: WHOLE shards from the gate every score already
-- trusts, and only the FRACTIONAL part from the fragment read.  If fragments are
-- unreadable here, fill == shards and the rail simply draws whole segments —
-- nothing else in the widget changes.
function S.RailInfo()
  local mode, projected, isProjected = S.Mode()
  local cap  = ns.SHARD_CAP or 5
  local live = S.shards
  local fill, smoothed = live, false
  if live ~= nil then
    if live >= cap then
      fill = cap
    elseif S.fragments and S.fragmentsMax and S.fragmentsMax > 0 then
      local f = (S.fragments / S.fragmentsMax) * cap
      local part = f - math.floor(f)
      if part > 0 then smoothed = true end
      fill = live + math.max(0, math.min(0.99, part))
    end
  end
  return {
    mode = mode, cap = cap, shards = live, fill = fill, smoothed = smoothed,
    projected = projected, isProjected = isProjected,
    capped = (live ~= nil and live >= cap),
    fragmentsReadable = (S.fragments ~= nil),
  }
end

-- The one redraw door.  Honours the setting here rather than in the painter, so
-- `rail = false` costs a table compare and nothing else.
function S.PaintRail()
  if not hudOn() then return end
  local info = S.RailInfo()
  -- M3e — §7.5 item 4: the PREDICTIVE SPEND flip, timestamped.  Logged HERE
  -- rather than in the painter and ABOVE the `rail = false` early-out, because
  -- the mode is STATE, not chrome: turning the widget off must not turn the
  -- measurement off.  CAP is recorded as a treatment on SPEND (HudChrome's
  -- reading), so a flip into and out of cap is visible as a mode move.
  if ns.HudLog then
    local key = info.mode and (info.capped and (info.mode .. "/CAP") or info.mode) or "UNKNOWN"
    if key ~= S.lastMode then
      ns.HudLog.Note("mode", string.format("%s -> %s  (shards %s%s)",
        S.lastMode or "-", key, tostring(info.shards),
        info.isProjected and string.format(", projected ~%s", tostring(info.projected)) or ""))
      S.lastMode = key
    end
  end
  -- M4 — the burst window is the sequence pane's second consumer, driven off the
  -- mode.  Above the `rail = false` early-out for the same reason the log is: the
  -- mode is STATE, not chrome, so turning the rail off must not turn burst off.
  if ns.HudBurst then pcall(ns.HudBurst.OnMode, info.mode) end
  if ns.db and ns.db.hud and ns.db.hud.rail == false then return end
  pcall(ns.HudChrome.PaintRail, info)
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

-- The icon item a CAST spellID belongs to (D, M4.4 — the cast-start flash).  A
-- direct match first; failing that, an override cast (Ruination for HoG) resolves
-- back to the base icon it landed on.  nil when the spell isn't drawn.
local function castItemFor(spellID)
  local item = iconItemFor(spellID)
  if item then return item end
  for base, over in pairs(S.override) do
    if over == spellID then return iconItemFor(base) end
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
--   * the dot itself — one SetCue per icon item, so the scorer never touches a
--     frame.
-- The LIVE identity of a registry entry, as a name.  ONE definition, because
-- naming the BASE here is precisely what printed "Grimoire: Fel Ravager — use on
-- cooldown" over a Devour Magic button (M3c-b B1).  PrintStatus, the pull
-- recorder and the seeding log all resolve it the same way — override event ->
-- the item's own reported spell -> the base — so a log written to MEASURE that
-- bug can never re-introduce it.
function S.LiveID(e)
  if not e then return nil end
  local base = e.baseSpellID or e.spellID
  return (base and S.override[base]) or e.spellID or base
end

local function liveName(e)
  local id = S.LiveID(e)
  return (id and ns.SpellName(id)) or (id and tostring(id)) or "?"
end
S.LiveName = liveName

-- Scratch, reused across passes: the keys lit at ROTATION/LATE this pass.  A
-- reused table and integer appends only — the SAMPLE path must stay free of
-- string work (HudLog's header), and the reason strings are built ONLY when
-- HudLog.Sample reports a new peak.
local litKeys = {}
-- Scratch for the board-aware pass (v0.16.2): key -> score, computed in phase A
-- so the FILLER resolution can see whether anything better is lit before phase B
-- paints.  Reused (wiped) each Recompute; never allocates.
local scores = {}

function S.Recompute()
  if not (hudOn() and ns.HudScore) then return end
  local now = GetTime()
  local lit = 0
  wipe(litKeys)

  -- ── Phase A — score every item, and note if anything better than filler is up.
  -- FILLER (Shadow Bolt) is "what you press when nothing else is lit", so it can
  -- only be resolved against the whole board — which the per-item scorer cannot
  -- see.  So HudScore leaves it AVAILABLE and we decide here (v0.16.2).
  wipe(scores)
  local anyRotation = false
  for key, e in pairs(ns.Hud.items) do
    if ns.Hud.IsIconViewer(e.viewer) and e.item then
      local ok, sc = pcall(ns.HudScore.For, key, e)
      scores[key] = ok and sc or false
      if ok and sc and (sc.level == ns.HudScore.LEVELS.ROTATION) then
        anyRotation = true
      end
    end
  end
  -- The filler resolves against the board: NEVER when a real call is up, else it
  -- IS your press (ROTATION, but never a LATE candidate — a filler shouldn't
  -- nag).  Only touches a filler the scorer left at AVAILABLE, so SPEND-mode
  -- fillers (already pruned to NEVER) stay pruned.
  local inCombat = InCombatLockdown()
  for key, sc in pairs(scores) do
    if sc and sc.cadence == "filler" and sc.level == ns.HudScore.LEVELS.AVAILABLE then
      if anyRotation then
        sc.level = ns.HudScore.LEVELS.NEVER
        sc.reasons[#sc.reasons + 1] = "better options up"
      elseif inCombat then
        sc.level = ns.HudScore.LEVELS.ROTATION
        sc.candidate = false
        sc.reasons[#sc.reasons + 1] = "filler — nothing better up"
      end
    end
  end

  -- ── Phase B — clock, log transitions, paint.  Uses the phase-A scores.
  for key, e in pairs(ns.Hud.items) do
    if ns.Hud.IsIconViewer(e.viewer) and e.item then
      local sc = scores[key]
      if sc then
        -- B6 — LATE MUST NOT ACCRUE OUT OF COMBAT, and the CLOCK must not run
        -- there either.  LATE is a NAG ("been a candidate 3s+, press it") — a nag
        -- with nothing to nag about trains the player to ignore the channel.
        --
        -- ⚠ M3e caught this GATE IN THE WRONG PLACE.  The promotion below was
        -- combat-gated, but the STAMP (`= … or now`) was not — so the clock ran
        -- out of combat, and B6's combat-exit `wipe(candidateSince)` was undone
        -- 0.25s later by the always-on scoreTicker.  Standing 43s at a dummy then
        -- pulling opened the fight with every "use on cooldown" button already at
        -- "waiting 43s" on frame 1 — observed in BOTH recorded pulls (peak set at
        -- +0.08s, "waiting 43s" / "waiting 19s" matching the idle time exactly).
        -- The stamp and the promotion are ONE decision and share ONE gate now;
        -- entering combat starts the clock fresh from the first in-combat frame.
        -- (InCombatLockdown is readable and branchable — the secure-API lockdown
        -- flag, not combat state; same precedent quiet() relies on above.)
        if sc.candidate and InCombatLockdown() then
          S.candidateSince[key] = S.candidateSince[key] or now
          local since = S.candidateSince[key]
          if (now - since) >= LATE_AFTER then
            sc.level = ns.HudScore.LEVELS.LATE
            sc.reasons[#sc.reasons + 1] = string.format("waiting %.0fs", now - since)
          end
        else
          -- Not a candidate, OR out of combat: no clock.  Out of combat this also
          -- means a candidate carries NO stale timestamp into the pull — which is
          -- the whole point.  (The combat-exit wipe is now redundant but harmless.)
          S.candidateSince[key] = nil
        end
        -- M3e — the TRANSITION.  `S.score[key]` still holds the PREVIOUS score at
        -- this point, so the compare has to happen before the assignment below.
        -- Recorded on a move of the level or of soon/projected, because those two
        -- change what the dot CLAIMS even when the level is unmoved.  This is the
        -- path that is allowed to cost strings; the sample path below is not.
        local prev = S.score[key]
        if ns.HudLog and (not prev or prev.level ~= sc.level
            or (prev.soon or false) ~= (sc.soon or false)
            or (prev.projected or false) ~= (sc.projected or false)) then
          ns.HudLog.Note("dot", string.format("%s  %s -> %s%s%s : %s",
            liveName(e), prev and prev.level or "-", sc.level,
            sc.soon and "/SOON" or "", sc.projected and " ~est" or "",
            ns.HudScore.Why(sc)))
        end
        if sc.level == ns.HudScore.LEVELS.ROTATION or sc.level == ns.HudScore.LEVELS.LATE then
          lit = lit + 1
          litKeys[lit] = key
        end
        S.score[key] = sc
        -- M4.1 — the 4th arg is now `judgeReady` (was the B4 hollow flag, retired
        -- with the disc): a judgeable=false ability that is otherwise up (Implosion
        -- off cooldown) lights the cue bar cyan "ready, your call".  The B4 estimate
        -- marker now rides the debug row's `~est` text only.
        -- SOON is a treatment on NEVER, never a level of its own: it brightens
        -- and counts down but claims nothing about pressability.
        -- The 5th arg is `emphasis` (A3, M4.4) — "burst" makes Tyrant's cue bar
        -- the widest on the board regardless of level.
        pcall(ns.HudChrome.SetCue, e.item, e.viewer,
          (sc.soon and sc.level == ns.HudScore.LEVELS.NEVER) and "SOON" or sc.level,
          sc.judgeReady, sc.emphasis)
      else
        -- Losing a dot is a transition too, and a LOUD one: it is what an
        -- unrecognised override looks like (HudScore returns nil rather than
        -- inheriting the base's cadence).  Silence here would hide the very case
        -- B1 exists to make safe.
        if ns.HudLog and S.score[key] then
          ns.HudLog.Note("dot", string.format("%s  %s -> (no dot)",
            liveName(e), S.score[key].level))
        end
        S.score[key] = nil
        S.candidateSince[key] = nil
        pcall(ns.HudChrome.SetCue, e.item, e.viewer, nil)
      end
    end
  end
  -- M3c-c1 — the rail rides the same recompute set as the dots.  This is the
  -- ONE tail that sees every input the mode reads: RefreshGlows ends here (aura
  -- edges, shard changes, overrides), and so do beginCast/endCast — which is
  -- what makes the predictive SPEND flip land DURING the cast rather than a beat
  -- after it.  No new ticker: HudCore.lua's header rule stands.
  S.PaintRail()
  -- M3c-c2 — the opener's dissolve clock (first Tyrant window close).  On the
  -- same tail, no new ticker; a cheap elapsed-time compare against the Tyrant cast.
  if ns.HudOpener then ns.HudOpener.Tick() end
  if ns.HudBurst then ns.HudBurst.Tick() end
  -- M3e — the SAMPLE, on the same tail and for the same reason: this is the one
  -- place that sees every input.  Sample() is one increment; the reason strings
  -- are built ONLY when it reports a new peak, which is rare by construction.
  if ns.HudLog and ns.HudLog.Sample(lit) then
    local set = {}
    for i = 1, lit do
      local k = litKeys[i]
      set[i] = string.format("%s (%s)", liveName(ns.Hud.items[k]),
        ns.HudScore.Why(S.score[k]))
    end
    ns.HudLog.Peak(set)
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
    -- the countdown said.  The estimate is never allowed to outlive an
    -- observation — and as of M3d that includes a SEED, which is why Clear is
    -- unconditional rather than checking where the record came from.
    local key, e = keyFor(item)
    if key then S.readySource[key] = "edge" end
    -- M3e — §7.4 item 2, THE GCD TRAP, is a TIMING defect: nothing genuinely
    -- ready may flip to on-cooldown inside the 1.5s global.  That is unreadable
    -- from a snapshot and obvious from two timestamps.
    if ns.HudLog then ns.HudLog.Note("ready", liveName(e) .. "  READY (edge)") end
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
    local key, e = keyFor(item)
    if key then S.readySource[key] = "edge" end
    if ns.HudLog then ns.HudLog.Note("ready", liveName(e) .. "  ON COOLDOWN (edge)") end
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
-- OUT-OF-COMBAT SEEDING — M3d
--------------------------------------------------------------------------------
-- THE COLD START, deleted.  Until now readiness came ONLY from an observed
-- alert edge, so on every login, /reload and zone-in every cooldown-bearing
-- ability read `NEVER · no edge seen yet` until it had been cast once and had
-- run a full cooldown cycle.  That was written up as "the design holding, not a
-- bug" — the M3b doctrine is that we refuse to GUESS a secret.  We still do.
-- This is READING, not guessing (see ns.ReadCooldown's header for the measured
-- evidence), and the doctrine stands unchanged inside combat.
--
-- Three rules, and none of them is optional:
--
--   * UNREADABLE TOUCHES NOTHING.  A `nil` from ns.ReadCooldown is not evidence
--     of anything.  Overwriting a known state with it is the exact B2-shaped
--     mistake — keep what you had.
--   * NEVER IN COMBAT.  Gated here AND inside ns.ReadCooldown, because a caller
--     added later will not remember.
--   * NO TICKER.  Out of combat a finishing cooldown still fires its `Available`
--     alert edge, so the event path already covers the tail — consistent with
--     the standing "if something detaches, the fix is another EVENT, not the
--     ticker back" (HudCore.lua header).
function S.SeedFromReads()
  if not hudOn() then return end
  if InCombatLockdown() then
    S.seed.blocked = S.seed.blocked + 1
    if ns.HudLog then ns.HudLog.Note("seed", "skipped — in combat (by design)") end
    return
  end
  local seeded, ready, unreadable = 0, 0, 0
  for key, e in pairs(ns.Hud.items) do
    if ns.Hud.IsIconViewer(e.viewer) and e.item then
      -- The LIVE identity, resolved the way B1 established it in HudScore.For:
      -- override event -> the item's own reported spell -> the base.  Seeding a
      -- transformed button from the ability underneath it would put a real,
      -- confident countdown on a spell that isn't on the bar — B1's failure
      -- with better numbers.  Do NOT re-derive this a second way.
      local base   = e.baseSpellID or e.spellID
      local liveID = (base and S.override[base]) or e.spellID or base
      local isReady, _, duration, startTime = ns.ReadCooldown(liveID)
      if isReady == nil then
        unreadable = unreadable + 1
      elseif isReady then
        ready = ready + 1
        ns.HudChrome.SetReady(e.item, true)
        -- Same both-identities clear as the Available edge: SUCCEEDED files a
        -- napkin under whatever spellID actually went off, which is the
        -- OVERRIDE while a transform is armed.
        ns.HudNapkin.Clear(liveID)
        if base and base ~= liveID then ns.HudNapkin.Clear(base) end
        S.readySource[key] = "seed"
        if base then S.readyAt[base] = GetTime() end
      else
        seeded = seeded + 1
        ns.HudChrome.SetReady(e.item, false)
        ns.HudNapkin.Seed(liveID, startTime, duration)
        S.readySource[key] = "seed"
        if base then S.readyAt[base] = nil end
      end
    end
  end
  S.seed.passes = S.seed.passes + 1
  S.seed.seeded, S.seed.ready, S.seed.unreadable = seeded, ready, unreadable
  S.seed.at = GetTime()
  -- Only ever set from a pass that had something to say.  A board with no items
  -- proves nothing about whether reads work here.
  if seeded + ready > 0 then S.seed.readable = true
  elseif unreadable > 0 then S.seed.readable = false end
  -- M3e — §7.4 items 1/3: what a /reload or a combat exit ACTUALLY seeded.  The
  -- status block reports the last pass; this one is timestamped and survives to
  -- disk, which is the difference between "seeding works" and "seeding worked at
  -- 12.4s into that pull, on 6 of 9 buttons".
  if ns.HudLog then
    ns.HudLog.Note("seed", string.format("%d on cd / %d ready / %d unreadable  (reads %s)",
      seeded, ready, unreadable,
      S.seed.readable == true and "live" or (S.seed.readable == false and "SECRET here" or "?")))
  end
  S.Recompute()
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
    -- M3e — the pull boundary.  BeginPull KEEPS whatever prologue was recorded
    -- since the last pull closed (a /reload's seeding pass, a keybind rescan) and
    -- only bases the clock + clears the distribution, so the run-up to the pull
    -- is readable beside it.
    if event == "PLAYER_REGEN_DISABLED" and ns.HudLog then ns.HudLog.BeginPull() end
    if event == "PLAYER_REGEN_ENABLED" then
      -- B6's other half.  Leaving combat clears the candidate clocks so the next
      -- pull starts them FRESH — otherwise an ability that became a candidate as
      -- the last mob died carries a stale timestamp into the opener and promotes
      -- straight to LATE on the first frame of the fight.
      wipe(S.candidateSince)
      S.cast = nil
      -- M3d — leaving combat RE-TRUTHS the whole board from reads.  Reads go
      -- secret in combat, so the board has been running on edges + estimates for
      -- the length of the fight; this is the first moment we can ask the client
      -- again.  It is also the free fix for "should be up, unconfirmed": a
      -- drifted estimate is replaced by a real number the instant combat ends.
      pcall(S.SeedFromReads)
      -- M4 — combat is over, so any open burst window is closed.  Dissolve it
      -- FIRST, before the opener re-arms the shared pane below.
      if ns.HudBurst then pcall(ns.HudBurst.OnCombatEnd) end
      -- M3c-c2 — we are back in PREP; re-arm the opener for the NEXT pull.
      if ns.HudOpener then pcall(ns.HudOpener.OnCombatEnd) end
    end
    S.fragments, S.fragmentsMax = readFragments()
    S.EvaluateBoard()          -- combat state is half of "is the board quiet?"
    S.PaintRail()              -- ...and ALL of PREP vs GENERATE
    -- Closed LAST, after seeding and the PREP repaint, so the combat-exit seed
    -- and the mode flip out of SPEND land INSIDE the pull they belong to.
    -- Nothing is printed: the summary goes to ns.db.pulls (HudLog's header).
    if event == "PLAYER_REGEN_ENABLED" and ns.HudLog then pcall(ns.HudLog.EndPull) end
  elseif event == "UNIT_POWER_UPDATE" or event == "UNIT_POWER_FREQUENT" then
    if a1 ~= "player" then return end
    local n = readShards()
    local fr, fm = readFragments()
    -- ⚠ The old early-out compared WHOLE shards only, which swallows every
    -- fragment-only change — the partial segment would freeze between whole
    -- steps and the smoothing would silently do nothing.  Both values are
    -- compared, but they take DIFFERENT paths: a whole-shard step moves gates
    -- (softening, board-quiet, every score), a fragment tick moves one texture's
    -- width and must not drag a full board re-evaluation behind it.
    local wholeChanged = (n ~= S.shards)
    if wholeChanged or fr ~= S.fragments then
      S.shards = n
      S.fragments, S.fragmentsMax = fr, fm
      if wholeChanged then
        S.RefreshGlows()        -- re-evaluates softening + the board (+ the rail)
      else
        S.PaintRail()
      end
    end
  elseif event == "UNIT_SPELLCAST_START" then
    -- (unit, castGUID, spellID) — RegisterUnitEvent already filters to player.
    pcall(beginCast, a3)
    -- C2 (M4.4) — the sequence pane's start-side shimmer, the sibling of the
    -- SUCCEEDED OnCast route below.  Ownership tags keep only the armed one lit.
    if ns.HudOpener then pcall(ns.HudOpener.OnCastStart, a3) end
    if ns.HudBurst then pcall(ns.HudBurst.OnCastStart, a3) end
    -- D (M4.4) — a quiet cast-start flash beside the CASTING icon.  START fires
    -- only for cast-time spells (an instant fires SUCCEEDED alone), so gating on
    -- this event already scopes D to cast-time abilities.  Resolve the (possibly
    -- overridden) cast id back to the icon it landed on.
    if type(a3) == "number" and not ns.IsSecret(a3) then
      local item = castItemFor(a3)
      if item then pcall(ns.HudChrome.CastFlash, item) end
    end
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" or event == "UNIT_SPELLCAST_STOP"
      or event == "UNIT_SPELLCAST_INTERRUPTED" then
    -- M3c-c2 — a SUCCEEDED cast advances the opener queue (STOP/INTERRUPTED do
    -- not: the press never landed).  a3 is the spellID; the consumer resolves it
    -- back to the base identity so a transformed press still matches its step.
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
      if ns.HudOpener then pcall(ns.HudOpener.OnCast, a3) end
      -- M4 — the burst window is the second consumer of the same sequence pane;
      -- ownership tags (HudPane) keep only the armed one advancing.
      if ns.HudBurst then pcall(ns.HudBurst.OnCast, a3) end
    end
    -- C2 (M4.4) — the cast is over (landed, stopped or interrupted), so the
    -- start-side "casting…" shimmer has no business outliving it.  A SUCCEEDED
    -- already gave way to the advance pop; a fizzle just clears the shimmer.
    if ns.HudPane then pcall(ns.HudPane.ClearCastStart) end
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
  S.fragments, S.fragmentsMax = readFragments()
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
  wipe(S.readySource)
  S.fragments, S.fragmentsMax = nil, nil
  S.lastMode = nil           -- so a re-enable logs its first mode as a transition
  ns.HudChrome.SetRecede(1.0)
  pcall(ns.HudChrome.HideRail)
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

  -- ── M3d: is out-of-combat seeding actually working HERE? ───────────────────
  -- "Capability is reported, never assumed" — the same standing the napkin's own
  -- status line has.  The OOC read is MEASURED open-world only; if it goes
  -- secret in some other context this line is how we find out, rather than
  -- wondering later why the cold start came back.
  local verdict
  if InCombatLockdown() then
    verdict = "|cffffd100unavailable in combat|r — by design; the board is running on EDGES + estimates until you drop combat"
  elseif S.seed.readable == true then
    verdict = "|cff88ff88live|r — the client answers cooldown reads in this context"
  elseif S.seed.readable == false then
    verdict = "|cffff4040unreadable here|r — reads came back <secret> out of combat; seeding is OFF in this context"
  else
    verdict = "|cff808080not probed|r — no seeding pass with items yet"
  end
  ns.Printf("   seeding (M3d, out-of-combat reads): %s", verdict)
  ns.Printf("     last pass: %d on cooldown (seeded) / %d ready / %d unreadable   passes=%d  skipped-in-combat=%d",
    S.seed.seeded, S.seed.ready, S.seed.unreadable, S.seed.passes, S.seed.blocked)
  for sourceID, rule in pairs(ns.SpecProcGlow or {}) do
    local st = S.glowing[sourceID]
    ns.Printf("   glow %s: %s   last edge: %s",
      rule.label or tostring(sourceID),
      st and string.format("|cff88ff88ON|r (strength %.2f)", st) or "|cff808080off|r",
      S.lastEdge[sourceID] or S.lastEdge[rule.target] or "|cff808080none yet|r")
  end

  -- ── M3c-c1: the rail + the mode spine ──────────────────────────────────────
  -- Same "capability is reported, never assumed" standing as the napkin's line
  -- and M3d's seeding verdict.  The load-bearing report is whether FRAGMENTS are
  -- readable IN THIS CONTEXT: whole shards are confirmed readable+branchable,
  -- the fragment resolution is not, and if it goes secret somewhere the only
  -- symptom is a partial segment that never moves — which looks like a bug in
  -- the widget rather than an answer about the client.
  ns.Heading("  rail — M3c-c1 (the shard rail + mode spine)")
  local info = S.RailInfo()
  local rs = ns.HudChrome.RailStats and ns.HudChrome.RailStats() or {}
  ns.Printf("   mode: %s   whole shards: %s / %d%s",
    info.mode and ("|cffffd100" .. info.mode .. "|r")
      or "|cffff4040unknown|r — shards unreadable; the rail draws UNKNOWN, never an empty bar",
    info.shards and tostring(info.shards) or "|cffff4040?|r", info.cap,
    info.capped and "   |cffffd100AT CAP — act or waste|r" or "")
  ns.Printf("   fragments (partial-segment smoothing only): %s",
    info.fragmentsReadable
      and string.format("|cff88ff88readable here|r — %s/%s (%s)",
            tostring(S.fragments), tostring(S.fragmentsMax),
            info.smoothed and "partial segment live" or "sitting on a whole shard")
      or "|cffffd100unreadable here|r — whole segments only; that is an ANSWER, not a failure")
  ns.Printf("   projected: %s   (live %s -> %s%s)   SPEND_AT=%d",
    info.isProjected and "|cffffd100yes — the rail's head is HOLLOW|r" or "|cff808080no in-flight cast|r",
    info.shards and tostring(info.shards) or "?",
    info.projected and tostring(info.projected) or "?",
    info.isProjected and ", pre-flip active" or "", SPEND_AT)
  -- [X2] — WCAG's three-flashes-in-one-second guidance.  The M1 prototype fired
  -- on EVERY capped edge, so cap -> HoG -> cap re-fired within a couple of GCDs.
  ns.Printf("   cap edges: %d   glitter fired: %d   |cffffd100suppressed by the %.1fs re-arm: %d|r",
    rs.edges or 0, rs.glitters or 0, rs.rearm or 0, rs.suppressed or 0)

  -- ── the score block ────────────────────────────────────────────────────────
  ns.Heading("  score — M3c-a (the dot)")
  ns.Printf("   target mode (/cdmp single|multi): %s  |cff808080(scaffolding — no Demo dot depends on it)|r",
    S.aoe and "|cffbef264MULTI (AoE)|r" or "|cff88ccffSINGLE|r")
  -- Is the whole anticipation feature live?  Reported, never assumed: this is
  -- the milestones.md §7 assumption made visible.  The dummy and the delve both
  -- say yes and we treat it as settled — this line exists so that if it is ever
  -- wrong somewhere, you SEE it here instead of wondering why the biggest win
  -- quietly stopped happening.
  ns.HudNapkin.PrintStatus()
  local counts, lit = {}, {}
  for key, sc in pairs(S.score) do
    counts[sc.level] = (counts[sc.level] or 0) + 1
    if sc.level == "ROTATION" or sc.level == "LATE" then
      -- Name the LIVE identity (B1) — via the ONE resolver (S.LiveName), which
      -- the pull recorder's peak set also uses.  Naming the base here is what
      -- printed "Grimoire: Fel Ravager - up - use on cooldown" over a Devour
      -- Magic button; this line is the milestone's own exit measurement, so it
      -- has to report what is actually on screen.
      lit[#lit + 1] = string.format("%s (%s)", liveName(ns.Hud.items[key]),
        ns.HudScore.Why(sc))
    end
  end
  ns.Printf("   levels: NEVER=%d AVAILABLE=%d |cff88ff88ROTATION=%d|r |cffffd100LATE=%d|r",
    counts.NEVER or 0, counts.AVAILABLE or 0, counts.ROTATION or 0, counts.LATE or 0)
  -- Strictness is the whole UX.  If this line routinely names 4+, the RULES are
  -- too loose — tighten HudScore before touching a single visual.
  ns.Printf("   lit now: %s", #lit > 0 and table.concat(lit, "  |  ") or "|cff808080nothing|r")
end
