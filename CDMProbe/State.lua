-- State.lua — the REDUCED CLIENT PICTURE (W4 pipeline Stage 1).
--
-- The one stage that touches the game API, distilled to a spec-agnostic table
-- everything above the pipeline consumes: State -> Coach -> Guidance -> Binder ->
-- DrawList -> Renderer (docs/architecture.md).  This file builds ONLY Stage 1.  It
-- decides no cue, knows no rotation, imports no SpecDemonology — that is invariant
-- #3 (State names no spell and no role; the rotational meaning stays Coach-only).
-- (It DOES consult a couple of injected `ns.Spec*` READERS — the napkin's base
-- cooldowns, and `ns.SpecPowerDelta` for the signed per-power incoming projection — exactly as the
-- architecture sanctions "a game-fact input like base cooldowns": State's code names
-- no spell and no role; the rotational meaning stays Coach-only.)
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
--   3. IDENTITY RESOLUTION LIVES HERE, ONE COPY.  We carry the raw ids (spellID =
--      base, plus overrideSpellID / overrideTooltipSpellID) and resolve a single
--      `liveSpellID` the whole pipeline reads, with its inverse `BaseOfCast` beside it.
--      Keybinds still resolve off the BASE; the two resolutions are deliberately NOT
--      unified (see the identity section below).
--   4. READINESS IS OBSERVED, NOT GUESSED.  The cd model is THREE
--      honest states — ready | on-cooldown | unknown — with `source` (live|napkin|
--      none) a trust annotation on `remaining`, not a second axis.  Readiness rests
--      on an OOC read, the OOC baseline carried across combat entry, or an OBSERVED
--      CDM alert edge (Available/OnCooldown) — never a bare estimate; the napkin
--      supplies only the *remaining* seconds while on cooldown.  The keybind is the
--      OOC-resolved base-id binding.
--
-- NOT IN THIS FILE: any consumer of State.  Build() emits a table; nothing here scores
-- it.  The live driver (HudDriver, /cdmp hud) Acquire()s ingestion and calls Build each
-- tick; the Coach above decides.
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
--   * `spellID` (base) is `info.spellID` untouched.  KEYBINDS RESOLVE OFF THE BASE —
--     the v0.7.0 rule stated in full at HudBinds.lua's header.  Unifying the two
--     resolutions reintroduces that bug.
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

-- OOC-readiness BASELINE (W4 Phase 7a), keyed by cooldownID.  On every readable
-- (OOC) cd read we stash the truth — ready plus the raw duration/startTime the
-- read already carries — so a never-cast/ready ability SURVIVES combat entry
-- instead of collapsing to `source:none` the instant the live read goes secret.
-- The combat path projects this forward when nothing more recent (an edge or a
-- napkin cast) is known.
local cdBaseline = {}    -- cooldownID -> { ready, duration, startTime, at }

-- OBSERVED ready-edge truth (W4 Phase 7b), keyed by cooldownID.  Filled by the
-- CDM alert hook (onAlert): an `Available` edge => ready-at-now, an `OnCooldown`
-- edge => on-cooldown-at-now.  These fire IN COMBAT off the item's own alert
-- choke point (not a secret-guarded API read), so readiness becomes OBSERVED,
-- not guessed.  readCd's combat path consults this as ground truth.
local readyEdge = {}     -- cooldownID -> { ready = bool, at }

-- OBSERVED AURA-LIFECYCLE truth (field-fix C), keyed by cooldownID — the second thing the
-- alert choke point tells us that the corresponding STATE read refuses.  A tracked target
-- DoT's pandemic fields (`pandemicStartTime`/`EndTime`) read SECRET in combat and
-- `IsInPandemicTime` THROWS (measured 2026-07-30, knowledge/addon-dev/
-- api-events-and-discovery.md §2.8) — but the `PandemicTime` ALERT fires normally.  So the
-- refresh window is an EDGE LATCH over three observed transitions, never a poll:
--   PandemicTime  -> "pandemic"  the aura entered its refresh window
--   OnAuraApplied -> "fresh"     a NEW application landed (not a stack — §2.8)
--   OnAuraRemoved -> "absent"    it fell off
-- Structural, not rotational: State records the transition for whichever cooldownID raised
-- it and names no spell.  Build resolves the cid to its base spellID (`dotEdges`), so the
-- Coach — which decides in base spellIDs — never sees a cooldownID.  Named for the DoT case
-- because `PandemicTime` can only ever fire for a target DoT; `OnAura*` also fires for
-- self-buff entries, whose latch simply has no consumer.
St.dotEdge = {}          -- cooldownID -> { state = "pandemic"|"fresh"|"absent", at }

--------------------------------------------------------------------------------
-- The CHARGE NAPKIN (field-fix C2) — an estimate over an EXACT seed, never a poll
--------------------------------------------------------------------------------
-- `ns.ReadCharges` is combat-gated by design (C_Spell.GetSpellCharges reads secret in
-- restricted combat), so a charged ability's count vanishes exactly when it matters.  The
-- alert channel closes the gap: `ChargeGained` fires IN COMBAT on any upward move of
-- Blizzard's cached count (observed x10 across ~80s on Conflagrate, i.e. natural recharge
-- AND cooldown-reset procs both land here — §2.8).  So:
--     seed  exact from the OOC read      (the measurement)
--     -1    on UNIT_SPELLCAST_SUCCEEDED  (we pressed it)
--     +1    on the ChargeGained alert    (observed, not guessed)
--     clamp [0, max]; an exact OOC re-read always overwrites the estimate.
-- THE HONESTY RULE, mirroring HudNapkin: an OVERCOUNT claims a charge you do not have (it
-- cues a press that will fail); an UNDERCOUNT only under-presses.  So every unresolvable
-- case biases DOWN, and the estimate is surfaced with `source = "napkin"` so the brain can
-- tell an estimate from a measurement.
local chargeEst = {}     -- cooldownID -> { cur, max }
local chargeCid = {}     -- base spellID -> the cooldownID of its CHARGED row (spend needs it)

local function chargeSeed(cooldownID, cur, max)
  if not (cooldownID and type(cur) == "number") then return end
  chargeEst[cooldownID] = { cur = cur, max = (type(max) == "number") and max or nil }
end

local function chargeRead(cooldownID)
  local e = cooldownID and chargeEst[cooldownID]
  if not e then return nil end
  return e.cur, e.max
end

-- A cast landed: spend one.  Floors at 0 — never negative, and never "we must have had
-- more than we counted".
local function chargeSpend(base)
  local cid = base and chargeCid[base]
  local e = cid and chargeEst[cid]
  if not e then return end
  e.cur = math.max(0, e.cur - 1)
end

-- An observed ChargeGained edge: credit one, clamped to max when we know it.  An unknown
-- max cannot clamp, so it is left uncapped rather than clamped against a guessed cap —
-- the edge itself is an observation, so crediting it is not speculation.
local function chargeGain(cooldownID)
  local e = cooldownID and chargeEst[cooldownID]
  if not e then return end
  local n = e.cur + 1
  if e.max then n = math.min(e.max, n) end
  e.cur = n
end

-- Test seam (the C2 spec drives the whole loop off synthetic pulses).
St.Charges = { Seed = chargeSeed, Read = chargeRead, Spend = chargeSpend, Gain = chargeGain,
               Bind = function(base, cid) if base and cid then chargeCid[base] = cid end end,
               Reset = function() wipe(chargeEst); wipe(chargeCid) end }

-- FOLD cache (W4 domain-view re-layer), keyed by cooldownID.  base-spellID -> cooldownID
-- is N:1 (a summon is one Essential row + one TrackedBar/TrackedBuff row), and Build's
-- domain view must group the N CDM rows of one ability under its base spellID.  In combat
-- a row's `spellID` can read secret, so this remembers each cooldownID's base from the
-- OOC-readable path (where base is guaranteed readable) as the fallback fold key; the
-- per-pulse readable base is primary.  Lives with cdBaseline/readyEdge, written on the
-- same OOC-readable rhythm in readCd.
local foldBase = {}      -- cooldownID -> base spellID

-- The napkin's anticipation for a cd, queried under the live identity first, the
-- base second (a transformed button's cast filed the napkin under whichever id
-- fired SUCCEEDED).  Returns the estimated remaining (may be <= 0 when elapsed),
-- or nil when the napkin has no record.  The napkin supplies only the *remaining*
-- number now — readiness itself comes from the read/baseline/edge.
local function napkinRemaining(live, base)
  local N = ns.HudNapkin
  if not (N and N.Remaining) then return nil end
  local rem = N.Remaining(live)
  if rem == nil and base and base ~= live then rem = N.Remaining(base) end
  return rem
end

-- cd{state, remaining, readable, source} — the THREE honest states (W4 Phase 7).
--   state ∈ ready | on-cooldown | unknown
--   source ∈ live | napkin | none      (a TRUST annotation on `remaining`, not a
--                                        second state axis)
-- Readiness is OBSERVED: an OOC live read, or an in-combat `Available`/`OnCooldown`
-- alert edge, or the OOC baseline projected forward with no cast since.  The napkin
-- supplies only the *remaining* estimate while on cooldown.  `readable` mirrors
-- `source == "live"` — true when the number is a read/observation, false when it is
-- an estimate or absent.
local function readCd(live, base, cooldownID)
  local isReady, remaining, duration, startTime = ns.ReadCooldown(live)
  if isReady ~= nil then
    -- Readable (OOC): the precise truth, AND the baseline stash that outlives combat.
    -- Remember this cd's base id too — the fold key the domain view falls back to when a
    -- combat pulse reads the row's spellID secret (base is usually still readable, but this
    -- guarantees it).  Written on the same OOC-readable rhythm as cdBaseline.
    if cooldownID and readable(base) then foldBase[cooldownID] = base end
    if cooldownID then
      if readable(duration) and readable(startTime) then
        cdBaseline[cooldownID] = { ready = isReady and true or false,
          duration = duration, startTime = startTime, at = GetTime() }
      else
        cdBaseline[cooldownID] = { ready = isReady and true or false, at = GetTime() }
      end
    end
    if isReady then
      return { state = "ready", remaining = 0, readable = true, source = "live" }
    end
    return { state = "on-cooldown", remaining = ns.Stash(remaining),
             readable = true, source = "live" }
  end

  -- Not readable live (combat/secret).  Determine readiness WITHOUT guessing.
  local now = GetTime()
  local rem = napkinRemaining(live, base)

  -- A live napkin countdown means a cast filed this recently -> ON COOLDOWN NOW,
  -- which OUTRANKS a stale `Available` edge (the just-cast race the doc names).
  if rem and rem > 0 then
    return { state = "on-cooldown", remaining = ns.Stash(rem), readable = false, source = "napkin" }
  end

  -- Observed alert edge = ground truth for readiness (Phase 7b).
  local edge = cooldownID and readyEdge[cooldownID] or nil
  if edge then
    if edge.ready then
      return { state = "ready", remaining = 0, readable = true, source = "live" }
    end
    -- Observed on cooldown; no live estimate (or it has run out).  "napkin says
    -- zero, unconfirmed" — probably-up, but not a laundered `ready`.
    return { state = "on-cooldown", remaining = 0, readable = false, source = "napkin" }
  end

  -- No edge — the napkin's own estimate, if it had a record (rem <= 0 here means
  -- the estimate has run out: on cooldown, remaining 0, unconfirmed).
  if rem ~= nil then
    return { state = "on-cooldown", remaining = 0, readable = false, source = "napkin" }
  end

  -- No edge, no napkin — project the OOC baseline forward across combat entry (7a).
  local b = cooldownID and cdBaseline[cooldownID] or nil
  if b then
    if b.ready then
      -- The OOC read said ready and nothing has cast since (no napkin record) ->
      -- still ready.  This is the never-cast-summon fix.
      return { state = "ready", remaining = 0, readable = true, source = "live" }
    end
    if readable(b.duration) and readable(b.startTime) then
      local rem2 = b.startTime + b.duration - now
      if rem2 > 0 then
        return { state = "on-cooldown", remaining = ns.Stash(rem2), readable = false, source = "napkin" }
      end
    end
    -- Baseline was cooling but has since elapsed (or carried no timing) -> on
    -- cooldown, estimate exhausted, unconfirmed.
    return { state = "on-cooldown", remaining = 0, readable = false, source = "napkin" }
  end

  -- No baseline AND never observed -> genuine no-data.
  return { state = "unknown", readable = false, source = "none" }
end

-- charge{cur, max, readable, source}.  A banked charge means PRESSABLE whatever the
-- recharge timer says — the Coach's call to make; State just reports the pair honestly.
--
-- `source` is the same TRUST annotation the cd model carries: "live" = an exact read (OOC),
-- "napkin" = the C2 edge-latched estimate (in combat, where the read is secret).  `readable`
-- keeps mirroring `source == "live"`, so a consumer that only trusts measurements is
-- unaffected by C2 and one that wants the estimate opts in by reading `cur`.
-- ⚠ THE READ IS NOT GATED ON `hasCharges` (fixed after the 2026-07-30 live pass).  It was,
-- and that made the whole napkin dependent on one CDM struct flag being right — a single
-- point of silent failure with no symptom, since a never-seeded napkin looks exactly like an
-- ability with no charges.  `ns.ReadCharges` already short-circuits on InCombatLockdown, so
-- the extra attempt costs nothing in combat and one guarded call per row out of it.
-- `charged` is the honest, MEASURED answer to "does this thing have a charge pool" — a live
-- max > 1 — and it is what the brain keys on, rather than the flag.
local function readCharge(live, hasCharges, cooldownID)
  local cur, max = ns.ReadCharges(live)
  if cur ~= nil then
    if type(max) == "number" and max > 1 then
      -- The exact read ALWAYS wins, and re-seeds the napkin (the combat-exit correction).
      chargeSeed(cooldownID, cur, max)
      return { readable = true, cur = ns.Stash(cur), max = ns.Stash(max),
               source = "live", charged = true }
    end
    return { readable = true, cur = nil, max = 0 }   -- read fine; no charge pool to report
  end
  local ecur, emax = chargeRead(cooldownID)
  if ecur ~= nil then
    return { readable = false, cur = ecur, max = emax, source = "napkin", charged = true }
  end
  if not hasCharges then return { readable = true, cur = nil, max = 0 } end
  return { readable = false }
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
--
-- FULL ACTIVE-BUFF SCAN — the spec-agnostic source of truth for "what is on the player
-- right now" (v0.29.4).  `GetPlayerAuraBySpellID(id)` only finds the aura if `id` is
-- the buff's OWN aura spellID — and a CDM entry's `spellID` is not always that id
-- (Wild Imp's matched; Demonic Core's may not).  So we ALSO enumerate every player
-- buff and report the list (`activeAuras`), and mark an entry active when any of its
-- associated ids is in that set.  The raw list is first-class: the spec-agnostic State
-- reports which buffs are up; the Coach (spec-aware) decides which ones MEAN something.
-- Secret-guarded per aura: in restricted combat a packed auraData can be a secret
-- table, so an unreadable aura is COUNTED (`secret`), never indexed.
local function scanActiveAuras()
  local list, byID, secret = {}, {}, 0
  if not (AuraUtil and AuraUtil.ForEachAura) then return list, byID, secret end
  local cb = function(aura)
    local sid, name
    local ok = pcall(function()
      if type(aura) == "table" and not ns.IsSecretTable(aura) then
        sid, name = aura.spellId, aura.name
      end
    end)
    if ok and readable(sid) then
      if not byID[sid] then
        byID[sid] = true
        list[#list + 1] = { spellID = sid, name = (type(name) == "string") and name or nil }
      end
    else
      secret = secret + 1
    end
    -- return nothing -> keep iterating every aura
  end
  pcall(AuraUtil.ForEachAura, "player", "HELPFUL", nil, cb, true)
  return list, byID, secret
end

-- aura{active, readable}.  `activeByID` is the full-scan set; `ids` are the entry's
-- associated spellIDs (live, base, linked); `aurasSecret` is how many auras this pulse
-- read secret.  Active if ANY associated id is in the scan set or a direct by-id read
-- finds it.
--
-- ⚠ COMBAT AURAS ARE SECRET (measured v0.29.4).  A State capture proved it:
-- out of combat the scan read 8 buffs / 0 secret; IN COMBAT only 1 passive was
-- readable and 6–16 auras per pulse came back as secret tables, with
-- GetPlayerAuraBySpellID returning nil for the hidden ones.  So when the aura space is
-- partially secret we CANNOT honestly say a buff is absent — an unconfirmed entry is
-- `readable:false`, NOT a false `active:false` (secrecy first-class).  The
-- combat-readable proc signal lives on the `glow` fact below, not here.
local function readAura(hasAura, selfAura, activeByID, ids, aurasSecret)
  if not (hasAura or selfAura) then return { readable = true, active = false } end
  for _, id in ipairs(ids) do
    if readable(id) and activeByID[id] then return { readable = true, active = true } end
  end
  if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
    for _, id in ipairs(ids) do
      if readable(id) then
        local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, id)
        if not ok then return { readable = false } end
        if type(aura) == "table" then return { readable = true, active = true } end
      end
    end
  end
  -- Not positively confirmed.  If auras are being hidden this pulse, absence is
  -- unknowable -> readable:false.  Only a fully-readable aura space makes false honest.
  if aurasSecret and aurasSecret > 0 then return { readable = false } end
  return { readable = true, active = false }
end

-- glow{active, readable} — is this spell PROC-HIGHLIGHTED right now (the spell-
-- activation overlay the action bars flash)?  This is the CDM's OWN combat-readable
-- proc signal: RefreshOverlayGlow (CooldownViewer.lua:1124) calls exactly this
-- `IsSpellOverlayed` to decide the glow, and it reads in combat where C_UnitAuras goes
-- secret (fired 27x in a measured pull).  Spec-agnostic: State reports "spell X is
-- overlay-glowed"; the Coach knows a glow on Demonbolt means a Demonic Core proc.  The
-- glow lands on the EMPOWERED spell, which is the actionable one — better than the aura.
local function readGlow(spellID)
  if not readable(spellID) then return { readable = false } end
  if not (C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed) then
    return { readable = false }
  end
  local ok, on = pcall(C_SpellActivationOverlay.IsSpellOverlayed, spellID)
  if not ok or ns.IsSecret(on) then return { readable = false } end
  return { readable = true, active = on and true or false }
end

-- buff{...} — what the buff-tracking ITEM FRAME exposes that the DB struct does not
-- (v0.29.5, probing the user's "is buff-tracking another source?" question).
-- Demonic Core is a CooldownViewerBuffItemMixin; its `isActive` is a bool Blizzard's
-- TRUSTED code derives from the (secret) aura and stores on the frame — so it MAY be a
-- clean, readable-in-combat "is this buff up" signal even though the aura itself is
-- secret.  We MEASURE that here: read `IsActive()` and `IsShown()` guarded, and carry
-- `hideWhenInactive` (whether `shown` is even a signal — the ShouldBeShown caveat).
-- Duration/stacks are deliberately NOT read: they are auraData-derived and secret.
local function readBuffItem(item)
  if not item then return nil end
  local out = {}
  if ns.HasMethod(item, "IsActive") then
    local ok, v = pcall(item.IsActive, item)
    if ok and not ns.IsSecret(v) then
      out.isActive, out.isActiveReadable = (v and true or false), true
    else
      out.isActiveReadable = false
    end
  end
  if ns.HasMethod(item, "IsShown") then
    local ok, v = pcall(item.IsShown, item)
    if ok and not ns.IsSecret(v) then out.shown = v and true or false end
  end
  local ok, hwi = pcall(function() return item.hideWhenInactive end)
  if ok and type(hwi) == "boolean" then out.hideWhenInactive = hwi end
  return out
end

-- cooldownID -> live item frame, across all viewers.  Frame-anchored best-effort: the
-- buff-tracking items are where a proc's isActive/shown lives, and the DB struct never
-- carries it.  Rebuilt each Build so a repooled frame can't go stale.
local function itemFrameMap()
  local map = {}
  if not ns.VIEWERS then return map end
  for _, v in ipairs(ns.VIEWERS) do
    local viewer = ns.GetViewer(v.frame)
    if viewer then
      for _, item in ipairs(ns.GetItemFrames(viewer)) do
        local cid = readable(item.cooldownID) and item.cooldownID or nil
        if not cid and ns.HasMethod(item, "GetCooldownID") then
          local ok, id = pcall(item.GetCooldownID, item)
          if ok and readable(id) then cid = id end
        end
        if cid and not map[cid] then map[cid] = item end
      end
    end
  end
  return map
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
local PENDING_MAX = 64          -- bound the delta so a drain-LESS consumer can't leak

-- Append to the since-last-pulse delta.  Bounded: a Build(false) consumer (the live
-- driver) never drains `pending`, so without a cap it would grow without limit; the
-- ring is only ever the last PENDING_MAX events, which is far more than one pulse's
-- worth (a Build(true) drain empties it).
local function pushEvent(e)
  pending[#pending + 1] = e
  while #pending > PENDING_MAX do table.remove(pending, 1) end
end

--------------------------------------------------------------------------------
-- The CDM alert edges — in-combat readiness, OBSERVED not guessed (W4 Phase 7b)
--------------------------------------------------------------------------------
-- The Cooldown Manager fires `Enum.CooldownViewerAlertEventType.Available` (a
-- cooldown FINISHED) and `.OnCooldown` (WENT on cooldown) through each item's own
-- `TriggerAlertEvent`, and these fire IN COMBAT — off the item's alert choke point,
-- not a secret-guarded API read.  We hook that choke point per item and record the
-- observed edge in `readyEdge`, which readCd consults as ground truth.  CLEAN-ROOM:
-- State ports the HOOK PATTERN from the old HUD (S.Install/onAlert) but owns its own
-- edge store and reads none of the old engine's state — a clean Stage-1 separation.
-- Six alert types exist (Available=1, PandemicTime=2, OnCooldown=3, ChargeGained=4,
-- OnAuraApplied=5, OnAuraRemoved=6 — Blizzard_APIDocumentationGenerated/
-- CooldownViewerConstantsDocumentation.lua:43-55).
--
-- ⚠ ALL SIX ARE NOW CONSUMED (field-fixes C/C2, 2026-07-30).  The other four used to be
-- recorded only by the temporary AlertTape instrument, because "an unverified channel must
-- not silently start driving readiness".  That verification HAPPENED: a live capture
-- confirmed five of the six firing in combat and pinned what each one means
-- (knowledge/addon-dev/api-events-and-discovery.md §2.8, CONFIRMED IN-CLIENT), so they are
-- promoted here on measurement, not on hope.  The rule stands for anything ELSE: measure
-- first, then consume.
local function onAlert(item, event)
  local A = Enum and Enum.CooldownViewerAlertEventType
  if not A then return end
  -- A Secret Value must never be compared; if the event arg is ever restricted we
  -- drop it rather than taint on the ==.
  if ns.IsSecret(event) then return end
  -- Resolve the item's cooldownID, guarded (an unreadable id is dropped, not keyed).
  -- Hoisted ABOVE the event filter so the tape can key its rows by cooldownID too.
  local cid = readable(item.cooldownID) and item.cooldownID or nil
  if not cid and ns.HasMethod(item, "GetCooldownID") then
    local ok, id = pcall(item.GetCooldownID, item)
    if ok and readable(id) then cid = id end
  end
  if not cid then return end

  -- THE TAPE — every alert type, before any filtering, and NOT gated on St.consumers, so
  -- the two known-good edges act as its control group.  A no-op (one boolean test) unless
  -- `/cdmp alerts on`.  pcall'd: a discovery instrument must never break the pipeline.
  -- ⚠ One of only TWO legitimate guards on an `ns.` symbol in the addon (the other is
  -- ns.SpecInfo in Viewers.lua's DisplayIdentity).  AlertTape is a TEMPORARY instrument
  -- scheduled for deletion, i.e. a genuinely OPTIONAL collaborator — the case the no-guards
  -- rule carves out.  Every other module we ship is called DIRECTLY, so a missing
  -- definition throws.
  if ns.AlertTape then pcall(ns.AlertTape.Record, item, event, cid) end

  -- THE PIPELINE.
  if St.consumers <= 0 then return end   -- nobody is ingesting: drop it
  local now = GetTime()

  -- READINESS (Phase 7b) — the two settled cooldown edges.
  if event == A.Available or event == A.OnCooldown then
    local ready = (event == A.Available)
    readyEdge[cid] = { ready = ready, at = now }
    pushEvent({ kind = "ready_edge", cooldownID = cid, ready = ready, at = now })
    return
  end

  -- AURA LIFECYCLE (field-fix C) — the pandemic latch and its two clears.  Last edge wins
  -- per cooldownID; Build resolves the cid to a base spellID for the Coach.
  local st
  if event == A.PandemicTime then st = "pandemic"
  elseif event == A.OnAuraApplied then st = "fresh"
  elseif event == A.OnAuraRemoved then st = "absent" end
  if st then
    -- ⚠ SAME-FRAME TIE, measured 2026-07-30.  A DoT REFRESH fires OnAuraRemoved AND
    -- OnAuraApplied with the IDENTICAL timestamp (capture: cid 133441 + 164597, both events
    -- at 131184.611), so a bare last-write-wins latch is decided by Blizzard's dispatch
    -- ORDER rather than by what happened.  It landed the right way round in that capture,
    -- which is exactly why it is worth pinning: a re-application SUPERSEDES the removal it
    -- replaces, so "absent" must never overwrite a "fresh" recorded at the same instant.
    local prev = St.dotEdge[cid]
    local sameFrameRefresh = prev and prev.at == now
      and st == "absent" and prev.state == "fresh"
    if not sameFrameRefresh then
      St.dotEdge[cid] = { state = st, at = now }
    end
    pushEvent({ kind = "dot_edge", cooldownID = cid, state = st, at = now })
    return
  end

  -- CHARGES (field-fix C2) — the only in-combat charge information there is.
  if event == A.ChargeGained then
    chargeGain(cid)
    pushEvent({ kind = "charge_gained", cooldownID = cid, at = now })
  end
end

St.OnAlert = onAlert     -- test seam: hooksecurefunc is a no-op off-game, so the specs
                         -- drive the latch through the same function the hook calls.

-- One hook per item INSTANCE (the methods are Mixin()-copied, so a hook on the
-- shared mixin table would miss every already-created frame).  hooksecurefunc can
-- never be undone, so the callback is gated on St.consumers inside onAlert.
local function installAlertHook(item)
  if not item or item.__stateAlertHooked then return end
  if not ns.HasMethod(item, "TriggerAlertEvent") then return end
  item.__stateAlertHooked = true
  hooksecurefunc(item, "TriggerAlertEvent", function(self, event)
    pcall(onAlert, self, event)
  end)
end

-- Hook every CDM item across all viewers.  Idempotent (per-instance flag) and
-- cheap enough to run each Build, so re-pooled/newly-created frames are covered
-- without a dedicated layout event.
local function installAlertHooks()
  if not ns.VIEWERS then return end
  for _, v in ipairs(ns.VIEWERS) do
    local viewer = ns.GetViewer(v.frame)
    if viewer then
      for _, item in ipairs(ns.GetItemFrames(viewer)) do
        installAlertHook(item)
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Cast history — a bounded, timestamped window of recent casts (sequence memory)
--------------------------------------------------------------------------------
-- A single State pulse is a snapshot; to know we're PARTWAY THROUGH A SEQUENCE the
-- Coach needs recent cast order.  Keeping that here (spec-agnostic: "the player cast
-- these spells at these times") lets the Coach compute the sequence cursor as a PURE
-- FUNCTION of State — which is what makes the Phase-2 golden tests fixturable (perturb
-- a pulse's history, assert the Guidance.sequence).  Same observation the napkin
-- already ingests, ordered by time instead of keyed by spell.
--
-- We record BOTH phases:
--   * "start"     (UNIT_SPELLCAST_START)     — a cast has COMMITTED / is in flight.
--     Cast-time spells only (instants fire SUCCEEDED alone).  Lets the Coach hint the
--     NEXT step and animate the current one BEFORE it lands.
--   * "succeeded" (UNIT_SPELLCAST_SUCCEEDED) — the cast LANDED; advance the sequence.
-- Bounded by count on push and by age at Build, long enough to cover an opener.
local HISTORY_MAX    = 32       -- hard cap on retained cast entries
local HISTORY_WINDOW = 20.0     -- seconds of history a pulse carries (>= longest sequence)
local INFLIGHT_WINDOW = 3.0     -- a cast still plausibly IN FLIGHT this recently (~2 GCDs)
local history = {}

local function pushCast(phase, spellID)
  if not readable(spellID) then return end
  history[#history + 1] = { phase = phase, spellID = spellID,
                            base = ns.Stash(St.BaseOfCast(spellID)), at = GetTime() }
  while #history > HISTORY_MAX do table.remove(history, 1) end
end

-- The live Soul Shard value as a plain number, or nil if unreadable/no Enum (P6 P2).
-- Used both for the spender START snapshot and inflightIncoming's double-deduction guard.
local function currentShardValue()
  local pt = Enum and Enum.PowerType and Enum.PowerType.SoulShards
  if pt == nil then return nil end
  local ok, val = pcall(UnitPower, "player", pt)
  if ok and not ns.IsSecret(val) and type(val) == "number" then return val end
  return nil
end

-- Shard bar value snapshotted at the START of an in-flight SPENDER, keyed by base
-- spellID (P6 Part 2, the double-deduction guard).  A spend (Hand of Gul'dan) consumes
-- its shards on COMPLETION, so its negative projection must apply only while the shards
-- are still in hand; inflightIncoming drops the −delta once the live value falls below
-- this snapshot (the deduction has landed).  The old HUD used the same atStart pattern.
local spendStartShards = {}     -- base spellID -> shard value at its UNIT_SPELLCAST_START

St.combatStartedAt = nil        -- GetTime() when combat last began; nil = never seen

-- Per-cooldown last-transition stamp (NOT a history — the Coach only ever needs "when
-- did this last change", e.g. how long it has sat ready for a LATE cue).  We remember
-- the previous observed cd.state per cooldownID and stamp `cd.changedAt` when it flips.
-- ⚠ Honest caveat: this is when STATE'S VIEW changed, ~poll-granular.  Since Phase 7
-- the model no longer collapses ready->unknown on combat entry (the OOC baseline +
-- the observed alert edges keep readiness honest in combat), so a spurious flip on
-- the combat seam is far rarer; the Coach still reads `cd.source` + `combatStartedAt`
-- to discount any residual poll-granular jitter.
local cdPrevState = {}
local cdChangedAt = {}

-- Stamp `cd.changedAt` = when this cooldown's observed state last flipped.  First
-- observation stamps `now` ("seen in this state since"), which the Coach treats as a
-- floor, not a proven transition (cold-start, like the live HUD's candidateSince).
local function stampCd(cooldownID, cd, now)
  if cdPrevState[cooldownID] ~= cd.state then
    cdPrevState[cooldownID] = cd.state
    cdChangedAt[cooldownID] = now
  end
  cd.changedAt = cdChangedAt[cooldownID]
  return cd
end

-- VIRTUAL-ROW KNOWNNESS, cached (a spellbook read per candidate per 10 Hz tick would be
-- wasteful) and pcall-guarded where it is read: `C_SpellBook.IsSpellKnown` is
-- `SecretArguments = "AllowedWhenUntainted"` (SpellBookDocumentation.lua:684), so it CAN
-- refuse — and a refusal yields no virtual row, the under-show direction.  Knownness is
-- respec-scoped, so the SPELLS_CHANGED handler below wipes it; that handler is why the
-- declaration lives up HERE rather than beside the walk that reads it (further down, under
-- "VIRTUAL ROWS").  It was originally declared next to the walk, and luacheck caught it:
-- the wipe was resolving to an undefined GLOBAL, so the cache would never have invalidated
-- and `wipe(nil)` would have thrown inside an event handler.
local knownCache = {}

-- THE ACTIVE HERO TALENT TREE, cached, on the same discipline as knownCache above.
--
-- This is a CLIENT READ, so it belongs in Stage 1 and nowhere else — architecture.md's
-- "State is the only stage that touches the game API".  It used to live inside the
-- Destruction brain's Context, which meant `C_ClassTalents.GetActiveHeroTalentSpec()` ran
-- from a function the Coach calls at 10 Hz, and — worse — the hero tree DECIDED which
-- rotation lines fire without ever appearing on the pulse.  A captured pulse therefore
-- could not reproduce a Hellcaller decision, which is the entire payoff of the seam.
--
-- Cached because it is respec-scoped, wiped by the SAME `SPELLS_CHANGED` branch as
-- knownCache: that event covers talent swaps, spec changes and hero-tree swaps alike.
-- pcall + IsSecret guarded: an API that is missing, restricted, or throws must yield nil
-- ("we don't know"), never take the pipeline down and never a poisoned number.  A nil here
-- is honest — the Coach has a documented inference fallback for exactly this case.
local heroCache = { asked = false, id = nil, name = nil }

-- SubTreeID -> our generic hero name.  TraitSubTree @ 12.0.7.  State names no rotation,
-- but it does carry the game's own vocabulary through, exactly as it does for `mode` and
-- `powerType` — the ROTATIONAL meaning of "hellcaller" stays Coach-only.
local HERO_BY_SUBTREE = {
  [58] = "hellcaller",   -- Warlock
  [59] = "diabolist",    -- Warlock
}

local function readHero()
  if heroCache.asked then return heroCache.name, heroCache.id end
  heroCache.asked = true
  if not (C_ClassTalents and C_ClassTalents.GetActiveHeroTalentSpec) then return nil, nil end
  local ok, subTreeID = pcall(C_ClassTalents.GetActiveHeroTalentSpec)
  if not ok or ns.IsSecret(subTreeID) or type(subTreeID) ~= "number" then return nil, nil end
  -- The raw id is carried even when we have no NAME for it, so a captured pulse from a
  -- class we have not mapped is still self-describing rather than silently blank.
  heroCache.id   = subTreeID
  heroCache.name = HERO_BY_SUBTREE[subTreeID]
  return heroCache.name, heroCache.id
end

St.ReadHero = readHero          -- test seam (the resolution path)

local eframe = CreateFrame("Frame")
eframe:SetScript("OnEvent", function(_, event, a1, a2, a3)
  if event == "COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED" then
    -- (baseSpellID, overrideSpellID).  Record the transform and update the one
    -- override map identity reads from.
    --
    -- ⚠ IDEMPOTENCY (v0.29.3).  The client fires this event REDUNDANTLY — several
    -- times per logical transform, each carrying the same (base, override) pair, as
    -- the pet summon / aura / linked-spell / cooldown updates each poke the override
    -- table.  Blizzard's own code expects this: CooldownViewerItemData.lua:91
    -- SetOverrideSpell early-returns when overrideSpellID is unchanged, and
    -- CooldownViewer.lua:173 defers its refresh "until a unique event is received".
    -- We mirror that guard: only record a transform when the value ACTUALLY changes,
    -- so the delta is the real transition, not 1 real + N no-op re-fires.
    if readable(a1) then
      local from = St.override[a1]
      local to = readable(a2) and a2 or nil
      if to ~= from then
        St.override[a1] = to
        pushEvent({ kind = "transform", base = a1, from = ns.Stash(from),
                    to = ns.Stash(to), at = GetTime() })
      end
    end
  elseif event == "UNIT_SPELLCAST_START" then
    -- (unit, castGUID, spellID) — the cast is IN FLIGHT.  Cast-time spells only; the
    -- Coach can start hinting the next step before this one lands.
    if readable(a3) then
      pushCast("start", a3)
      -- Snapshot shards at a SPENDER's start (signed delta < 0) so inflightIncoming can
      -- guard the completion-frame double-deduction (P6 Part 2).  Spec-agnostic: State
      -- reads the injected signed delta (Phase 3: a { power, delta } record), names no
      -- spell.  ⚠ multi-power guard: Phase-when-needed — currentShardValue() is the
      -- SoulShards live value, correct because Demo has one spender-power; a second spec
      -- with a spender on a different power would want that power's live value here.
      local base = St.BaseOfCast(a3)
      if ns.SpecPowerDelta and type(base) == "number" then
        local r = ns.SpecPowerDelta(base)
        if type(r) == "table" and type(r.delta) == "number" and r.delta < 0 then
          spendStartShards[base] = currentShardValue()
        end
      end
      pushEvent({ kind = "cast_started", spellID = a3,
                  base = ns.Stash(St.BaseOfCast(a3)), at = GetTime() })
    end
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    -- a3 is the spellID (unit, castGUID, spellID); RegisterUnitEvent filters to
    -- player.  Resolve back to the base entry so the Coach can tie it to a cooldown.
    if readable(a3) then
      pushCast("succeeded", a3)
      local base = St.BaseOfCast(a3)
      if type(base) == "number" then spendStartShards[base] = nil end
      -- The charge napkin's DEBIT half (C2): we pressed it, so one banked charge is gone.
      -- Keyed off the base id because that is what the cast resolves to; the charged row's
      -- cooldownID is bound during Build.  Floors at 0 — the undercount direction.
      chargeSpend(base)
      pushEvent({ kind = "cast_succeeded", spellID = a3,
                  base = ns.Stash(St.BaseOfCast(a3)), at = GetTime() })
    end
  elseif event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED"
      or event == "UNIT_SPELLCAST_FAILED_QUIET" or event == "UNIT_SPELLCAST_STOP" then
    -- A cast STOPPED — cancelled/interrupted, or the normal STOP that trails SUCCEEDED.
    -- Push a terminal 'stopped' phase so it SUPERSEDES the 'start' in inflightIncoming's
    -- latest-phase-per-base check; without this a cancelled Hand of Gul'dan would keep
    -- projecting −3 for up to INFLIGHT_WINDOW (P6 Part 2).  Clears the spend snapshot too.
    if readable(a3) then
      pushCast("stopped", a3)
      local base = St.BaseOfCast(a3)
      if type(base) == "number" then spendStartShards[base] = nil end
    end
  elseif event == "SPELLS_CHANGED" then
    -- Knownness is respec-scoped, and this is the event that covers every way it can move
    -- (talent swap, spec change, level, a temporarily-granted ability).  Wiping is the whole
    -- invalidation: the next Build re-reads the spellbook for each candidate once.
    wipe(knownCache)
    -- The hero tree moves on exactly the same events, so it invalidates here too.
    heroCache.asked, heroCache.id, heroCache.name = false, nil, nil
  elseif event == "PLAYER_REGEN_DISABLED" then
    St.combatStartedAt = GetTime()
    pushEvent({ kind = "combat_start", at = GetTime() })
  elseif event == "PLAYER_REGEN_ENABLED" then
    pushEvent({ kind = "combat_end", at = GetTime() })
  end
  -- Power changes are NOT an event trigger — they fire far too often in a pull and
  -- flooded the ring (v0.29.0: 30 of 40 slots were power captures, evicting procs
  -- and the OOC baseline).  The poll's change-detection folds power into its
  -- signature instead, so a shard step still records but as a rate-limited 'change'.
end)

--------------------------------------------------------------------------------
-- Incoming shards — the in-flight builder projection (W4 P5b)
--------------------------------------------------------------------------------
-- `power.SoulShards.incoming` (architecture.md Stage-1) = the net shard yield of casts
-- currently IN FLIGHT, so the Coach can rank on PROJECTED shards (value + incoming) —
-- the overcap guard and the HoG-SOON "pressable the instant an in-flight builder's
-- shard lands" cue.  Sourced from State's OWN cast history: a 'start' with no later
-- 'succeeded' for the same base, within a short flight window.
--
-- SPEC-AGNOSTIC BY THE SAME RULE AS THE NAPKIN.  The per-cast delta comes from the
-- INJECTED `ns.SpecPowerDelta(base)` reader — the "injected mechanical shard-yield table"
-- the architecture sanctions as "a game-fact input like base cooldowns, so State's CODE
-- stays spec-agnostic; the rotational ROLE stays Coach-only".  State names no spell and
-- no role; it sums an injected SIGNED number: a builder is +, a spender is − (P6 Part 2).
--
-- PER-POWER (multi-spec Phase 3).  SpecPowerDelta now returns `{ power, delta }`, so the
-- sum is a MAP `sums[power] = total` rather than a scalar — a dual-resource spec's casts
-- accumulate onto their OWN named power.  Demo's casts all name "SoulShards", so the map
-- carries the single old scalar under that one key.
--
-- The SIGNED direction is why the projection now clears an in-flight HoG (−3) instead of
-- only promoting builders (the v0.32.2 bug: the overlay re-cued the spell you were
-- casting).  A spender's shards are consumed on COMPLETION, not cast-start, so during
-- flight the live `value` still reads the pre-spend number — the DOUBLE-DEDUCTION guard
-- (`spendStartShards` snapshot at START) drops the −delta only once the live value has
-- fallen below it, covering the one-frame race at completion before 'succeeded' lands.
-- Builders need no guard — they credit, never over-credit.
--
-- Attached to each power via the game Enum.PowerType name (game vocabulary, the
-- contract's sanctioned power-token exception — the same names State keys every power
-- by).  The second-spec seam is exactly here: a spec whose casts move a different
-- resource names it in `{ power, delta }`, with its own SpecPowerDelta.
--
-- `hist` defaults to the file-local history; it is a parameter so the off-game harness
-- (resource_multipower_spec) can drive the per-power accumulation with a synthetic
-- in-flight history — the multi-power seam proof (this is the pure core Build calls).
local function inflightIncoming(now, liveShards, hist)
  local sums = {}
  if not ns.SpecPowerDelta then return sums end
  hist = hist or history
  -- Latest phase per base within the flight window (a fresh 'start' still in flight; a
  -- 'succeeded'/'stopped' supersedes it and stops it counting).
  local latest = {}
  for i = 1, #hist do
    local h = hist[i]
    local id = h.base or h.spellID
    if type(id) == "number" and type(h.at) == "number" and (now - h.at) <= INFLIGHT_WINDOW then
      local prev = latest[id]
      if not prev or h.at >= prev.at then latest[id] = { phase = h.phase, at = h.at } end
    end
  end
  for id, e in pairs(latest) do
    if e.phase == "start" then
      local r = ns.SpecPowerDelta(id)
      local power = r and r.power
      local d = r and r.delta
      if power and type(d) == "number" and d ~= 0 then
        if d > 0 then
          sums[power] = (sums[power] or 0) + d   -- builder: credit unconditionally
        else
          -- Spender: apply the −delta only while the deduction has NOT landed (live value
          -- still at/above the start snapshot).  No snapshot / unreadable live => apply
          -- (the projecting-the-clear direction; the Coach ignores it anyway when shards
          -- read unreadable).  ⚠ multi-power guard: Phase-when-needed — `liveShards`/the
          -- snapshot are SoulShards-keyed, correct because Demo has one spender-power.
          local snap = spendStartShards[id]
          if snap == nil or liveShards == nil or liveShards >= snap then
            sums[power] = (sums[power] or 0) + d
          end
        end
      end
    end
  end
  return sums
end

-- Fold the per-power in-flight projection onto the live power table, walking the active
-- spec's declared powers (spec-agnostic; State names no power, the spec's `powers` does).
-- Each power flagged `incoming` and present in `power` gets its `incoming` field set to
-- the summed projection (0 when nothing is in flight).  Demo declares one power
-- (SoulShards), so this restores the exact single-bar behaviour.  Exposed alongside
-- inflightIncoming as the pure cores Build uses, for the off-game seam proof.
local function projectIncoming(power, sums, powers)
  if not (power and powers) then return end
  for _, p in ipairs(powers) do
    if p.incoming and p.name and power[p.name] then
      power[p.name].incoming = (sums and sums[p.name]) or 0
    end
  end
end

St.InflightIncoming = inflightIncoming   -- test seam (multi-power proof)
St.ProjectIncoming  = projectIncoming    -- test seam (multi-power proof)

--------------------------------------------------------------------------------
-- The DOMAIN VIEW fold (W4 re-layer, filtered by field-fix A) — PURE
--------------------------------------------------------------------------------
-- `abilities[base]` is "the PRESSABLE representative row" of an ability, and PRESSABLE is
-- ENFORCED here, not merely intended.  State anchors on the CDM DATABASE with
-- `allowUnlearned = true` (see the header), so without this filter the fold promotes rows
-- for spells the character has not talented and rows the Layout can never draw.  Both
-- read `ready` FOREVER — a hard cooldown that never runs — so they win the priority list
-- and sit above every real press.
--
-- TWO SIGNALS, and the order matters:
--   * `displayable` (PRIMARY) — an item frame exists for this cooldownID in the live
--     viewers.  NO INFERENCE: a frame is there or it is not, and if it is not, the Binder
--     has nothing to anchor to, so the cue would be dropped anyway.  This is the only
--     signal that catches INCINERATE — known, talented, pressed constantly, and simply
--     absent from the live tracked set.
--   * `isKnown` (SECONDARY) — the CDM's own "the character has this spell" flag, captured
--     since Phase 1 with zero consumers until now.  Catches the untalented rows
--     (Soul Fire / Havoc / Channel Demonfire) that DO have no frame either, but this is
--     the direct statement of the fact rather than a consequence of it.
--
-- ⚠ FAILURE DIRECTION, deliberately chosen.  The whole point is REMOVING rows, so a wrong
-- signal removes a real button — the same class of harm as the nil-guard outage.  Three
-- fences:
--   1. `isKnown` is trusted only when it says FALSE.  nil (no info struct, a combat-secret
--      read) is "we don't know", never "unlearned" — absence of a read is not evidence.
--   2. The displayable filter is SKIPPED WHOLESALE when the frame map is empty (viewers not
--      created yet, CDM unavailable).  An empty map must never mean "nothing is drawable".
--   3. Every drop is REPORTED (`dropped[base] = why`), so the decision log shows it and a
--      wrong filter is visible on the next capture rather than silent.
--
-- `dropped` only ever names an ability that WOULD have had a pressable row — a tracked-only
-- entry (Demonic Core, a buff bar) has no pressable member by construction, which is the
-- pre-existing exclusion and not a drop.
--
-- PURE: rows in, {abilities, dropped, dotEdges} out.  No client reads, no file locals —
-- which is what lets state_domainview_spec arbitrate it off-game.
local function baseOfRow(entry, fold)
  return (type(entry.spellID) == "number" and entry.spellID)
      or (fold and fold[entry.cooldownID])
      or nil
end

local function dropReason(entry, filterDisplayable)
  if entry.isKnown == false then return "unlearned" end
  if filterDisplayable and entry.displayable == false then return "no-icon" end
  return nil
end

-- The pressable representative of a row set: Essential outranks Utility; anything else
-- (TrackedBuff / TrackedBar) is an input, never a press.
local function pressableRep(rows)
  for _, e in ipairs(rows) do if e.category == "Essential" then return e end end
  for _, e in ipairs(rows) do if e.category == "Utility" then return e end end
  return nil
end

local function domainView(cooldowns, fold, filterDisplayable, edges)
  local abilities, dropped, dotEdges = {}, {}, {}
  -- Display-identity claims, resolved in a SECOND pass.  `pairs(rowsByBase)` order is
  -- unstable, so deciding a contested identity inline would make the domain view depend on
  -- table order — the exact class of bug the log's fixed render orders exist to prevent.
  local claimed = {}

  -- Group the raw rows by base spellID (base-spellID -> cooldownID is N:1 — a summon is one
  -- Essential row plus one TrackedBar row; Immolate is one Essential CAST row plus one
  -- BuffBar AURA row, and those two carry DIFFERENT base spellIDs, which is why the Coach
  -- resolves its DoT across a candidate list rather than assuming one id).
  local rowsByBase = {}
  for _, entry in pairs(cooldowns) do
    local base = baseOfRow(entry, fold)
    if base then
      local rows = rowsByBase[base]
      if not rows then rows = {}; rowsByBase[base] = rows end
      rows[#rows + 1] = entry
      -- The aura-lifecycle latch, re-keyed cid -> base so the Coach never sees a cooldownID.
      -- Newest wins when several of an ability's rows latched (both Immolate rows fire
      -- PandemicTime — §2.8 — and either must resolve to the one answer).
      local e = edges and edges[entry.cooldownID]
      if e then
        local prev = dotEdges[base]
        if not prev or (type(e.at) == "number" and type(prev.at) == "number" and e.at >= prev.at) then
          dotEdges[base] = e
        end
      end
    end
  end

  for base, rows in pairs(rowsByBase) do
    local kept, why = {}, nil
    for _, e in ipairs(rows) do
      local r = dropReason(e, filterDisplayable)
      if r then why = why or r else kept[#kept + 1] = e end
    end
    local rep = pressableRep(kept)
    if rep then
      rep.display = { cooldownID = rep.cooldownID, category = rep.category }
      rep.dot = dotEdges[base]        -- the row-level surface the brain reads
      -- Key by what the row DISPLAYS, not by its own spellID — see ns.DisplayIdentity.
      -- ⚠ Only for a row that SURVIVED the filter, which is load-bearing: on Hellcaller
      -- cid 66181 is unlearned, and re-keying that DROP onto Incinerate would make
      -- `virtualCandidates`' "not dropped-unlearned" fence refuse to synthesise our own
      -- Incinerate icon — killing the one path that already works.  A drop keeps its raw
      -- base (`dropped[base]` below is untouched); only a displayed row claims an identity.
      local ident = ns.DisplayIdentity(base, rep.overrideSpellID, rep.overrideTooltipSpellID)
      rep.identity = ident
      claimed[#claimed + 1] = { ident = ident, base = base, rep = rep }
    elseif why and pressableRep(rows) then
      -- It WOULD have been a press; the filter is the only reason it is not.  Say so.
      dropped[base] = why
    end
  end

  -- Pass 2 — assign keys.  A row keeps its own base unless it claims a DIFFERENT displayed
  -- identity that nothing else owns.  Sorted by base so a contested identity always
  -- resolves the same way regardless of `pairs` order.
  local owned = {}
  for _, c in ipairs(claimed) do owned[c.base] = true end
  table.sort(claimed, function(a, b) return a.base < b.base end)
  for _, c in ipairs(claimed) do
    -- Never displace a row that legitimately owns that key as its OWN base, and never let
    -- two rows claim one identity (first by sorted base wins, deterministically).
    if c.ident ~= c.base and not owned[c.ident] and abilities[c.ident] == nil then
      abilities[c.ident] = c.rep
    else
      c.rep.identity = c.base
      abilities[c.base] = c.rep
    end
  end

  return abilities, dropped, dotEdges
end

St.DomainView = domainView               -- test seam (the field-fix A/C proof)

--------------------------------------------------------------------------------
-- VIRTUAL ROWS — the rotation buttons the Cooldown Manager tracks NOWHERE
--------------------------------------------------------------------------------
-- THE PROBLEM (docs/virtual-cdm-plan.md).  Blizzard's CDM does not track every ability a
-- rotation needs.  Destruction's INCINERATE is the sharp case: spellID 29722 is absent from
-- `CooldownSetSpell` for every set (Tier-1, 12.0.7), so it never enters `enumerate()`, never
-- reaches `cooldowns`, and therefore never reaches `abilities` — and `RankWinner`'s
-- `key(base)` gates on `ctx.facts[base]`, so THE COACH CANNOT PICK IT AT ALL.  The first
-- live Destruction pass measured the cost: 59 of 191 decision changes had NO winner (31 %),
-- every one at 0–2 shards, i.e. below Chaos Bolt's cost where the floor press was the right
-- answer and could not be named.  Demonology has the identical hole at Shadow Bolt.
--
-- ⚠ THIS IS A DECISION PROBLEM BEFORE IT IS A DRAWING PROBLEM.  Drawing an icon for a cue
-- that is never emitted would achieve nothing, which is why the row is synthesised HERE, in
-- the domain view, rather than invented downstream: the Binder is a pure geometry merge and
-- has no cue to map until State gives the Coach something to pick.
--
-- WHY IT IS DETECTED, NOT DECLARED.  `ns.Spec` ALREADY IS the spec's ability library — every
-- rotation button, with its `kind` / `cadence` / `expect`.  A `virtual = true` flag would
-- merely restate what that table says, and would have to be maintained per spec forever.  So
-- the walk asks the table directly, and Phase 3's "generalise to Shadow Bolt" is zero edits.
--
-- ⚠ THE RELATIONSHIP TO FIELD-FIX A, which removed rows for two reasons that are NOT the
-- same kind of claim:
--   * `unlearned` (isKnown == false) — the character does not have this spell.  A CORRECTNESS
--     fence; it is what killed the 216-dropped-Soul-Fire-cues bug, and it survives here as
--     the `known` fence below (read from the spellbook, since an untracked ability has no CDM
--     struct to carry `isKnown`).
--   * `no-icon` (no item frame) — the character HAS it and presses it constantly; we simply
--     could not draw it.  That is a DISPLAY limit that was being enforced at the DECISION
--     layer, correct only while the product was strictly a CDM overlay.  It is the fence this
--     walk deliberately reverses: unmappable now means "draw our own icon", not "forget it".
--
-- WHY ADMITTING ROWS HERE CANNOT RE-CREATE PHANTOM ABILITIES.  Coach.Classify computes
-- `probablyUp = ready or (onCd and source == "napkin" and remaining <= 0)`, and every
-- cooldown-bearing line in RankWinner gates on `usable()`, which needs `probablyUp` or a
-- banked charge.  An ability admitted with no observation reads `unknown` — neither ready nor
-- on-cooldown — so `probablyUp` is FALSE and it can never win a line.  That is why the
-- zero-cooldown fence below is not a prohibition but a DESCRIPTION: a 0-cooldown spell is the
-- only case where we can honestly rank without an observation, because `ready` is then a
-- statement about the spell's NATURE rather than a faked reading of its state.
--
-- THE HANDLE IS NEGATIVE (`-spellID`).  Real cooldownIDs are positive, so collision with a
-- Blizzard row is impossible by construction rather than by luck, and the handle is
-- reversible by eye in a decision log.

-- (`knownCache` is declared ABOVE the event frame — it is wiped from the SPELLS_CHANGED
--  handler, which is defined earlier in the file than this walk.)
local function spellKnown(spellID)
  local c = knownCache[spellID]
  if c ~= nil then return c end
  if not (C_SpellBook and C_SpellBook.IsSpellKnown) then return nil end
  local ok, known = pcall(C_SpellBook.IsSpellKnown, spellID)
  if not ok or type(known) ~= "boolean" then return nil end
  knownCache[spellID] = known
  return known
end

-- Every identity the CDM is ALREADY displaying — not merely the base spellIDs `abilities`
-- is keyed by.  A row's base can be a DIFFERENT SPELL from the one it draws (cid 66181 is
-- Shadow Bolt 686 displaying Incinerate 29722), so "is this ability on screen?" cannot be
-- answered from the keys alone.
--
-- ⚠ UNIONING THE TWO STATIC OVERRIDE FIELDS IS LOAD-BEARING, not belt-and-braces.  While
-- the Demonic Art is armed that row's `liveSpellID` becomes Infernal Bolt 433891 — so a
-- `liveSpellID`-only check would let our duplicate icon flicker back in MID-COMBAT, exactly
-- when the ability is most active.  `overrideSpellID` / `overrideTooltipSpellID` carry the
-- displayed id (29722) throughout.
local function displayedIdentities(abilities)
  local on = {}
  for base, row in pairs(abilities) do
    on[base] = true
    if readable(row.liveSpellID) then on[row.liveSpellID] = true end
    if readable(row.overrideSpellID) then on[row.overrideSpellID] = true end
    if readable(row.overrideTooltipSpellID) then on[row.overrideTooltipSpellID] = true end
  end
  return on
end

-- PURE: (spec table, abilities, dropped, known(), baseCooldown()) -> sorted base spellIDs.
-- Sorted so frame assignment is stable across ticks and the tests are order-independent.
--
-- Every fence is required, and each earns its place:
--   kind == "button"      an aura row is an INPUT to a decision, never a press.
--   cadence ~= "utility"  defensives / CC / mobility are never cued; drawing our own icon
--                         for a Healthstone is exactly the scope creep that would turn this
--                         into a replacement UI.
--   expect ~= false       the spec table's EXISTING statement of "never bound to a CDM icon
--                         of its own" — the transforms (Ruination / Infernal Bolt) and the
--                         cast-id aliases.  An override or an alias must never become a
--                         second icon beside the ability it is an alias OF.
--   not already DISPLAYED Blizzard draws it -> we do not.  Asked of the DISPLAY identities
--                         (`displayedIdentities`), not of `abilities`' keys: cid 66181 is
--                         Shadow Bolt 686 with its display overridden to Incinerate 29722,
--                         so a base-identity test stays true while Blizzard is visibly
--                         drawing the ability — and we synthesised a SECOND icon (the
--                         v0.32.32 Diabolist duplicate).  If the CDM ever starts tracking
--                         the ability, the virtual row silently stops being synthesised.
--   not dropped-unlearned the CDM said this row is unlearned.  Even if the spellbook
--                         disagrees, a conflict resolves to NOT DRAWING (under-show).
--   base cooldown == 0    see the header.  `ns.BaseCooldown` returns nil when the read
--                         refuses, and nil ~= 0, so an unreadable cooldown yields no row.
--   known                 the surviving half of field-fix A.
local function virtualCandidates(specTable, abilities, dropped, known, baseCooldown)
  local out = {}
  if type(specTable) ~= "table" then return out end
  local onScreen = displayedIdentities(abilities)
  for spellID, info in pairs(specTable) do
    if type(spellID) == "number" and type(info) == "table"
        and info.kind == "button"
        and info.cadence ~= "utility"
        and info.expect ~= false
        and not onScreen[spellID]
        and (not dropped or dropped[spellID] ~= "unlearned")
        and baseCooldown(spellID) == 0
        and known(spellID) == true then
      out[#out + 1] = spellID
    end
  end
  table.sort(out)
  return out
end

-- The synthetic domain-view row.  Keyed by base spellID like every other `abilities` row,
-- and carrying every field Classify reads, so nothing downstream needs to know it is ours.
--
-- `cd.source = "static"` is a FOURTH member of the trust annotation (live|napkin|none), and
-- it exists precisely so this is not laundered as `"live"`: we are stating the spell's
-- nature, not reporting an observation.  Nothing branches on `source` except Classify
-- (which tests `== "napkin"`) and the decision log (which renders `state` only), so the
-- addition is inert by design.
--
-- `liveSpellID` still resolves through the override map, so IF the client fires
-- COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED for an untracked base the Diabolist transform
-- (Incinerate -> Infernal Bolt) rides this frame exactly as it would a real one.  Whether it
-- fires for a spell with no CDM entry is the one thing only a live pass can settle
-- (@verify-ingame); absent the event this degrades to a plain Incinerate, which is correct.
local function virtualRow(spellID)
  local live = St.override[spellID]
  if not readable(live) then live = spellID end
  return {
    cooldownID  = -spellID,
    category    = "Virtual",
    spellID     = spellID,
    liveSpellID = live,
    linkedSpellIDs = {},
    selfAura    = false,
    hasAura     = false,
    charges     = false,
    isKnown     = true,
    displayable = true,
    virtual     = true,
    cd     = { state = "ready", remaining = 0, readable = true, source = "static" },
    charge = { readable = true, cur = nil, max = 0 },
    aura   = { readable = true, active = false },
    glow   = readGlow(live),
    display = { cooldownID = -spellID, category = "Virtual" },
    keybind = ns.HudBinds.Get(spellID),
  }
end

St.VirtualCandidates = virtualCandidates   -- test seam (the fence proof)
St.VirtualRow        = virtualRow          -- test seam (the row shape)
St.DisplayedIdentities = displayedIdentities  -- test seam (the display-identity fence)
St.SpellKnown        = spellKnown

--------------------------------------------------------------------------------
-- St.Build — the reduced picture for THIS instant.  `drain` (capture path) moves
-- the pending events into the pulse and clears them; a diagnostic Build leaves them
-- for the next real capture so "delta since last pulse" stays honest.
function St.Build(drain)
  local now = GetTime()
  installAlertHooks()            -- keep the CDM alert edges wired (idempotent)
  local set = enumerate()
  wipe(St.baseOfCast)
  -- ONE full active-buff scan for the whole pulse — the spec-agnostic proc source.
  local auraList, activeByID, auraSecret = scanActiveAuras()
  local items = itemFrameMap()   -- cooldownID -> item frame, for the buff-item probe

  local cooldowns = {}
  for cooldownID, categoryName in pairs(set) do
    local info = cooldownInfo(cooldownID)
    local base = info and readable(info.spellID) and info.spellID or nil
    local live = liveSpellID(info) or base
    local hasAura = info and info.hasAura and true or false
    local selfAura = info and info.selfAura and true or false
    local hasCharges = info and info.charges and true or false
    -- ⚠ THREE-VALUED, and it MUST be built with an if.  The obvious one-liner
    -- `info and (info.isKnown and true or false) or nil` is a Lua and/or trap: a FALSE
    -- middle term falls through to the `or nil`, so `isKnown` could only ever read `true`
    -- or `nil` — never `false`.  It shipped that way since W4 Phase 1 and went unnoticed
    -- because the field had no consumer until field-fix A gave it one.  The three values are
    -- load-bearing now: false = "the client says unlearned" (a drop), nil = "no info struct
    -- / unreadable" (NOT a drop).
    local isKnown
    if info ~= nil then isKnown = info.isKnown and true or false end

    -- Build the inverse identity index as we go (B3).
    if base then St.baseOfCast[base] = base end
    if readable(live) then St.baseOfCast[live] = base or live end
    -- (the charge napkin's base -> cooldownID binding is done below, off the MEASURED
    --  `charge.charged` rather than the struct flag — see readCharge)

    local linked = {}
    if info and type(info.linkedSpellIDs) == "table" then
      for _, id in ipairs(info.linkedSpellIDs) do
        if readable(id) then linked[#linked + 1] = id end
      end
    end

    -- Charges, and the napkin's base -> cooldownID edge.  The alert and the OOC seed arrive
    -- keyed by cooldownID; a cast arrives keyed by spellID.  Bound off the MEASURED `charged`
    -- (a live max > 1), so a wrong struct flag cannot silently disable the napkin.
    local charge = readCharge(live, hasCharges, cooldownID)
    if charge.charged and base then chargeCid[base] = cooldownID end

    -- The entry's associated aura ids (no nils/holes — ipairs-safe), for the scan match.
    local auraIds = {}
    if readable(live) then auraIds[#auraIds + 1] = live end
    if readable(base) and base ~= live then auraIds[#auraIds + 1] = base end
    for _, id in ipairs(linked) do auraIds[#auraIds + 1] = id end

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
      isKnown    = isKnown,
      -- CAN THE BINDER EVER DRAW THIS ROW?  A cooldownID with no item frame in any live
      -- viewer has no anchor, so a cue on it is dropped by construction (field-fix A).
      -- Structural and inference-free: the frame is there or it is not.
      displayable = items[cooldownID] ~= nil,
      flags      = info and ns.Stash(info.flags) or nil,
      -- live facts (secrecy first-class)
      cd     = stampCd(cooldownID, readCd(live, base, cooldownID), now),
      charge = charge,
      aura   = readAura(hasAura, selfAura, activeByID, auraIds, auraSecret),
      glow   = readGlow(live),   -- the combat-readable proc-highlight signal
      -- buff-item frame state (isActive/shown) — measured for the aura entries, the
      -- candidate per-buff combat signal the DB struct doesn't carry.
      buff   = (hasAura or selfAura) and readBuffItem(items[cooldownID]) or nil,
      -- mostly-static, OOC-resolved off the BASE id (finding-3)
      keybind = base and ns.HudBinds.Get(base) or nil,
    }
  end

  local events = {}
  if drain then
    for i = 1, #pending do events[i] = pending[i] end
    wipe(pending)
  end

  -- Cast history within the window, oldest->newest — the sequence-memory substrate.
  local hist = {}
  for i = 1, #history do
    local c = history[i]
    if (now - c.at) <= HISTORY_WINDOW then hist[#hist + 1] = c end
  end

  -- Power, with the in-flight SIGNED projection folded PER POWER onto each bar (P5b;
  -- signed in P6 Part 2 so an in-flight spender clears itself; per-power in Phase 3).
  -- We walk the active spec's declared powers rather than hardwiring SoulShards; the
  -- SoulShards live value still doubles as inflightIncoming's double-deduction guard input.
  local power = readPower()
  local shardName = Enum and Enum.PowerType and POWER_NAME[Enum.PowerType.SoulShards]
  local liveShards
  if shardName and power[shardName] then
    local v = power[shardName].value
    liveShards = (type(v) == "number") and v or nil
  end
  local sums = inflightIncoming(now, liveShards)
  projectIncoming(power, sums, ns.ActiveSpec and ns.ActiveSpec.powers)

  -- ── THE DOMAIN VIEW (W4 re-layer) — the pipeline's actual input, keyed by BASE
  -- spellID, folding the N CDM rows of one ability into one.  `cooldowns` above is the
  -- RAW CDM diagnostic view (retained for probe/cdmp.py, additive); this is what the
  -- Coach decides on.  Assembled from the just-built locals — NO new spec coupling: the
  -- fold key is `category` (spec-agnostic) + base spellID (from the readable row or the
  -- OOC-cached foldBase fallback).
  --   abilities[base] = the PRESSABLE representative row (Essential > Utility) of the
  --                     ability, carrying every field Classify reads, plus `display`
  --                     (the cooldownID/category the Binder anchors to).  Tracked-only
  --                     rows (Demonic Core, Wild Imp — no pressable twin) do NOT enter.
  --   buffs[spellID]  = procs/auras PRESENT (a summon's TrackedBar isActive lands here as
  --                     the window-active signal), unioned with the flat active-aura scan.
  --   dropped[base]   = an ability the FILTER removed and why (field-fix A) — never silent.
  -- (The named power bars ride `power` — keyed by Enum.PowerType name — which every
  --  consumer reads directly; the old `resources.shards` alias was retired in Phase 4.)
  -- Tracked-only rows (Demonic Core, Wild Imp — no pressable twin) still do NOT enter
  -- `abilities`; the fold gives that exclusion for free.
  local function baseOf(entry)
    return baseOfRow(entry, foldBase)
  end

  -- ⚠ The displayable filter is applied only when we HAVE a frame map.  An empty map means
  -- the viewers are not up (login, CDM disabled, a relayout mid-pulse), not that nothing on
  -- the board can be drawn — filtering on it would empty `abilities` outright, which is the
  -- exact shape of the v0.32.25 total outage.
  local abilities, dropped, dotEdges = domainView(cooldowns, foldBase, next(items) ~= nil,
                                                  St.dotEdge)

  -- VIRTUAL ROWS — the spec's own rotation buttons the CDM tracks nowhere (see the walk's
  -- header).  Synthesised AFTER the fold, so `abilities` is the real absence test, and
  -- folded into the SAME table so every stage above is unchanged: to the Coach a virtual row
  -- is just another pressable ability, and to the Binder its negative handle is just another
  -- Layout key.  `pulse.virtual` is the sorted id list HudVirtual pools its frames from.
  local virtual = virtualCandidates(ns.Spec, abilities, dropped, spellKnown, ns.BaseCooldown)
  for _, id in ipairs(virtual) do
    abilities[id] = virtualRow(id)
  end

  -- buffs — presence, secrecy-guarded (an entry's aura/buff reads TRUE only when it was
  -- readable, so absence never becomes a false positive).  Keyed by the entry's base for
  -- the CDM rows, and by the aura's own spellID for the flat scan.
  local buffs = {}
  for _, entry in pairs(cooldowns) do
    if (entry.aura and entry.aura.active == true)
        or (entry.buff and entry.buff.isActive == true) then
      local base = baseOf(entry)
      if base then buffs[base] = true end
    end
  end
  for _, a in ipairs(auraList) do
    if type(a.spellID) == "number" then buffs[a.spellID] = true end
  end

  return {
    at     = now,
    combat = InCombatLockdown() and true or false,
    combatStartedAt = St.combatStartedAt,   -- so "elapsed in combat" is computable here
    -- The user-toggled single/AoE mode (P5b).  State FORWARDS it (from the AoE toggle
    -- `/cdmp single|multi|aoe` sets in Mode.lua); the Coach READS it.  Spec-agnostic: it
    -- is a generic "st"|"aoe" enum, not a rotation fact.  Defaults "st" (single).
    mode   = (ns.Mode and ns.Mode.aoe) and "aoe" or "st",
    -- THE ACTIVE HERO TALENT TREE, read from the client here so it rides the pulse: a
    -- captured pulse must be able to reproduce a hero-gated decision.  `hero` is the
    -- generic name ("hellcaller"), `heroSubTreeID` the raw TraitSubTree id — carried even
    -- when unmapped so the capture is self-describing.  BOTH may be nil (API refused, or
    -- a class we have no map for); the Coach has an inference fallback for that.
    hero          = (readHero()),
    heroSubTreeID = select(2, readHero()),
    -- RAW CDM view (retained, additive) — probe / DecisionLog short-codes / cdmp.py.
    cooldowns = cooldowns,
    -- DOMAIN view (the re-layer) — the pipeline's input; the Coach decides on THIS.
    abilities = abilities,
    buffs     = buffs,
    -- The base spellIDs whose `abilities` row is SYNTHETIC (sorted).  HudVirtual pools one
    -- button frame per id and returns Layout/registry fragments the driver merges; each row
    -- also carries `virtual = true`, so a consumer that never sees this list can still tell.
    virtual   = virtual,
    -- What the domain-view filter REMOVED, and why (field-fix A).  base spellID -> reason
    -- ("unlearned" | "no-icon").  Rendered by the decision log so a filter that drops a
    -- real button shows up in the trace instead of being silently absent.
    dropped   = dropped,
    -- The aura-lifecycle latch, re-keyed cooldownID -> BASE spellID (field-fix C).  Carried
    -- as its own map as well as on each pressable row, because an ability's latch can live
    -- on a row that is NOT pressable — Immolate's DoT aura sits on the Buff-bar viewer and
    -- never enters `abilities`, yet it raises PandemicTime just like the Essential cast row.
    dotEdges  = dotEdges,
    power  = power,
    -- Every active player buff, spec-agnostically — the Coach's authoritative proc
    -- source, and the diagnostic that reveals a proc's TRUE aura id when a CDM entry's
    -- own spellID does not match it.  `auraSecret` = auras whose id read secret.
    activeAuras = auraList,
    activeAuraSecret = auraSecret,
    -- Recent casts (start + succeeded), the Coach's sequence memory — see the header.
    history = hist,
    events = events,
  }
end

--------------------------------------------------------------------------------
-- Lifecycle — ref-counted event ingestion
--------------------------------------------------------------------------------
-- EVENT INGESTION is the override/history/combat tracking + the napkin/keybind inputs
-- a good pulse needs.  The LIVE DRIVER (HudDriver, /cdmp hud) Acquire()s it to keep the
-- eframe events running, and Release()s it when the HUD is turned off.  Ingestion is
-- REF-COUNTED — the events run while any consumer holds a ref — so multiple consumers
-- can share it.  This is the "expose the pulse to a driver" seam: State.Build + a clean
-- way to keep ingestion live.  (The W4-Phase-1 statelog disk-recording layer that used
-- to sit on top of this was retired at the W4 cutover; the decision log is the
-- pipeline's recorder now.)
St.consumers = 0                -- live consumers of event ingestion

function St.Acquire()
  St.consumers = St.consumers + 1
  if St.consumers > 1 then return end   -- already ingesting
  wipe(St.override)
  -- State CONSULTS the napkin and keybind cache as inputs, so it owns making them
  -- live for a session — otherwise, with the HUD off, both are dormant and every cd
  -- reads source="none" while every keybind is nil (the v0.29.0 gap: the napkin's
  -- SUCCEEDED frame and the bar scan are only started by the HUD).  Both Start()s are
  -- idempotent, so this is harmless if another consumer already started them.
  ns.HudNapkin.Start()
  ns.HudBinds.Start()
  eframe:RegisterEvent("COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED")
  eframe:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
  eframe:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
  -- Terminal cast phases — clear an in-flight spender's −shard projection when the cast
  -- ends without completing (or on the STOP that trails a normal cast).  P6 Part 2.
  eframe:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player")
  eframe:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player")
  eframe:RegisterUnitEvent("UNIT_SPELLCAST_FAILED_QUIET", "player")
  eframe:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player")
  eframe:RegisterEvent("PLAYER_REGEN_DISABLED")
  eframe:RegisterEvent("PLAYER_REGEN_ENABLED")
  -- Invalidates the virtual-row knownness cache (talent swap / respec / level).
  eframe:RegisterEvent("SPELLS_CHANGED")
end

function St.Release()
  if St.consumers <= 0 then return end
  St.consumers = St.consumers - 1
  if St.consumers == 0 then eframe:UnregisterAllEvents() end
end

-- State is available from load; ingestion only runs once a consumer (the HUD driver)
-- Acquire()s it.  OnLogin just builds the category/power name caches.
local prevOnLogin = ns.OnLogin
function ns.OnLogin()
  if prevOnLogin then prevOnLogin() end
  buildCategoryNames()
  buildPowerNames()
end
