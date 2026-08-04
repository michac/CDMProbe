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
-- W4-era second HUD, retired at the cutover, and never meant anything here.
-- Multi-spec Phase 4.)
--
-- THE SPLIT is the whole design:
--   * Render(pulse, guidance, drawList) -> string is PURE — no frames, no db, no clock.
--     Builds the `S{…} G{…} B{…}` content.  This is the busted-testable core.
--   * Record(...) is the stateful wrapper — lazy session, the change-only dedup, the
--     ring trim, the clock/date/version, and the EDGE MARKERS (`# combat`, `# config`).
--     The split still earns its place: Render stays pure and is the bulk of the test
--     surface.  ⚠ But Record is no longer untested — the combat marker carries a rule
--     ("stamped ABOVE the dedup") that a refactor could silently break, so
--     decisionlog_spec drives it through a `date` fake and a table for `ns.db`.
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
-- Sessions kept on disk.  A "session" is ONE ADDON LOAD (see Record's lazy header), so
-- every `/reload` burns a slot — and a verification pass that respecs between hero trees
-- and specs reloads 4-5 times.  At 3 the earliest pull silently rolled off before it could
-- be extracted, which is a data-loss trap in exactly the sessions that matter most.
local SESSIONS = 6       -- sessions kept on disk

-- Guidance emphasis -> compact Binder token.  Generic (spec-agnostic), so it stays a
-- shell local rather than moving to the per-spec log vocabulary.
-- ⚠ `RFB` NOW MEANS "the NEXT press", not "the runner-up" (2026-08-03) — the token kept its
-- name so a capture stays greppable across the change; guidance-contract.json carries the
-- ruling.  A repeat of the WINNER emits no RFB at all: it rides the winner's cue as
-- `next`, and the log renders that as a trailing `+1` on the `w:` field.
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

  -- PW — the power bar the HUD renders, read off the GUIDANCE the Coach emitted, which is
  -- the ONE place both halves of the string live: resourceBars[] carries `value` AND
  -- `incoming` (guidance-contract.json -> channels/resourceBars).  Before Phase 6 this
  -- walked ns.ActiveSpec.powers and read `pulse.power[…].incoming` straight off the pulse;
  -- State no longer writes that field — the Coach derives the projection from the pulse's
  -- cast history — so reading the pulse here would render a permanent `+0`.
  -- The first bar is the spec's primary meter (Demo/Destro: Soul Shards).  ⚠ A PASSIVE spec
  -- emits none (EmptyGuidance -> resourceBars = {}), so it renders `?/?` rather than reading
  -- through to the pulse.  That is more honest, not less: there is no bar.
  --
  -- ⚠ THE EXACT RAIL WINS WHEN IT IS THERE (Phase 6.2).  `valueExact`/`incomingExact` are
  -- integers in the game's internal units (Soul Shards: 0–50 fragments) with `modifier`
  -- relating them to the display units, so dividing HERE — at the very edge, in a string —
  -- is what turns `18` into the `1.8` a human reads, without any float ever reaching a gate.
  -- Falls back to the whole-unit integers when the client refused the exact read; an
  -- all-integer `PW:` column in a capture therefore means the exact read is not wired
  -- (State step 1) or not being passed through (Coach:ResourceBars), which is precisely the
  -- signal the in-flight verification of this phase looks for.
  --
  -- ⚠⚠ AND IT MUST NEVER PRINT A NUMBER THAT IS NOT A MEASUREMENT (2026-08-03).  The Havoc
  -- flight rendered `PW:0/+0` on all 2380 lines while Fury was in fact UNREADABLE, because
  -- `Coach:ResourceBars` coerced an absent value to zero — so the one instrument that could
  -- have named the problem instead corroborated the wrong answer.  A future reader seeing
  -- `PW:0` has to be able to trust that it means ZERO.
  --   `restricted`  the rail is STRUCTURALLY unreadable — a PRIMARY resource, secret
  --                 forever (State asks C_Secrets.ShouldUnitPowerBeSecret).  Not a
  --                 transient miss; nothing will ever fill this column in.
  --   `?`           we came away with nothing this pulse, reason unknown — the pre-existing
  --                 honest blank, which also covers a PASSIVE spec's absent bar.
  local bar = (guidance.resourceBars or {})[1] or {}
  local mod = num(bar.modifier)
  local xVal, xInc = num(bar.valueExact), num(bar.incomingExact)
  local pwStr
  if bar.restricted == true then
    pwStr = "restricted"
  elseif mod and mod > 1 and xVal then
    pwStr = string.format("%.1f", xVal / mod)
      .. "/" .. (xInc and string.format("%+.1f", xInc / mod) or "?")
  else
    local val, inc = num(bar.value), num(bar.incoming)
    pwStr = (val and string.format("%d", math.floor(val)) or "?")
      .. "/" .. (inc and string.format("%+d", math.floor(inc)) or "?")
  end

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

  -- CH — the charge count for every ability that HAS a charge pool, `Conf=1/2` (an exact
  -- read) or `Conf~1/2` (the napkin estimate).  Added after the first live pass, where the
  -- HUD recommended Conflagrate at zero charges and the log could not show it: every line
  -- said `Conf=R`, because for a charged ability the CDM raises `Available` per charge and
  -- never raises `OnCooldown`.  A decision input the trace cannot see is a defect waiting to
  -- be un-diagnosable.
  local chList = {}
  for _, base in ipairs(bases) do
    local ch = abilities[base].charge
    if ch and ch.charged then
      local code = abbrOf(base) or tostring(base)
      local cur, mx = num(ch.cur), num(ch.max)
      chList[#chList + 1] = code .. (ch.source == "napkin" and "~" or "=")
        .. (cur and tostring(cur) or "?") .. "/" .. (mx and tostring(mx) or "?")
    end
  end
  table.sort(chList)
  local chStr = (#chList > 0) and table.concat(chList, ",") or "-"

  -- DR — the declared abilities State will NOT let the Coach pick, and why:
  -- `SF:unlearned`, `HoW:unknown`.  ⚠ RE-SOURCED, NOT DELETED (roster-state-plan Phase 5
  -- §C6).  It used to read `pulse.dropped`, the field-fix-A record of what the domain-view
  -- FILTER removed; Phase 5 retired that filter — knownness marks the row instead of
  -- deleting it — but the visibility it bought is the whole reason the Soul Fire bug was
  -- findable, and §8 is explicit that dropping it without a replacement trades a loud
  -- failure for a quiet one.  So the same column now reads the three-valued `known` off the
  -- rows themselves, which is strictly MORE than before: `dropped` could only ever name an
  -- ability that would have been a press, while this names every declared one.
  --
  -- ⚠ AND IT SAYS SO WHEN THE WHOLE CHANNEL REFUSED.  `knownReadable == false` is the
  -- wholesale guard firing — not one ability answered — which the Coach responds to by
  -- ignoring knownness altogether.  That is exactly the state a reader must not mistake for
  -- "everything is fine": it renders as `!refused`.
  local drStr
  if pulse.knownReadable == false then
    drStr = "!refused"
  else
    local drList = {}
    for base, ab in pairs(pulse.abilities or {}) do
      local k = ab.known
      if k == false or k == "unknown" then
        drList[#drList + 1] = (abbrOf(base) or tostring(base))
          .. ":" .. (k == false and "unlearned" or "unknown")
      end
    end
    table.sort(drList)
    drStr = (#drList > 0) and table.concat(drList, ",") or "-"
  end

  -- G — Coach output by emphasis.  Cues keyed by BASE spellID (the re-layer).  ROTATION/
  -- LATE = winner (w:/w!), else w:- (the nil-winner smoking gun); ROTATION_FALLBACK = fb;
  -- SOON = a sorted list.
  local cues = guidance.cues or {}
  local wCode, wLate, wNote, fbCode
  local wRepeat = false
  local soon = {}
  for spellID, cue in pairs(cues) do
    local emph = cue.emphasis
    if emph == "ROTATION" or emph == "LATE" then
      wCode, wLate, wNote = codeForSpell(spellID), (emph == "LATE"), cue.note
      -- THE LOOK-AHEAD LANDED BACK ON THE WINNER (2026-08-03).  There is no RFB cue in this
      -- case — the repeat rides the winner — so without this the log would be silent about
      -- a decision the screen is making, which is exactly what the `DR:` field exists to
      -- stop happening elsewhere.
      wRepeat = (cue.next == true)
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
    -- `+1` = "and again next GCD".  A trailing marker rather than a field of its own, so
    -- every existing `w:` grep keeps matching.
    if wRepeat then w = w .. "+1" end
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

  -- DOT — BOTH of the DoT's observation channels, side by side, as `<code>=<frame>/<edge>`.
  --
  -- The edge half arrived 2026-07-30 because a `w:Wth:pandemic_refresh` in the field could
  -- not be diagnosed from this trace at all: the latch was the sole input to L8's refresh
  -- half and the one thing the log did not render, so "the HUD says refresh and the DoT has
  -- 17s left" had no evidence either way.  `pandemic@4.2` reads "the pandemic edge landed
  -- 4.2s ago" — an edge older than the DoT's own duration is a MISSED CLEAR.
  --
  -- The FRAME half arrived with §3.10, and it is why this field is now two-sided: the brain
  -- consults the per-frame verdict FIRST and the latch only where that has no opinion, so a
  -- trace showing one channel cannot explain which one decided.  `Imm=tgt+p/pandemic@43.8`
  -- is the exact shape of the bug this replaced — a live frame reading beside a 43-second-
  -- old notification.  Frame tokens:
  --   tgt / plr   an aura is bound, and on which side     (=> dotState "up")
  --   off         capable and readable, nothing bound     (=> dotState "missing" — the
  --                                                           `not up` press, and the one
  --                                                           answer the old pipeline could
  --                                                           never reach)
  --   ?           the read refused (secret / threw)       (=> no opinion, hand to the edge)
  --   X           the writer methods are gone             (=> rule 17b's fallback; if this
  --                                                           appears, Blizzard moved the
  --                                                           internals — a finding, not a
  --                                                           bug)
  --   +p          `PandemicIcon` present: in the refresh window, RIGHT NOW (no TTL — it is
  --               a poll of a live predicate, not a latch)
  local function frameTok(f)
    if type(f) ~= "table" then return nil end
    if not f.capable then return "X" end
    if not f.unitReadable then return "?" end
    local u = "off"
    if f.unit == "target" then u = "tgt"
    elseif f.unit == "player" then u = "plr"
    elseif type(f.unit) == "string" then u = f.unit end
    return u .. (f.pandemic and "+p" or "")
  end

  local dotSeen, dotBases = {}, {}
  local function noteDot(spellID)
    if not dotSeen[spellID] then dotSeen[spellID] = true; dotBases[#dotBases + 1] = spellID end
  end
  for spellID, e in pairs(pulse.dotEdges or {}) do
    if type(e) == "table" and e.state then noteDot(spellID) end
  end
  for spellID, f in pairs(pulse.auraFrames or {}) do
    if frameTok(f) then noteDot(spellID) end
  end
  local dotList = {}
  for _, spellID in ipairs(dotBases) do
    local e = (pulse.dotEdges or {})[spellID]
    local edgeTok = "-"
    if type(e) == "table" and e.state then
      local age = (type(e.at) == "number" and type(pulse.at) == "number")
        and string.format("@%.1f", pulse.at - e.at) or ""
      edgeTok = tostring(e.state) .. age
    end
    dotList[#dotList + 1] = codeForSpell(spellID) .. "="
      .. (frameTok((pulse.auraFrames or {})[spellID]) or "-") .. "/" .. edgeTok
  end
  table.sort(dotList)
  local dotStr = (#dotList > 0) and table.concat(dotList, ",") or "-"

  return string.format("S{CD:%s | CH:%s | PR:%s | PW:%s | DOT:%s | CS:%s | DR:%s} G{%s} B{%s}",
    cdStr, chStr, prStr, pwStr, dotStr, csStr, drStr, gStr, bStr)
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
DL.lastConfig  = nil   -- last "<spec> tracked:<codes>" stamped into this session
DL.lastCombat  = nil   -- last combat state stamped into this session (nil ⇒ none yet)

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
    DL.session, DL.t0, DL.lastContent, DL.lastConfig = sess, GetTime(), nil, nil
    DL.lastCombat = nil
  end

  local entries = DL.session.entries
  local function append(line)
    entries[#entries + 1] = line
    while #entries > CAP do table.remove(entries, 1) end
  end

  -- ── COMBAT EDGE ────────────────────────────────────────────────────────────
  -- ⚠ STAMPED **ABOVE** THE CHANGE-ONLY DEDUP, AND THAT PLACEMENT IS THE WHOLE POINT.
  -- Combat state is NOT part of `content`, so a combat edge that does not happen to move
  -- the decision — idling at a full bar and pulling, which is the normal way a pull starts —
  -- would be swallowed by the `content == DL.lastContent` early return below.  A transition
  -- the log exists to mark must not be conditional on something else changing.
  --
  -- WHY THE LOG NEEDS THIS AT ALL.  The v0.32.36 re-fly's acceptance is `w:-` (no winner)
  -- ≈ 0 % **in a pull**, and out of combat "no winner" is the CORRECT answer — so idle time
  -- inflates the ratio without anything being wrong.  The 2026-08-01 capture measured 53.6 %
  -- across 21,048 lines and that number is simply unreadable for the purpose: a line carried
  -- no combat flag, and its clock is session-relative (`GetTime() - DL.t0`), so it could not
  -- be correlated with the flight ring's absolute `GetTime()` stamps either.  This marker is
  -- the split, and `wowkb.cdmp decisionlog --split` computes the ratio from it.
  --
  -- ⚠ AND IT COULD NOT BE RECOVERED RETROACTIVELY.  `entries` holds PRE-RENDERED STRINGS —
  -- the string IS the record — so no extractor change can put combat back into a capture
  -- taken before this shipped.  docs/status.md claimed the old log could be re-read "with no
  -- new flying"; that was wrong, and the capture on disk is spent for this purpose.
  --
  -- ⚠ THE FIRST `# combat` LINE OF A SESSION IS A BASELINE, NOT AN EDGE.  `lastCombat` starts
  -- nil, so the first Record always stamps the state it observes — usually `end` at t0.0,
  -- meaning "from here, out of combat".  That is deliberate: a session that BEGINS in combat
  -- (a login inside a pull) then says so, instead of leaving the reader to assume.
  --
  -- (`# config` deliberately stays BELOW the dedup: a spec or hero swap always moves the
  -- tracked set, hence always moves `content`, so it cannot be swallowed the way this can.)
  local inCombat = pulse.combat and true or false
  if inCombat ~= DL.lastCombat then
    DL.lastCombat = inCombat
    append(string.format("t%.1f # combat %s", GetTime() - DL.t0, inCombat and "start" or "end"))
  end

  -- Change-only: skip a tick whose whole decision is byte-identical to the last logged.
  local content = DL.Render(pulse, guidance, drawList)
  if content == DL.lastContent then return end
  DL.lastContent = content

  -- CONFIG RE-STAMP.  The session header records the tracked set at the session's FIRST
  -- record, which is accurate for t0.0 and MISLEADING for everything after any later
  -- reconfiguration — a respec 15 s into a login labels the whole session with the hero
  -- tree the player was LEAVING.  So stamp the configuration whenever it CHANGES: the
  -- ability set is the one signal that moves on both a spec swap and a hero-tree swap.
  -- Computed only on the change-only path, so a deduped tick pays nothing.
  -- The hero tree is part of the configuration now that it rides the pulse, so a re-stamp
  -- names it directly instead of leaving the reader to infer it from the ability set.
  local config = (ns.detectedSpecName or "?")
    .. " hero:" .. tostring(pulse.hero or "?")
    .. " tracked:" .. trackedCodes(pulse)
  if config ~= DL.lastConfig then
    DL.lastConfig = config
    append(string.format("t%.1f # config %s", GetTime() - DL.t0, config))
  end

  append(string.format("t%.1f %s", GetTime() - DL.t0, content))
end
