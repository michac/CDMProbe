-- DecisionLog.lua — the pipeline DECISION LOG.  A greppable pipeline trace.
--
-- WHY THIS EXISTS.  The Coach (flat priority-list APL) can sit showing NO recommendation
-- in a state where it should call one (e.g. "build / pool shards").  A winner that
-- resolves to a spell with no cooldown is not in the Cooldown Manager's tracked set, so
-- the Binder DROPS the cue and nothing draws — but the interesting states fly by
-- mid-combat and `/cdmp hud status` only reports the LAST tick, so which failure mode it
-- is can't be confirmed from chat alone.
--
-- The fix is an INSTRUMENT, not a UI: each time the pipeline's decision CHANGES, append
-- ONE greppable line capturing State -> Coach(Guidance) -> Binder(DrawList), including
-- whether a Coach cue was DROPPED by the Binder (no icon, `×`) or the Coach produced NO
-- winner (`w:-`).  The log gets big; grep/awk sorts it out later.  It persists via
-- CDMProbeDB (flushed on /reload), and `wowkb.cdmp decisionlog` extracts it to a flat .log.
--
-- (The name is a fossil-free rename of the old `Hud2Log` — the `2` was left over from the
-- retired `/cdmp hud2` HUD alias and never meant anything here.  Multi-spec Phase 4.)
--
-- THE SPLIT is the whole design:
--   * Render(pulse, guidance, drawList) -> string is PURE — no frames, no db, no clock.
--     Builds the `S{…} G{…} B{…}` content.  This is the busted-testable core.
--   * Record(...) is the stateful wrapper — lazy session, the change-only dedup, the
--     ring trim, the clock/date/version.  Kept OUT of Render so the tests need no
--     `date`/`ns.version` (mock_ns provides neither).
--
-- SPEC-PARAMETERIZED (multi-spec Phase 4).  The log holds NO spell constants of its own:
-- per-ability short codes ride `abbr` on each ns.SpecInfo(id) entry, and the non-per-
-- ability vocabulary (CD/PR render order, proc buff codes, the armed-Art id set, the
-- core-glow id) is read off ns.ActiveSpec.log.  Demo renders byte-identical lines; a
-- second spec supplies its own `abbr`s + `log` table and this module is untouched.
--
-- DETERMINISM is load-bearing for the change-only dedup.  `guidance.cues` and
-- `pulse.abilities`/`.buffs` are MAPS; `pairs()` order is unstable.  Every map-derived
-- list here is emitted in a FIXED order (CD/PR render orders, ability bases sorted, the
-- rest sorted), so two ticks with the identical decision render the identical string and
-- the dedup holds.
--
-- SECRETS.  In combat `power.SoulShards.value`, `remaining`, `liveSpellID` etc. can be
-- the sentinel string "<secret>".  Every numeric read is `num()`-guarded and every
-- id->code lookup floors to "?" so a "<secret>" never reaches a `%d` slot.
local ADDON, ns = ...

ns.DecisionLog = {}
local DL = ns.DecisionLog

local CAP     = 5000     -- entries kept per session ("let it get big")
local SESSIONS = 3       -- sessions kept on disk

-- Guidance emphasis -> compact Binder token.  Generic (spec-agnostic), so it stays a
-- shell local rather than moving to the per-spec log vocabulary.
local EMPH = { ROTATION = "ROT", LATE = "LATE", ROTATION_FALLBACK = "RFB", SOON = "SOON" }

--------------------------------------------------------------------------------
-- Small guards
--------------------------------------------------------------------------------
local function num(v) return (type(v) == "number") and v or nil end

-- ns.SpecInfo is nil-safe/secret-safe; the NEUTRAL fallback carries no abbr/label, so
-- both readers below just return nil for an unknown/secret id.
local function abbrOf(id)
  if type(id) ~= "number" then return nil end
  local info = ns.SpecInfo and ns.SpecInfo(id)
  return info and info.abbr
end

local function labelOf(id)
  if type(id) ~= "number" then return nil end
  local info = ns.SpecInfo and ns.SpecInfo(id)
  return info and info.label
end

-- id -> short code.  live wins over base (a transformed button is what it BECAME); floor
-- to "?" so a "<secret>" or unknown never lands in a format slot as nil.
local function shortOf(live, base)
  return abbrOf(live) or abbrOf(base)
      or labelOf(live) or labelOf(base)
      or (type(base) == "number" and tostring(base))
      or (type(live) == "number" and tostring(live))
      or "?"
end

-- Notes go inline in a space-delimited line with no quotes: strip colour codes + quotes +
-- the field-delimiter chars, collapse whitespace to `_`.
local function clean(s)
  if type(s) ~= "string" then return "" end
  s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  s = s:gsub('"', ""):gsub("[{}|]", "")
  s = s:gsub("%s+", "_")
  return s
end

-- cd sub-table -> readiness token.  R ready · P probably-up (napkin elapsed, rem≤0) ·
-- c<sec> counting down · ? unknown/untracked.  A non-numeric (secret) remaining on
-- cooldown reads P (on cd, duration unconfirmed) rather than leaking the sentinel.
local function readiness(cd)
  if type(cd) ~= "table" then return "?" end
  local st = cd.state
  if st == "ready" then return "R" end
  if st == "on-cooldown" then
    local rem = num(cd.remaining)
    if rem and rem > 0 then return "c" .. tostring(math.floor(rem)) end
    return "P"
  end
  return "?"
end

--------------------------------------------------------------------------------
-- Render — PURE.  pulse/guidance/drawList in, the `S{…} G{…} B{…}` string out.
--------------------------------------------------------------------------------
function DL.Render(pulse, guidance, drawList)
  pulse = pulse or {}
  guidance = guidance or {}
  drawList = drawList or {}
  -- The per-spec log vocabulary (CD/PR render order, proc codes, armed-Art set, core-glow
  -- id).  Read off the active spec; empty-table fallback keeps Render total pre-activation.
  local L = (ns.ActiveSpec and ns.ActiveSpec.log) or {}
  -- THE DOMAIN VIEW is the Coach's decision surface, so the log encodes THAT (the
  -- re-layer): `abilities` (spellID-keyed, folded) / `buffs`, NOT the raw cooldownID-keyed
  -- `cooldowns`.  If the log didn't encode the Coach's real input it couldn't explain the
  -- Coach's decision.
  local abilities = pulse.abilities or {}
  local buffs = pulse.buffs or {}

  -- spellID -> code, live-over-base (a transformed button shows what it BECAME).
  local function codeForSpell(spellID)
    local ab = abilities[spellID]
    return shortOf(ab and ab.liveSpellID, spellID)
  end

  -- Stable base walk (map order is unstable) — first-by-sorted-base wins per code.
  local bases = {}
  for base in pairs(abilities) do bases[#bases + 1] = base end
  table.sort(bases)

  -- S — CD readiness (the full ranked set, folded) · PR procs/buffs · PW shards · CS cast.
  local rdy, prSet = {}, {}
  local artArmed = L.artArmed or {}
  for _, base in ipairs(bases) do
    local ab = abilities[base]
    local code = abbrOf(base)         -- base lookup: HoG stays HoG, one D (already folded)
    if code and rdy[code] == nil then rdy[code] = readiness(ab.cd) end
    -- the armed Demonic Art is a TRANSFORM (an ability's live override), not an aura
    if artArmed[ab.liveSpellID] then
      local c = abbrOf(ab.liveSpellID)
      if c then prSet[c] = true end
    end
  end
  -- The core-proc button's glow = the combat-readable core proc even when the aura reads
  -- secret (Demonbolt for Demo).
  local coreGlowID = L.coreGlowID
  local dbAb = coreGlowID and abilities[coreGlowID]
  if dbAb and dbAb.glow and dbAb.glow.active == true then prSet.core = true end
  -- procs/auras PRESENT, straight off the domain view's `buffs` set (spellID-keyed).
  local procBuffs = L.procBuffs or {}
  for sid in pairs(buffs) do
    local code = procBuffs[sid]
    if code then prSet[code] = true end
  end

  local cdParts = {}
  for _, code in ipairs(L.cdOrder or {}) do
    if rdy[code] then cdParts[#cdParts + 1] = code .. "=" .. rdy[code] end
  end
  local cdStr = (#cdParts > 0) and table.concat(cdParts, " ") or "-"

  local prParts = {}
  for _, k in ipairs(L.procOrder or {}) do if prSet[k] then prParts[#prParts + 1] = k end end
  local prStr = (#prParts > 0) and table.concat(prParts, ",") or "-"

  -- PW — the power bar the HUD renders.  Read the FIRST `incoming` power off the active
  -- spec's power array (Demo -> power.SoulShards); no `resources.shards` alias anymore.
  local ss = {}
  for _, p in ipairs((ns.ActiveSpec and ns.ActiveSpec.powers) or {}) do
    if p.incoming then ss = (pulse.power and pulse.power[p.name]) or {}; break end
  end
  local val, inc = num(ss.value), num(ss.incoming)
  local pwStr = (val and string.format("%d", math.floor(val)) or "?")
    .. "/" .. (inc and string.format("%+d", inc) or "?")

  -- In-flight cast: the NEWEST phase=="start" in history with no later succeeded/stopped
  -- across ALL bases (the prose rule; Coach.castingFresh is per-base, a different Q).
  local hist = pulse.history or {}
  local lastStart, lastStartIdx
  for i = 1, #hist do
    if hist[i].phase == "start" then lastStart, lastStartIdx = hist[i], i end
  end
  local csStr = "-"
  if lastStart then
    local terminated = false
    for j = lastStartIdx + 1, #hist do
      local ph = hist[j].phase
      if ph == "succeeded" or ph == "stopped" then terminated = true; break end
    end
    if not terminated then csStr = shortOf(lastStart.spellID, lastStart.base) end
  end

  -- DR — what State's domain-view filter REMOVED this pulse and why (field-fix A):
  -- `SF:unlearned`, `Inc:no-icon`.  The filter's whole job is deleting rows, so it must
  -- never delete one QUIETLY — a wrong signal that drops a real button has to be visible in
  -- the trace, not merely absent from it.  Stable across ticks, so the change-only dedup
  -- keeps it to one line, not one per pulse.
  local drList = {}
  for base, why in pairs(pulse.dropped or {}) do
    drList[#drList + 1] = (abbrOf(base) or tostring(base)) .. ":" .. tostring(why)
  end
  table.sort(drList)
  local drStr = (#drList > 0) and table.concat(drList, ",") or "-"

  -- G — Coach output by emphasis.  Cues keyed by BASE spellID (the re-layer).  ROTATION/
  -- LATE = winner (w:/w!), else w:- (the nil-winner smoking gun); ROTATION_FALLBACK = fb;
  -- SOON = a sorted list.
  local cues = guidance.cues or {}
  local wCode, wLate, wNote, fbCode
  local soon = {}
  for spellID, cue in pairs(cues) do
    local emph = cue.emphasis
    if emph == "ROTATION" or emph == "LATE" then
      wCode, wLate, wNote = codeForSpell(spellID), (emph == "LATE"), cue.note
    elseif emph == "ROTATION_FALLBACK" then
      fbCode = codeForSpell(spellID)
    elseif emph == "SOON" then
      soon[#soon + 1] = codeForSpell(spellID)
    end
  end
  local gParts = {}
  if wCode then
    local w = (wLate and "w!" or "w:") .. wCode
    local note = clean(wNote)
    if note ~= "" then w = w .. ":" .. note end
    gParts[#gParts + 1] = w
  else
    gParts[#gParts + 1] = "w:-"
  end
  if fbCode then gParts[#gParts + 1] = "fb:" .. fbCode end
  if #soon > 0 then
    table.sort(soon)
    gParts[#gParts + 1] = "soon:" .. table.concat(soon, ",")
  end
  local gStr = table.concat(gParts, " ")

  -- B — the Binder's fate of each guidance cue, across the spellID -> cid seam.  A cue is
  -- "drawn" iff a DrawList cue anchors to the ability's display cooldownID (abilities[
  -- spellID].display.cooldownID); `×` when not — "Coach said press it, Binder couldn't
  -- draw it".  Same signal, now honest across the re-key (and expected to go QUIET for the
  -- summons — the regression check).  Sorted by the rendered token for determinism.
  local anchored = {}
  for _, c in ipairs(drawList.cues or {}) do
    if c.anchorTo ~= nil then anchored[c.anchorTo] = true end
  end
  local bList = {}
  for spellID, cue in pairs(cues) do
    local tok = EMPH[cue.emphasis] or tostring(cue.emphasis)
    local ab = abilities[spellID]
    local displayCid = ab and ab.display and ab.display.cooldownID
    local drawn = (displayCid ~= nil) and anchored[displayCid]
    bList[#bList + 1] = codeForSpell(spellID) .. ":" .. tok .. (drawn and "" or "×")
  end
  table.sort(bList)
  local bStr = (#bList > 0) and table.concat(bList, " ") or "-"

  return string.format("S{CD:%s | PR:%s | PW:%s | CS:%s | DR:%s} G{%s} B{%s}",
    cdStr, prStr, pwStr, csStr, drStr, gStr, bStr)
end

--------------------------------------------------------------------------------
-- Record — the stateful wrapper (session push, change-only dedup, the ring).
--------------------------------------------------------------------------------
-- The rotation short-codes present in the pulse — captured on the session's FIRST Record,
-- so the header answers "is SB tracked?" without reading a single entry.  Only ids that
-- carry an `abbr` (the rotation set), so the list stays clean.
local function trackedCodes(pulse)
  -- From the domain view's `abilities` (spellID-keyed, folded), so the header answers
  -- "is SB tracked?" over the Coach's actual ability set, one code per ability.
  local abilities = (pulse and pulse.abilities) or {}
  local set = {}
  for base, ab in pairs(abilities) do
    local code = abbrOf(ab.liveSpellID) or abbrOf(base)
    if code then set[code] = true end
  end
  local list = {}
  for code in pairs(set) do list[#list + 1] = code end
  table.sort(list)
  return table.concat(list, ",")
end

DL.session     = nil   -- in-memory handle; nil ⇒ first Record of this load starts a session
DL.t0          = nil
DL.lastContent = nil

function DL.Record(pulse, guidance, drawList)
  if not ns.db then return end   -- pre-ADDON_LOADED; nothing to persist to

  -- Lazy session: push a fresh header the first time we run after a load.
  if DL.session == nil then
    local log = ns.db.decisionlog
    if type(log) ~= "table" then log = {}; ns.db.decisionlog = log end
    local sess = {
      started = date("%Y-%m-%d %H:%M:%S"),
      version = ns.version,
      tracked = trackedCodes(pulse),
      entries = {},
    }
    log[#log + 1] = sess
    while #log > SESSIONS do table.remove(log, 1) end
    DL.session, DL.t0, DL.lastContent = sess, GetTime(), nil
  end

  -- Change-only: skip a tick whose whole decision is byte-identical to the last logged.
  local content = DL.Render(pulse, guidance, drawList)
  if content == DL.lastContent then return end
  DL.lastContent = content

  local entries = DL.session.entries
  entries[#entries + 1] = string.format("t%.1f %s", GetTime() - DL.t0, content)
  while #entries > CAP do table.remove(entries, 1) end
end
