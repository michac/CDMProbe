-- Hud2Log.lua — the HUD2 DECISION LOG.  A greppable pipeline trace.
--
-- WHY THIS EXISTS.  The W4 Phase-8 Coach (flat priority-list APL) runs live behind
-- `/cdmp hud2`, and in-game it can sit showing NO recommendation in a state where it
-- should call one (e.g. "build / pool shards").  The leading hypothesis is that the
-- winner resolves to Shadow Bolt, which has no cooldown, so it is not in the Cooldown
-- Manager's tracked set (`cidByBase[686]` is nil) and the Binder DROPS the cue — nothing
-- draws.  But the interesting states fly by mid-combat and `/cdmp hud2 status` only
-- reports the LAST tick, so which of several failure modes it is can't be confirmed.
--
-- The fix is an INSTRUMENT, not a UI: each time the pipeline's decision CHANGES, append
-- ONE greppable line capturing State -> Coach(Guidance) -> Binder(DrawList), including
-- whether a Coach cue was DROPPED by the Binder (no icon, `×`) or the Coach produced NO
-- winner (`w:-`).  The log gets big; grep/awk sorts it out later.  It persists via
-- CDMProbeDB (flushed on /reload), and `wowkb.cdmp hud2log` extracts it to a flat .log.
--
-- THE SPLIT is the whole design (mirrors HudLog's Render/Record intent):
--   * Render(pulse, guidance, drawList) -> string is PURE — no frames, no db, no clock.
--     Builds the `S{…} G{…} B{…}` content.  This is the busted-testable core.
--   * Record(...) is the stateful wrapper — lazy session, the change-only dedup, the
--     ring trim, the clock/date/version.  Kept OUT of Render so the tests need no
--     `date`/`ns.version` (mock_ns provides neither).
--
-- DETERMINISM is load-bearing for the change-only dedup.  `guidance.cues` and
-- `pulse.cooldowns` are MAPS; `pairs()` order is unstable.  Every map-derived list here
-- is emitted in a FIXED order (the summon order for CD/PR, sorted for the rest), so two
-- ticks with the identical decision render the identical string and the dedup holds.
--
-- SECRETS.  In combat `power.SoulShards.value`, `remaining`, `liveSpellID` etc. can be
-- the sentinel string "<secret>".  Every numeric read is `num()`-guarded and every
-- id->code lookup floors to "?" so a "<secret>" never reaches a `%d` slot.
local ADDON, ns = ...

ns.Hud2Log = {}
local L2 = ns.Hud2Log

local CAP     = 5000     -- entries kept per session ("let it get big")
local SESSIONS = 3       -- sessions kept on disk

-- Short codes keyed by spellID.  No existing abbr field exists (ns.Spec[id].label is the
-- only name); this is the greppable stand-in.  Base ids from ns.SpecIDs + the Art
-- override ids (both the confirmed and the alt/unconfirmed pair, which cost nothing).
local SHORT = {
  [265187] = "T",  [104316] = "D",  [196277] = "I",
  [1276452] = "G", [1276467] = "G", [136726] = "G",
  [105174] = "HoG", [264178] = "DB", [686] = "SB",
  [434506] = "IB", [433891] = "IB", [434635] = "RU", [434636] = "RU",
}
-- The armed-Demonic-Art override ids (live id ∈ this set ⇒ the transform is up).
local ART = { [434506] = true, [433891] = true, [434635] = true, [434636] = true }
local DEMONIC_CORE = 264173   -- buff isActive ⇒ core proc
local DEMONBOLT    = 264178   -- glow.active   ⇒ core proc (the empowered button)

-- The CD group is EXACTLY the summon / on-cd set — the cooldowns whose readiness drives
-- the list.  Fillers/spenders (SB/HoG/DB) don't get a CD token; their state shows via
-- PW/PR/CS.  Fixed render order (deterministic + matches the header example T D I G).
local SUMMON_ORDER = { "T", "D", "I", "G" }
local SUMMON_SET   = { T = true, D = true, I = true, G = true }
-- PR render order (deterministic).  Only one Art is ever up, so core-then-Art suffices.
local PR_ORDER = { "core", "IB", "RU" }
-- Guidance emphasis -> compact Binder token.
local EMPH = { ROTATION = "ROT", LATE = "LATE", ROTATION_FALLBACK = "RFB", SOON = "SOON" }

--------------------------------------------------------------------------------
-- Small guards
--------------------------------------------------------------------------------
local function num(v) return (type(v) == "number") and v or nil end

-- ns.SpecInfo is nil-safe/secret-safe, but the NEUTRAL fallback has NO label, so guard.
local function labelOf(id)
  if type(id) ~= "number" then return nil end
  local info = ns.SpecInfo and ns.SpecInfo(id)
  return info and info.label
end

-- id -> short code.  live wins over base (a transformed button is what it BECAME); floor
-- to "?" so a "<secret>" or unknown never lands in a format slot as nil.
local function shortOf(live, base)
  return SHORT[live] or SHORT[base]
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
function L2.Render(pulse, guidance, drawList)
  pulse = pulse or {}
  guidance = guidance or {}
  drawList = drawList or {}
  local cds = pulse.cooldowns or {}

  -- cid -> code, resolved once against the pulse (guidance keys cues by cooldownID).
  local function codeForCid(cid)
    local cd = cds[cid]
    return shortOf(cd and cd.liveSpellID, cd and cd.spellID)
  end

  -- Stable cid walk (map order is unstable) — first-by-sorted-cid wins per code.
  local cids = {}
  for cid in pairs(cds) do cids[#cids + 1] = cid end
  table.sort(cids, function(a, b) return tostring(a) < tostring(b) end)

  -- S — CD readiness (summon set) · PR procs · PW shards · CS in-flight cast.
  local cdTok, prSet = {}, {}
  for _, cid in ipairs(cids) do
    local cd = cds[cid]
    local live, base = cd and cd.liveSpellID, cd and cd.spellID
    local code = shortOf(live, base)
    if SUMMON_SET[code] and cdTok[code] == nil then
      cdTok[code] = readiness(cd and cd.cd)
    end
    if base == DEMONIC_CORE and cd.buff and cd.buff.isActive == true then prSet.core = true end
    if base == DEMONBOLT and cd.glow and cd.glow.active == true then prSet.core = true end
    if ART[live] then prSet[SHORT[live]] = true end
  end

  local cdParts = {}
  for _, code in ipairs(SUMMON_ORDER) do
    if cdTok[code] then cdParts[#cdParts + 1] = code .. "=" .. cdTok[code] end
  end
  local cdStr = (#cdParts > 0) and table.concat(cdParts, " ") or "-"

  local prParts = {}
  for _, k in ipairs(PR_ORDER) do if prSet[k] then prParts[#prParts + 1] = k end end
  local prStr = (#prParts > 0) and table.concat(prParts, ",") or "-"

  local ss = (pulse.power and pulse.power.SoulShards) or {}
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

  -- G — Coach output by emphasis.  ROTATION/LATE = winner (w:/w!), else w:- (the nil-
  -- winner smoking gun); ROTATION_FALLBACK = fb; SOON = a sorted list.
  local cues = guidance.cues or {}
  local wCode, wLate, wNote, fbCode
  local soon = {}
  for cid, cue in pairs(cues) do
    local emph = cue.emphasis
    if emph == "ROTATION" or emph == "LATE" then
      wCode, wLate, wNote = codeForCid(cid), (emph == "LATE"), cue.note
    elseif emph == "ROTATION_FALLBACK" then
      fbCode = codeForCid(cid)
    elseif emph == "SOON" then
      soon[#soon + 1] = codeForCid(cid)
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

  -- B — the Binder's fate of each guidance cue.  `×` when no DrawList cue anchors to that
  -- cooldownID (the Binder drops layout-absent cues) — "Coach said press it, Binder
  -- couldn't draw it".  Sorted by the rendered token for determinism.
  local anchored = {}
  for _, c in ipairs(drawList.cues or {}) do
    if c.anchorTo ~= nil then anchored[c.anchorTo] = true end
  end
  local bList = {}
  for cid, cue in pairs(cues) do
    local tok = EMPH[cue.emphasis] or tostring(cue.emphasis)
    local dropped = not anchored[cid]
    bList[#bList + 1] = codeForCid(cid) .. ":" .. tok .. (dropped and "×" or "")
  end
  table.sort(bList)
  local bStr = (#bList > 0) and table.concat(bList, " ") or "-"

  return string.format("S{CD:%s | PR:%s | PW:%s | CS:%s} G{%s} B{%s}",
    cdStr, prStr, pwStr, csStr, gStr, bStr)
end

--------------------------------------------------------------------------------
-- Record — the stateful wrapper (session push, change-only dedup, the ring).
--------------------------------------------------------------------------------
-- The rotation short-codes present in the pulse — captured on the session's FIRST Record,
-- so the header answers "is SB tracked?" without reading a single entry.  Only ids the
-- SHORT map knows (the rotation set), so the list stays clean.
local function trackedCodes(pulse)
  local cds = (pulse and pulse.cooldowns) or {}
  local set = {}
  for _, cd in pairs(cds) do
    local code = SHORT[cd.liveSpellID] or SHORT[cd.spellID]
    if code then set[code] = true end
  end
  local list = {}
  for code in pairs(set) do list[#list + 1] = code end
  table.sort(list)
  return table.concat(list, ",")
end

L2.session     = nil   -- in-memory handle; nil ⇒ first Record of this load starts a session
L2.t0          = nil
L2.lastContent = nil

function L2.Record(pulse, guidance, drawList)
  if not ns.db then return end   -- pre-ADDON_LOADED; nothing to persist to

  -- Lazy session: push a fresh header the first time we run after a load.
  if L2.session == nil then
    local log = ns.db.hud2log
    if type(log) ~= "table" then log = {}; ns.db.hud2log = log end
    local sess = {
      started = date("%Y-%m-%d %H:%M:%S"),
      version = ns.version,
      tracked = trackedCodes(pulse),
      entries = {},
    }
    log[#log + 1] = sess
    while #log > SESSIONS do table.remove(log, 1) end
    L2.session, L2.t0, L2.lastContent = sess, GetTime(), nil
  end

  -- Change-only: skip a tick whose whole decision is byte-identical to the last logged.
  local content = L2.Render(pulse, guidance, drawList)
  if content == L2.lastContent then return end
  L2.lastContent = content

  local entries = L2.session.entries
  entries[#entries + 1] = string.format("t%.1f %s", GetTime() - L2.t0, content)
  while #entries > CAP do table.remove(entries, 1) end
end
