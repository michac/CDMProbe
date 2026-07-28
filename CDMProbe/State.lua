-- State.lua — the REDUCED CLIENT PICTURE (W4 pipeline Stage 1).
--
-- The one stage that touches the game API, distilled to a spec-agnostic table
-- everything above the pipeline consumes: State -> Coach -> Guidance -> Binder ->
-- DrawList -> Renderer (docs/architecture.md).  This file builds ONLY Stage 1.  It
-- decides no cue, knows no rotation, imports no SpecDemonology — that is invariant
-- #3, and it is enforced from the outside by `wowkb.cdmp check`'s statelog denylist.
-- (It DOES consult a couple of injected `ns.Spec*` READERS — the napkin's base
-- cooldowns, and `ns.SpecShardDelta` for the signed shard-incoming projection — exactly as the
-- architecture sanctions "a game-fact input like base cooldowns": State's code names
-- no spell and no role; the rotational meaning stays Coach-only.)
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
--   4. READINESS IS OBSERVED, NOT GUESSED (W4 Phase 7).  The cd model is THREE
--      honest states — ready | on-cooldown | unknown — with `source` (live|napkin|
--      none) a trust annotation on `remaining`, not a second axis.  Readiness rests
--      on an OOC read, the OOC baseline carried across combat entry, or an OBSERVED
--      CDM alert edge (Available/OnCooldown) — never a bare estimate; the napkin
--      supplies only the *remaining* seconds while on cooldown.  The keybind is the
--      OOC-resolved base-id binding.
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

-- FOLD cache (W4 domain-view re-layer), keyed by cooldownID.  base-spellID -> cooldownID
-- is N:1 (a summon is one Essential row + one TrackedBar/TrackedBuff row), and Build's
-- domain view must group the N CDM rows of one ability under its base spellID.  In combat
-- a row's `spellID` can read secret, so this remembers each cooldownID's base from the
-- OOC-readable path (where base is guaranteed readable) as the fallback fold key; the
-- per-pulse readable base is primary.  Lives with cdBaseline/readyEdge, written on the
-- same OOC-readable rhythm in readCd, wiped with them in clearStatelog.
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
-- ⚠ COMBAT AURAS ARE SECRET (measured v0.29.4).  A `/cdmp statelog` capture proved it:
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
local captureReason = nil       -- why the next poll should record (nil = no pull owed)

local function markCapture(reason)
  captureReason = captureReason or reason
end

-- Append to the since-last-pulse delta.  Bounded: a Build(false) consumer (the live
-- driver) never drains `pending`, so without a cap it would grow without limit; the
-- ring is only ever the last PENDING_MAX events, which is far more than one pulse's
-- worth (the statelog Capture drains it every ~change anyway).
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
-- State ports the HOOK PATTERN from HudState (the old HUD's S.Install/onAlert) but
-- owns its own edge store and never reads HudState's S.readyAt/HudChrome — the
-- separation wowkb.cdmp's statelog denylist enforces.
local function onAlert(item, event)
  if St.consumers <= 0 then return end   -- gated like the old HUD's ns.Hud.on
  local A = Enum and Enum.CooldownViewerAlertEventType
  if not A then return end
  -- A Secret Value must never be compared; if the event arg is ever restricted we
  -- drop it rather than taint on the ==.
  if ns.IsSecret(event) then return end
  if event ~= A.Available and event ~= A.OnCooldown then return end
  -- Resolve the item's cooldownID, guarded (an unreadable id is dropped, not keyed).
  local cid = readable(item.cooldownID) and item.cooldownID or nil
  if not cid and ns.HasMethod(item, "GetCooldownID") then
    local ok, id = pcall(item.GetCooldownID, item)
    if ok and readable(id) then cid = id end
  end
  if not cid then return end
  local now = GetTime()
  local ready = (event == A.Available)
  readyEdge[cid] = { ready = ready, at = now }
  pushEvent({ kind = "ready_edge", cooldownID = cid, ready = ready, at = now })
  markCapture("edge")
end

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
        markCapture("transform")
      end
    end
  elseif event == "UNIT_SPELLCAST_START" then
    -- (unit, castGUID, spellID) — the cast is IN FLIGHT.  Cast-time spells only; the
    -- Coach can start hinting the next step before this one lands.
    if readable(a3) then
      pushCast("start", a3)
      -- Snapshot shards at a SPENDER's start (signed delta < 0) so inflightIncoming can
      -- guard the completion-frame double-deduction (P6 Part 2).  Spec-agnostic: State
      -- reads the injected signed delta, names no spell.
      local base = St.BaseOfCast(a3)
      if ns.SpecShardDelta and type(base) == "number" then
        local d = ns.SpecShardDelta(base)
        if type(d) == "number" and d < 0 then spendStartShards[base] = currentShardValue() end
      end
      pushEvent({ kind = "cast_started", spellID = a3,
                  base = ns.Stash(St.BaseOfCast(a3)), at = GetTime() })
      markCapture("cast")
    end
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    -- a3 is the spellID (unit, castGUID, spellID); RegisterUnitEvent filters to
    -- player.  Resolve back to the base entry so the Coach can tie it to a cooldown.
    if readable(a3) then
      pushCast("succeeded", a3)
      local base = St.BaseOfCast(a3)
      if type(base) == "number" then spendStartShards[base] = nil end
      pushEvent({ kind = "cast_succeeded", spellID = a3,
                  base = ns.Stash(St.BaseOfCast(a3)), at = GetTime() })
      markCapture("cast")
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
  elseif event == "PLAYER_REGEN_DISABLED" then
    St.combatStartedAt = GetTime()
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
-- Incoming shards — the in-flight builder projection (W4 P5b)
--------------------------------------------------------------------------------
-- `power.SoulShards.incoming` (architecture.md Stage-1) = the net shard yield of casts
-- currently IN FLIGHT, so the Coach can rank on PROJECTED shards (value + incoming) —
-- the overcap guard and the HoG-SOON "pressable the instant an in-flight builder's
-- shard lands" cue.  Sourced from State's OWN cast history (a 'start' with no later
-- 'succeeded' for the same base, within a short flight window), NOT from HudState — the
-- clean-room separation (see the S.override note) is deliberate: State owns its
-- projection and never reaches into the old HUD's `S.cast`.
--
-- SPEC-AGNOSTIC BY THE SAME RULE AS THE NAPKIN.  The per-cast delta comes from the
-- INJECTED `ns.SpecShardDelta(base)` reader — the "injected mechanical shard-yield table"
-- the architecture sanctions as "a game-fact input like base cooldowns, so State's CODE
-- stays spec-agnostic; the rotational ROLE stays Coach-only".  State names no spell and
-- no role; it sums an injected SIGNED number: a builder is +, a spender is − (P6 Part 2).
--
-- The SIGNED direction is why the projection now clears an in-flight HoG (−3) instead of
-- only promoting builders (the v0.32.2 bug: the overlay re-cued the spell you were
-- casting).  A spender's shards are consumed on COMPLETION, not cast-start, so during
-- flight the live `value` still reads the pre-spend number — the DOUBLE-DEDUCTION guard
-- (`spendStartShards` snapshot at START) drops the −delta only once the live value has
-- fallen below it, covering the one-frame race at completion before 'succeeded' lands.
-- Builders need no guard — they credit, never over-credit.
--
-- Attached to the SoulShards power via the game Enum.PowerType name (game vocabulary,
-- the contract's sanctioned power-token exception — the same names State keys every
-- power by).  The second-spec seam is exactly here: a spec whose casts move a different
-- resource names it in place of SoulShards, with its own SpecShardDelta.
local function inflightIncoming(now, liveShards)
  if not (ns.SpecShardDelta) then return 0 end
  -- Latest phase per base within the flight window (a fresh 'start' still in flight; a
  -- 'succeeded'/'stopped' supersedes it and stops it counting).
  local latest = {}
  for i = 1, #history do
    local h = history[i]
    local id = h.base or h.spellID
    if type(id) == "number" and type(h.at) == "number" and (now - h.at) <= INFLIGHT_WINDOW then
      local prev = latest[id]
      if not prev or h.at >= prev.at then latest[id] = { phase = h.phase, at = h.at } end
    end
  end
  local sum = 0
  for id, e in pairs(latest) do
    if e.phase == "start" then
      local d = ns.SpecShardDelta(id)
      if type(d) == "number" and d ~= 0 then
        if d > 0 then
          sum = sum + d               -- builder: credit unconditionally
        else
          -- Spender: apply the −delta only while the deduction has NOT landed (live value
          -- still at/above the start snapshot).  No snapshot / unreadable live => apply
          -- (the projecting-the-clear direction; the Coach ignores it anyway when shards
          -- read unreadable).
          local snap = spendStartShards[id]
          if snap == nil or liveShards == nil or liveShards >= snap then sum = sum + d end
        end
      end
    end
  end
  return sum
end

--------------------------------------------------------------------------------
-- Build — the pulse
--------------------------------------------------------------------------------
-- Constructs the reduced picture for THIS instant.  `drain` (capture path) moves
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

    -- Build the inverse identity index as we go (B3).
    if base then St.baseOfCast[base] = base end
    if readable(live) then St.baseOfCast[live] = base or live end

    local linked = {}
    if info and type(info.linkedSpellIDs) == "table" then
      for _, id in ipairs(info.linkedSpellIDs) do
        if readable(id) then linked[#linked + 1] = id end
      end
    end

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
      isKnown    = info and (info.isKnown and true or false) or nil,
      flags      = info and ns.Stash(info.flags) or nil,
      -- live facts (secrecy first-class)
      cd     = stampCd(cooldownID, readCd(live, base, cooldownID), now),
      charge = readCharge(live, hasCharges),
      aura   = readAura(hasAura, selfAura, activeByID, auraIds, auraSecret),
      glow   = readGlow(live),   -- the combat-readable proc-highlight signal
      -- buff-item frame state (isActive/shown) — measured for the aura entries, the
      -- candidate per-buff combat signal the DB struct doesn't carry.
      buff   = (hasAura or selfAura) and readBuffItem(items[cooldownID]) or nil,
      -- mostly-static, OOC-resolved off the BASE id (finding-3)
      keybind = (base and ns.HudBinds and ns.HudBinds.Get and ns.HudBinds.Get(base)) or nil,
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

  -- Power, with the in-flight SIGNED shard projection folded onto the shard bar (P5b;
  -- signed in P6 Part 2 so an in-flight spender clears itself).  The live value doubles
  -- as inflightIncoming's double-deduction guard input.
  local power = readPower()
  local shardName = Enum and Enum.PowerType and POWER_NAME[Enum.PowerType.SoulShards]
  if shardName and power[shardName] then
    local v = power[shardName].value
    local liveShards = (type(v) == "number") and v or nil
    power[shardName].incoming = inflightIncoming(now, liveShards)
  end

  -- ── THE DOMAIN VIEW (W4 re-layer) — the pipeline's actual input, keyed by BASE
  -- spellID, folding the N CDM rows of one ability into one.  `cooldowns` above is the
  -- RAW CDM diagnostic view (retained for statelog/probe, additive); this is what the
  -- Coach decides on.  Assembled from the just-built locals — NO new spec coupling: the
  -- fold key is `category` (spec-agnostic) + base spellID (from the readable row or the
  -- OOC-cached foldBase fallback).
  --   abilities[base] = the PRESSABLE representative row (Essential > Utility) of the
  --                     ability, carrying every field Classify reads, plus `display`
  --                     (the cooldownID/category the Binder anchors to).  Tracked-only
  --                     rows (Demonic Core, Wild Imp — no pressable twin) do NOT enter.
  --   buffs[spellID]  = procs/auras PRESENT (a summon's TrackedBar isActive lands here as
  --                     the window-active signal), unioned with the flat active-aura scan.
  --   resources.shards = the SoulShards bar ({ value, max, incoming }).
  local function baseOf(entry)
    return (type(entry.spellID) == "number" and entry.spellID) or foldBase[entry.cooldownID]
  end

  local abilities = {}
  do
    -- Group the raw rows by base spellID, then pick each ability's pressable member.
    local rowsByBase = {}
    for _, entry in pairs(cooldowns) do
      local base = baseOf(entry)
      if base then
        local rows = rowsByBase[base]
        if not rows then rows = {}; rowsByBase[base] = rows end
        rows[#rows + 1] = entry
      end
    end
    for base, rows in pairs(rowsByBase) do
      local rep
      for _, e in ipairs(rows) do
        if e.category == "Essential" then rep = e; break end
      end
      if not rep then
        for _, e in ipairs(rows) do
          if e.category == "Utility" then rep = e; break end
        end
      end
      -- No pressable (Essential/Utility) member => a tracked-only ability (Core, Wild
      -- Imp): not in `abilities` (its presence rides `buffs`).  The fold gives the
      -- tracked-row EXCLUSION for free, which is all the fix needs (the TrackedBar
      -- DURATION -> abilities[base].uptime is a documented follow-up, not this task).
      if rep then
        rep.display = { cooldownID = rep.cooldownID, category = rep.category }
        abilities[base] = rep
      end
    end
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

  local resources = { shards = shardName and power[shardName] or nil }

  return {
    at     = now,
    combat = InCombatLockdown() and true or false,
    combatStartedAt = St.combatStartedAt,   -- so "elapsed in combat" is computable here
    -- The user-toggled single/AoE mode (P5b).  State FORWARDS it (from the AoE toggle
    -- the old HUD's /cdmp single|multi sets); the Coach READS it.  Spec-agnostic: it is
    -- a generic "st"|"aoe" enum, not a rotation fact.  Defaults "st" (single).
    mode   = (ns.HudState and ns.HudState.aoe) and "aoe" or "st",
    -- RAW CDM view (retained, additive) — statelog / probe / Hud2Log short-codes / cdmp.py.
    cooldowns = cooldowns,
    -- DOMAIN view (the re-layer) — the pipeline's input; the Coach decides on THIS.
    abilities = abilities,
    buffs     = buffs,
    resources = resources,
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
-- Returns (hash, procOn): a cheap change signature plus the count of active proc
-- signals (glow highlights + readable auras), so the poll can label a proc distinctly.
local function signature()
  local h = InCombatLockdown() and 1 or 0
  local procOn = 0
  for cooldownID in pairs(enumerate()) do
    local info = cooldownInfo(cooldownID)
    local base = info and readable(info.spellID) and info.spellID or nil
    local live = liveSpellID(info) or base
    local isReady, remaining = ns.ReadCooldown(live)
    local cdbit = (isReady == nil) and 0 or (isReady and 1 or 2)
    local rem = (type(remaining) == "number") and math.floor(remaining) or 0
    local ov = readable(St.override[base]) and St.override[base] or 0
    -- glow is the combat-readable proc signal, so fold it in AND count it as a proc.
    local g = readGlow(live)
    local glowbit = (g.readable and g.active) and 1 or 0
    if glowbit == 1 then procOn = procOn + 1 end
    -- Mix cooldownID + facts into the hash (mod keeps it a Lua number, not a string).
    h = (h * 131 + cooldownID + cdbit * 7 + rem * 13 + ov + glowbit * 11) % 2147483647
  end
  -- Fold every readable power into the hash so a shard step is a 'change' — spec-
  -- agnostically, mixing whatever powers the character has (no opinion on which).
  for value in pairs(POWER_NAME) do
    local okV, val = pcall(UnitPower, "player", value)
    if okV and type(val) == "number" and not ns.IsSecret(val) then
      h = (h * 131 + value * 17 + val) % 2147483647
    end
  end
  -- Fold the active-buff set in so an OOC proc is a 'change' too, and count them.
  -- Same-membership -> same pairs order -> same hash.
  local _, activeByID = scanActiveAuras()
  for id in pairs(activeByID) do
    procOn = procOn + 1
    h = (h * 131 + id) % 2147483647
  end
  return h, procOn
end

local pollTicker
local lastSig = nil
local lastProcOn = 0
local lastSample = 0

local function poll()
  if not St.recording then return end
  local now = GetTime()
  local due = captureReason
  local sig, procOn = signature()
  if not due then
    if sig ~= lastSig then
      -- an aura coming UP is a proc — a distinct, protected moment in the ring
      due = (procOn > lastProcOn) and "proc" or "change"
    elseif (now - lastSample) >= OOC_SAMPLE and not InCombatLockdown() then
      due = "sample"
    end
  end
  lastSig, lastProcOn = sig, procOn   -- resync so an owed event isn't re-detected
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
  wipe(history)
  wipe(cdPrevState)
  wipe(cdChangedAt)
  wipe(cdBaseline)
  wipe(readyEdge)
  wipe(foldBase)
  captureReason = nil
  lastSig = nil
  lastSample = 0
end

--------------------------------------------------------------------------------
-- Lifecycle — ingestion (ref-counted) vs statelog recording (W4 P5c)
--------------------------------------------------------------------------------
-- TWO separable things share this file: EVENT INGESTION (the override/history/combat
-- tracking + the napkin/keybind inputs a good pulse needs) and STATELOG RECORDING (the
-- poll ticker writing the disk ring).  The statelog session needs both; the LIVE DRIVER
-- (HudDriver, /cdmp hud2) needs ingestion but NOT the disk ring.  So ingestion is
-- REF-COUNTED — each consumer Acquire()s / Release()s, and the eframe events run while
-- any consumer holds a ref — and recording is its own flag on top.  This is the
-- "expose the pulse to a driver" seam the cutover plan asks for: State.Build + a clean
-- way to keep ingestion live without forcing disk churn.
St.consumers = 0                -- live consumers of event ingestion (statelog + driver)
St.recording = false           -- is the statelog poll writing the disk ring?

function St.Acquire()
  St.consumers = St.consumers + 1
  if St.consumers > 1 then return end   -- already ingesting
  wipe(St.override)
  -- State CONSULTS the napkin and keybind cache as inputs, so it owns making them
  -- live for a session — otherwise, with the HUD off, both are dormant and every cd
  -- reads source="none" while every keybind is nil (the v0.29.0 gap: the napkin's
  -- SUCCEEDED frame and the bar scan are only started by the HUD).  Both Start()s are
  -- idempotent, so this is harmless when the old HUD is also running.
  if ns.HudNapkin and ns.HudNapkin.Start then pcall(ns.HudNapkin.Start) end
  if ns.HudBinds and ns.HudBinds.Start then pcall(ns.HudBinds.Start) end
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
end

function St.Release()
  if St.consumers <= 0 then return end
  St.consumers = St.consumers - 1
  if St.consumers == 0 then eframe:UnregisterAllEvents() end
end

function St.Start()
  if St.recording then return end
  St.recording = true
  St.Acquire()
  if not pollTicker then pollTicker = C_Timer.NewTicker(POLL_PERIOD, poll) end
  -- Seed the ring with an immediate first pulse so a session that is captured OOC
  -- and then /reload'd has at least one recorded moment even if nothing changed.
  St.Capture("start")
end

function St.Stop()
  if not St.recording then return end
  St.recording = false
  if pollTicker then pollTicker:Cancel(); pollTicker = nil end
  St.Release()
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
    St.recording and "|cff88ff88recording|r" or "|cff808080idle|r", n, total)
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
    if not St.recording then
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
