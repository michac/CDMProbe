-- State.lua — the REDUCED CLIENT PICTURE (W4 pipeline Stage 1).
--
-- The one stage that touches the game API, distilled to a spec-agnostic table
-- everything above the pipeline consumes: State -> Coach -> Guidance -> Binder ->
-- DrawList -> Renderer (docs/architecture.md).  This file builds ONLY Stage 1.  It
-- decides no cue, knows no rotation, imports no SpecDemonology — that is invariant
-- #3, and it is enforced from the outside by `wowkb.cdmp check`'s statelog denylist.
--
-- WHY IT EXISTS SEPARATELY FROM HudState.lua.  HudState is the de-facto State layer
-- today, but 1,254 lines that also score and paint (w4-hud-audit.md A4), with three
-- copies of live-identity resolution (B1) and three event-ingest frames (A3).  This
-- is the clean-room Stage-1 extraction the W4 refactor builds up from.  It COEXISTS
-- with HudState during Phase 1 — parallel observation, the live HUD untouched (the
-- build plan's P1) — and the old frames are deleted only at the Phase-5 cutover.
--
-- FOUR THINGS MAKE THIS "State", not "a reader":
--   1. ANCHORED ON THE CDM DATABASE, not the live viewer frames.  We enumerate the
--      full trackable set per category via C_CooldownViewer.GetCooldownViewerCategorySet
--      (allowUnlearned=true) and read structural metadata with
--      GetCooldownViewerCooldownInfo.  That covers undisplayed/unlearned entries the
--      viewer frames never show, and it is STRUCTURAL (spellID / overrides /
--      hasAura / charges / flags), never rotational — exactly the spec-agnostic split.
--   2. SECRECY IS FIRST-CLASS (invariant #4).  Under Midnight 12.0 many combat reads
--      return Secret Values that cannot be compared/formatted/keyed without erroring.
--      Every live fact is therefore a VALUE or a marked absence (`readable=false`,
--      the value field simply absent) — never a raw secret, on screen or on disk.
--   3. IDENTITY RESOLUTION LIVES HERE, ONE COPY (fixes B1).  We carry the raw ids
--      (spellID = base, plus overrideSpellID / overrideTooltipSpellID) and resolve a
--      single `liveSpellID` the whole pipeline reads, with its inverse `BaseOfCast`
--      (B3) beside it.  Keybinds still resolve off the BASE (the v0.7.0 finding-3
--      rule); the two resolutions are deliberately NOT unified.
--   4. THE NAPKIN AND KEYBINDS ARE CONSULTED THROUGH State, not ad-hoc.  A cd we
--      cannot read live falls to the napkin's anticipation (`source="napkin"`,
--      state="anticipated"); an expired estimate stays "unknown", never "ready" (the
--      napkin honesty rule).  The keybind is the OOC-resolved base-id binding.
--
-- NOT IN THIS FILE: any consumer of State.  Build() emits a table; nothing scores
-- it.  The `/cdmp statelog` capture at the bottom records pulses to disk so the
-- Phase-2 Coach can be tested against an INDEPENDENT corpus (build plan P2) — that
-- is observation, not consumption.
local ADDON, ns = ...

ns.State = {}
local St = ns.State

--------------------------------------------------------------------------------
-- The CDM database anchor
--------------------------------------------------------------------------------
-- `GetCooldownViewerCategorySet(category, allowUnlearned)` takes an ENUM, so we
-- iterate ALL categories rather than calling once (verified against wow-ui-source
-- @ 4383ced: CooldownViewerSettingsDataProvider.lua:85 loops the same four and
-- passes ALLOW_ALL_COOLDOWNS_IN_SET=true).  The two hidden sentinels (-1/-2) are
-- Blizzard's book-keeping mirror of the visible four and carry no entries of their
-- own, so they are left out.
local CATEGORY_NAME = {}       -- enum value -> "Essential" | ...  (built at load)

local function buildCategoryNames()
  local E = Enum and Enum.CooldownViewerCategory
  if type(E) ~= "table" then return end
  for name, value in pairs(E) do
    -- Skip the hidden sentinels (HiddenSpell=-1 / HiddenAura=-2) and any non-number.
    if type(value) == "number" and value >= 0 then
      CATEGORY_NAME[value] = name
    end
  end
end

-- Every (cooldownID, category) the client will admit to, across all categories.
-- Guarded end to end: the availability gate, the per-category call, and the id
-- type — an unreadable id is dropped rather than keyed (keying a secret errors).
local function enumerate()
  local out = {}   -- cooldownID -> categoryName
  if not (C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet) then
    return out
  end
  if C_CooldownViewer.IsCooldownViewerAvailable then
    local ok, avail = pcall(C_CooldownViewer.IsCooldownViewerAvailable)
    if not ok or not avail then return out end
  end
  for value, name in pairs(CATEGORY_NAME) do
    local ok, ids = pcall(C_CooldownViewer.GetCooldownViewerCategorySet, value, true)
    if ok and type(ids) == "table" then
      for _, id in ipairs(ids) do
        if type(id) == "number" and not ns.IsSecret(id) and out[id] == nil then
          out[id] = name
        end
      end
    end
  end
  return out
end

-- The structural struct, secret-guarded.  GetCooldownViewerCooldownInfo is
-- MayReturnNothing=true and its ids can read secret in restricted combat, so the
-- whole table is validated and every field pulled through `readable`.
local function readable(v)
  return type(v) == "number" and not ns.IsSecret(v)
end

local function cooldownInfo(cooldownID)
  if not (C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo) then
    return nil
  end
  local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
  if not ok or type(info) ~= "table" or ns.IsSecretTable(info) then return nil end
  return info
end

--------------------------------------------------------------------------------
-- Identity — one resolver, one copy (B1), with its inverse (B3)
--------------------------------------------------------------------------------
-- DISPLAY IDENTITY vs BASE IDENTITY are two different questions and must stay so.
--
--   * `liveSpellID` (display) follows Blizzard's own effective-spell precedence
--     for the fields a STRUCTURAL read exposes — the observed live override, then
--     overrideTooltipSpellID, then overrideSpellID, then the base spellID
--     (CooldownViewerItemData.lua:176-195 GetEffectiveSpellID; the active
--     aura/linkedSpellID rungs of that ladder live on the item MIXIN, not the info
--     struct, so the observed COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED override —
--     which is exactly what an aura-driven transform fires — stands in for them).
--   * `spellID` (base) is `info.spellID` untouched.  KEYBINDS RESOLVE OFF THE BASE
--     (HudBinds.GetForItem, the v0.7.0 finding-3 rule): the action bar holds the
--     base spell, so while HoG is transformed into Ruination the base still finds
--     the key.  Unifying the two reintroduces that bug.
--
-- `S.override` mirrors HudState's override map but is owned independently — State
-- must not reach into HudState's state (that would couple two things W4 is prying
-- apart).  Populated from the same event, guarded the same way.
St.override = {}          -- base spellID -> observed live override spellID

local function liveSpellID(info)
  if type(info) ~= "table" then return nil end
  local base = readable(info.spellID) and info.spellID or nil
  local over = base and St.override[base] or nil
  if readable(over) then return over end
  if readable(info.overrideTooltipSpellID) then return info.overrideTooltipSpellID end
  if readable(info.overrideSpellID) then return info.overrideSpellID end
  return base
end

-- The inverse of liveSpellID: given a cast spellID (which may be an override),
-- which base entry did it come from?  Rebuilt each Build() from the live set so it
-- can never drift from the identities the pulse reports.  This is B3's `baseOfCast`,
-- owned beside the override map as the audit asks.
St.baseOfCast = {}        -- any observed spellID -> base spellID

function St.BaseOfCast(spellID)
  if not readable(spellID) then return nil end
  return St.baseOfCast[spellID] or spellID
end

--------------------------------------------------------------------------------
-- Live facts — secrecy first-class
--------------------------------------------------------------------------------
-- Each returns a table that is ALWAYS shaped the same: a value plus `readable`, or
-- `readable=false` with the value fields absent.  No raw secret ever leaves here.

-- cd{state, remaining, readable, source}.  Reuses ns.ReadCooldown (the GCD-trap-
-- aware live read) and falls to the napkin when the client won't tell us live.
--   state ∈ ready | cooling | anticipated | unknown
--   source ∈ live | napkin | none
local function readCd(live, base)
  local isReady, remaining = ns.ReadCooldown(live)
  if isReady ~= nil then
    if isReady then
      return { state = "ready", remaining = 0, readable = true, source = "live" }
    end
    return { state = "cooling", remaining = ns.Stash(remaining),
             readable = true, source = "live" }
  end
  -- Not readable live (combat/secret) — consult the napkin's anticipation.  Query
  -- the live identity first, the base second (a transformed button's cast filed the
  -- napkin under whichever id fired SUCCEEDED).
  local N = ns.HudNapkin
  if N and N.Remaining then
    local rem = N.Remaining(live)
    if rem == nil and base and base ~= live then rem = N.Remaining(base) end
    if rem ~= nil then
      if rem > 0 then
        return { state = "anticipated", remaining = ns.Stash(rem),
                 readable = false, source = "napkin" }
      end
      -- Expired estimate: "should be up, unconfirmed" — NEVER "ready".  The one
      -- rule that keeps the napkin from lying (HudNapkin honesty rule).
      return { state = "unknown", readable = false, source = "napkin" }
    end
  end
  return { state = "unknown", readable = false, source = "none" }
end

-- charge{cur, max, readable}.  A banked charge means PRESSABLE whatever the recharge
-- timer says — the Coach's call to make; State just reports the pair honestly.
local function readCharge(live, hasCharges)
  if not hasCharges then return { readable = true, cur = nil, max = 0 } end
  local cur, max = ns.ReadCharges(live)
  if cur == nil then return { readable = false } end
  return { readable = true, cur = ns.Stash(cur), max = ns.Stash(max) }
end

-- aura{active, readable}.  Spec-agnostic: we ask the client whether the PLAYER has
-- the entry's own aura up, nothing about what it MEANS.
--
-- ⚠ GATE ON EITHER FLAG (v0.30.0 fix).  The CDM marks the two aura roles apart:
--   * `selfAura` — the entry IS a self-buff to watch.  Demonic Core (264173) is one
--     (cooldownID 777, selfAura=true, hasAura=FALSE), as are Tyrant/Dominion/Wild Imp.
--     These are exactly the procs the pipeline cares about.
--   * `hasAura`  — a cast that also applies an aura (Healthstone, pet buffs).
-- v0.29.0 read only `hasAura`, so every proc aura was hard-coded inactive and never
-- observed.  Read whenever EITHER is set.
--
-- Presence, not contents, is the signal: a RETURNED aura table (secret or not) means
-- the buff is up.  We never index it, so a secret aura still reads as active — only a
-- thrown call is `readable=false`.  (Measured readable in combat this build, but the
-- guard stays: absence of a read is not evidence of absence of the buff.)
local function readAura(live, base, hasAura, selfAura)
  if not (hasAura or selfAura) then return { readable = true, active = false } end
  if not (C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) then
    return { readable = false }
  end
  for _, id in ipairs({ live, base }) do
    if readable(id) then
      local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, "player", id)
      if not ok then return { readable = false } end
      if type(aura) == "table" then return { readable = true, active = true } end
    end
  end
  return { readable = true, active = false }
end

--------------------------------------------------------------------------------
-- Power — keyed by the REAL power-type, spec-agnostically
--------------------------------------------------------------------------------
-- We report every power the character actually HAS (max > 0), keyed by the game's
-- own Enum.PowerType member name — "SoulShards", "Mana", … .  The Coach decides
-- which one matters; State has no opinion (invariant #3).  Readable-and-branchable
-- even in restricted combat for most powers, but guarded anyway: a power that turns
-- secret degrades to `readable=false` rather than tainting on a comparison.
local POWER_NAME = {}          -- enum value -> name   (built at load)

local function buildPowerNames()
  local E = Enum and Enum.PowerType
  if type(E) ~= "table" then return end
  for name, value in pairs(E) do
    if type(value) == "number" and value >= 0 and type(name) == "string" then
      -- First name wins for a value (Enum has no dup values, but be defensive).
      if POWER_NAME[value] == nil then POWER_NAME[value] = name end
    end
  end
end

local function readOnePower(value)
  local okM, max = pcall(UnitPowerMax, "player", value)
  if not okM or ns.IsSecret(max) or type(max) ~= "number" or max <= 0 then return nil end
  local okV, val = pcall(UnitPower, "player", value)
  if not okV or ns.IsSecret(val) or type(val) ~= "number" then
    return { readable = false, max = ns.Stash(max), type = value }
  end
  return { readable = true, value = ns.Stash(val), max = ns.Stash(max), type = value }
end

local function readPower()
  local out = {}
  for value, name in pairs(POWER_NAME) do
    local p = readOnePower(value)
    if p then out[name] = p end
  end
  return out
end

--------------------------------------------------------------------------------
-- Events — the delta since the last pulse (observed only)
--------------------------------------------------------------------------------
-- One ingest frame, one secret guard (the A3 "collapse to one" target, run here
-- ALONGSIDE the old three during Phase-1 observation — deleting the originals is
-- the Phase-5 cutover).  Handlers append to `pending`; Build() drains it into the
-- pulse's `events` and clears it, so each recorded pulse carries the delta since
-- the previous one.  Derived thresholds ("napkin getting close") are NOT events —
-- those are the Coach's call over State's honest countdown (architecture.md Events).
local pending = {}
local captureReason = nil       -- why the next poll should record (nil = no pull owed)

local function markCapture(reason)
  captureReason = captureReason or reason
end

local function pushEvent(e)
  pending[#pending + 1] = e
end

local eframe = CreateFrame("Frame")
eframe:SetScript("OnEvent", function(_, event, a1, a2, a3)
  if event == "COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED" then
    -- (baseSpellID, overrideSpellID).  Record the transform and update the one
    -- override map identity reads from.
    if readable(a1) then
      local from = St.override[a1]
      local to = readable(a2) and a2 or nil
      St.override[a1] = to
      pushEvent({ kind = "transform", base = a1, from = ns.Stash(from),
                  to = ns.Stash(to), at = GetTime() })
      markCapture("transform")
    end
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    -- a3 is the spellID (unit, castGUID, spellID); RegisterUnitEvent filters to
    -- player.  Resolve back to the base entry so the Coach can tie it to a cooldown.
    if readable(a3) then
      pushEvent({ kind = "cast_succeeded", spellID = a3,
                  base = ns.Stash(St.BaseOfCast(a3)), at = GetTime() })
      markCapture("cast")
    end
  elseif event == "PLAYER_REGEN_DISABLED" then
    pushEvent({ kind = "combat_start", at = GetTime() })
    markCapture("combat")
  elseif event == "PLAYER_REGEN_ENABLED" then
    pushEvent({ kind = "combat_end", at = GetTime() })
    markCapture("combat")
  end
  -- Power changes are NOT an event trigger — they fire far too often in a pull and
  -- flooded the ring (v0.29.0: 30 of 40 slots were power captures, evicting procs
  -- and the OOC baseline).  The poll's change-detection folds power into its
  -- signature instead, so a shard step still records but as a rate-limited 'change'.
end)

--------------------------------------------------------------------------------
-- Build — the pulse
--------------------------------------------------------------------------------
-- Constructs the reduced picture for THIS instant.  `drain` (capture path) moves
-- the pending events into the pulse and clears them; a diagnostic Build leaves them
-- for the next real capture so "delta since last pulse" stays honest.
function St.Build(drain)
  local set = enumerate()
  wipe(St.baseOfCast)

  local cooldowns = {}
  for cooldownID, categoryName in pairs(set) do
    local info = cooldownInfo(cooldownID)
    local base = info and readable(info.spellID) and info.spellID or nil
    local live = liveSpellID(info) or base
    local hasAura = info and info.hasAura and true or false
    local selfAura = info and info.selfAura and true or false
    local hasCharges = info and info.charges and true or false

    -- Build the inverse identity index as we go (B3).
    if base then St.baseOfCast[base] = base end
    if readable(live) then St.baseOfCast[live] = base or live end

    local linked = {}
    if info and type(info.linkedSpellIDs) == "table" then
      for _, id in ipairs(info.linkedSpellIDs) do
        if readable(id) then linked[#linked + 1] = id end
      end
    end

    cooldowns[cooldownID] = {
      -- structural metadata (spec-agnostic)
      cooldownID = cooldownID,
      category   = categoryName,
      spellID    = ns.Stash(base),
      liveSpellID = ns.Stash(readable(live) and live or nil),
      overrideSpellID = info and ns.Stash(readable(info.overrideSpellID) and info.overrideSpellID or nil) or nil,
      overrideTooltipSpellID = info and ns.Stash(readable(info.overrideTooltipSpellID) and info.overrideTooltipSpellID or nil) or nil,
      linkedSpellIDs = linked,
      selfAura   = selfAura,
      hasAura    = hasAura,
      charges    = hasCharges,
      isKnown    = info and (info.isKnown and true or false) or nil,
      flags      = info and ns.Stash(info.flags) or nil,
      -- live facts (secrecy first-class)
      cd     = readCd(live, base),
      charge = readCharge(live, hasCharges),
      aura   = readAura(live, base, hasAura, selfAura),
      -- mostly-static, OOC-resolved off the BASE id (finding-3)
      keybind = (base and ns.HudBinds and ns.HudBinds.Get and ns.HudBinds.Get(base)) or nil,
    }
  end

  local events = {}
  if drain then
    for i = 1, #pending do events[i] = pending[i] end
    wipe(pending)
  end

  return {
    at     = GetTime(),
    combat = InCombatLockdown() and true or false,
    cooldowns = cooldowns,
    power  = readPower(),
    events = events,
  }
end

--------------------------------------------------------------------------------
-- Eval gating — the simplest thing that matches today (architecture.md)
--------------------------------------------------------------------------------
-- A modest ~10 Hz poll behind a swappable trigger.  The format supports CHANGE
-- DETECTION at the seam so a no-change pulse is a near-noop and builds no strings
-- (the E1 hot-path concern): the poll computes a cheap NUMERIC signature (no table
-- or string allocation) and only does the full Build+record when something moved,
-- an interesting event is owed, or the periodic OOC sample is due.  The trigger
-- policy lives entirely here; nothing downstream cares what caused a pulse, so it
-- can later become event-driven + napkin-scheduled wakeups with no change upstream.
local POLL_PERIOD = 0.1        -- ~10 Hz, matching the live HUD's poll cadence
local OOC_SAMPLE  = 5.0        -- periodic out-of-combat sample, for baseline coverage

-- A cheap running hash of the salient facts, arithmetic only.  In combat the live
-- cd read short-circuits to nil (constant), so combat pulses ride the event flags;
-- out of combat cd/aura movement shows up here directly.
-- Returns (hash, auraOn): a cheap change signature plus the count of active auras
-- (so the poll can label a proc distinctly from a plain change).
local function signature()
  local h = InCombatLockdown() and 1 or 0
  local auraOn = 0
  for cooldownID in pairs(enumerate()) do
    local info = cooldownInfo(cooldownID)
    local base = info and readable(info.spellID) and info.spellID or nil
    local live = liveSpellID(info) or base
    local isReady, remaining = ns.ReadCooldown(live)
    local cdbit = (isReady == nil) and 0 or (isReady and 1 or 2)
    local rem = (type(remaining) == "number") and math.floor(remaining) or 0
    local aur = 0
    if info and (info.hasAura or info.selfAura) then
      local a = readAura(live, base, info.hasAura, info.selfAura)
      if a.readable and a.active then aur = 1; auraOn = auraOn + 1 end
    end
    local ov = readable(St.override[base]) and St.override[base] or 0
    -- Mix cooldownID + facts into the hash (mod keeps it a Lua number, not a string).
    h = (h * 131 + cooldownID + cdbit * 7 + rem * 13 + aur * 3 + ov) % 2147483647
  end
  -- Fold every readable power into the hash so a shard step is a 'change' — spec-
  -- agnostically, mixing whatever powers the character has (no opinion on which).
  for value in pairs(POWER_NAME) do
    local okV, val = pcall(UnitPower, "player", value)
    if okV and type(val) == "number" and not ns.IsSecret(val) then
      h = (h * 131 + value * 17 + val) % 2147483647
    end
  end
  return h, auraOn
end

local pollTicker
local lastSig = nil
local lastAuraOn = 0
local lastSample = 0

local function poll()
  if not St.on then return end
  local now = GetTime()
  local due = captureReason
  local sig, auraOn = signature()
  if not due then
    if sig ~= lastSig then
      -- an aura coming UP is a proc — a distinct, protected moment in the ring
      due = (auraOn > lastAuraOn) and "proc" or "change"
    elseif (now - lastSample) >= OOC_SAMPLE and not InCombatLockdown() then
      due = "sample"
    end
  end
  lastSig, lastAuraOn = sig, auraOn   -- resync so an owed event isn't re-detected
  if due then
    captureReason = nil
    lastSample = now
    St.Capture(due)
  end
end

--------------------------------------------------------------------------------
-- The statelog capture ring — the Phase-2 corpus, written to disk
--------------------------------------------------------------------------------
-- A BOUNDED ring of diverse moments (cap RING), stored in a NEW CDMProbeDB.statelog
-- store — separate from `.probe` / `.pulls`.  Reuses ALL the existing capture
-- infrastructure: the CDMProbeDB SavedVariables file, the /reload-flush discipline,
-- and the ns.Stash secret-never-reaches-disk guard (every field in a pulse already
-- passed through the readable/Stash gates in Build, so nothing here can be a secret).
--
-- The collect/assert split (docs/m4.5-t3-plan.md): this COLLECTS (addon change +
-- release); the wowkb.cdmp statelog baseline ASSERTS (local, no release).
local RING = 40

local function store()
  if not ns.db then return nil end
  ns.db.statelog = ns.db.statelog or {}
  local sl = ns.db.statelog
  sl.pulses = sl.pulses or {}
  sl.byReason = sl.byReason or {}
  sl.count = sl.count or 0
  return sl
end

function St.Capture(reason)
  local sl = store()
  if not sl then return end
  local pulse = St.Build(true)
  pulse.reason = reason or "manual"
  pulse.seq = sl.count + 1
  sl.count = sl.count + 1
  sl.byReason[pulse.reason] = (sl.byReason[pulse.reason] or 0) + 1
  local p = sl.pulses
  p[#p + 1] = pulse
  -- DIVERSITY-PRESERVING eviction: when full, drop the OLDEST pulse of the MOST
  -- common reason in the ring, not simply the oldest.  A pull streams dozens of
  -- shard-step 'change' captures; a plain FIFO lets them evict the rare moments the
  -- corpus needs (a proc, a transform, the OOC baseline — the v0.29.0 flip-flop).
  -- Trimming the most-over-represented reason keeps the ring diverse under spam.
  while #p > RING do
    local counts = {}
    for i = 1, #p do counts[p[i].reason] = (counts[p[i].reason] or 0) + 1 end
    local top, topN = nil, -1
    for r, n in pairs(counts) do if n > topN then top, topN = r, n end end
    for i = 1, #p do
      if p[i].reason == top then table.remove(p, i); break end
    end
  end
end

local function clearStatelog()
  if not ns.db then return end
  ns.db.statelog = { pulses = {}, byReason = {}, count = 0,
                     startedAt = date("%Y-%m-%d %H:%M:%S"), version = ns.version }
  wipe(pending)
  captureReason = nil
  lastSig = nil
  lastSample = 0
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------
St.on = false

function St.Start()
  if St.on then return end
  St.on = true
  wipe(St.override)
  -- State CONSULTS the napkin and keybind cache as inputs, so it owns making them
  -- live for a capture session — otherwise, with the HUD off, both are dormant and
  -- every cd reads source="none" while every keybind is nil (the v0.29.0 gap: the
  -- napkin's SUCCEEDED frame and the bar scan are only started by the HUD).  Both
  -- Start()s are idempotent, so this is harmless when the HUD is also running.
  if ns.HudNapkin and ns.HudNapkin.Start then pcall(ns.HudNapkin.Start) end
  if ns.HudBinds and ns.HudBinds.Start then pcall(ns.HudBinds.Start) end
  eframe:RegisterEvent("COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED")
  eframe:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
  eframe:RegisterEvent("PLAYER_REGEN_DISABLED")
  eframe:RegisterEvent("PLAYER_REGEN_ENABLED")
  if not pollTicker then pollTicker = C_Timer.NewTicker(POLL_PERIOD, poll) end
  -- Seed the ring with an immediate first pulse so a session that is captured OOC
  -- and then /reload'd has at least one recorded moment even if nothing changed.
  St.Capture("start")
end

function St.Stop()
  St.on = false
  eframe:UnregisterAllEvents()
  if pollTicker then pollTicker:Cancel(); pollTicker = nil end
end

--------------------------------------------------------------------------------
-- `/cdmp statelog` — capture, coverage, reset  (mirrors `/cdmp probe`)
--------------------------------------------------------------------------------
-- COLLECT-side command (needs a release).  `statelog` toggles the capture session
-- and prints status; `statelog guide` reports what coverage the ring still lacks
-- (the same in-game-timing payoff as `probe guide`); `statelog clear` resets for a
-- fresh session.  The reader/baseline half is local (wowkb.cdmp statelog), no release.
local function statusLine()
  local sl = ns.db and ns.db.statelog
  local n = (sl and sl.pulses and #sl.pulses) or 0
  local total = (sl and sl.count) or 0
  ns.Printf("statelog: %s — %d pulse(s) in the ring, %d captured this session",
    St.on and "|cff88ff88recording|r" or "|cff808080idle|r", n, total)
  if sl and sl.byReason and next(sl.byReason) then
    local parts = {}
    for reason, c in pairs(sl.byReason) do parts[#parts + 1] = string.format("%s=%d", reason, c) end
    table.sort(parts)
    ns.Printf("  by trigger: %s", table.concat(parts, "  "))
  end
end

-- Coverage the ring still needs, computed OVER THE CAPTURED PULSES — a pull-based
-- checklist mirroring `probe guide`.  Detects and nudges; it cannot create state.
local function guide()
  local sl = ns.db and ns.db.statelog
  local pulses = (sl and sl.pulses) or {}
  local seenOOC, seenCombat, seenSecret, seenNapkin, seenTransform, seenProc = false, false, false, false, false, false
  local shardValues = {}
  for _, p in ipairs(pulses) do
    if p.combat then seenCombat = true else seenOOC = true end
    for _, c in pairs(p.cooldowns or {}) do
      if c.cd and c.cd.readable == false then seenSecret = true end
      if c.cd and c.cd.source == "napkin" then seenNapkin = true end
      if c.aura and c.aura.active then seenProc = true end
    end
    for _, e in ipairs(p.events or {}) do
      if e.kind == "transform" then seenTransform = true end
    end
    local ss = p.power and p.power.SoulShards
    if ss and type(ss.value) == "number" then shardValues[ss.value] = true end
  end
  local nShards = 0
  for _ in pairs(shardValues) do nShards = nShards + 1 end

  ns.Heading("statelog coverage — what the corpus still needs")
  local goals = {
    { seenOOC,       "an out-of-combat pulse",        "stand at a dummy OOC and wait a few seconds" },
    { seenCombat,    "an in-combat pulse",            "pull a dummy" },
    { seenSecret,    "a secret/unreadable cd fired",  "pull — live cd reads go secret in combat" },
    { seenNapkin,    "a napkin-sourced cd",           "cast a cooldown in combat, then it anticipates" },
    { nShards >= 2,  "a shard spread (2+ values)",    "spend and generate shards in a pull" },
    { seenTransform, "a transform observed",          "arm a Demonic Art / let a Grimoire hit CD" },
    { seenProc,      "a proc/aura observed",          "proc a Demonic Core (or any tracked buff)" },
  }
  local left = 0
  for _, g in ipairs(goals) do
    if g[1] then
      ns.Printf("  |cff88ff88[x]|r %s", g[2])
    else
      left = left + 1
      ns.Printf("  |cff808080[ ]|r %s   |cffffd100<- %s|r", g[2], g[3])
    end
  end
  if left == 0 then
    ns.Print("  |cff88ff88coverage complete|r — |cffffffff/reload|r, then |cffffffffuv run python -m wowkb.cdmp check|r")
  else
    ns.Printf("  -> |cffffd100%d goal%s left|r; keep playing and re-run |cffffffff/cdmp statelog guide|r, then |cffffffff/reload|r",
      left, left == 1 and "" or "s")
  end
end

ns.RegisterCommand("statelog",
  "record reduced-State pulses to disk for the W4 pipeline corpus. `statelog guide` = coverage still missing; `statelog clear` = reset for a new session",
  function(rest)
    rest = (rest or ""):lower()
    if rest:find("guide") then return guide() end
    if rest:find("clear") or rest:find("reset") then
      clearStatelog()
      return ns.Print("statelog ring + counters cleared for a fresh session.")
    end
    if rest:find("stop") or rest:find("off") then
      St.Stop()
      return statusLine()
    end
    if not St.on then
      if not (ns.db and ns.db.statelog and ns.db.statelog.startedAt) then clearStatelog() end
      St.Start()
    else
      St.Capture("manual")
    end
    statusLine()
    ns.Print("|cffffd100play, then /reload|r — SavedVariables only flush on reload/logout. `/cdmp statelog guide` shows what coverage is still missing.")
  end)

-- Passive: State is available from load, but the poll/ring only run once `statelog`
-- is invoked (parallel OBSERVATION on demand — the live HUD is untouched either way).
local prevOnLogin = ns.OnLogin
function ns.OnLogin()
  if prevOnLogin then prevOnLogin() end
  buildCategoryNames()
  buildPowerNames()
end
