-- Census.lua — a TARGETED, TEMPORARY discovery instrument: the CDM STRUCT CENSUS.
--
-- ⚠ THIS FILE IS MEANT TO BE DELETED, on the AlertTape.lua model: one question set, one
-- capture format, a clear end date.  Nothing in State/Coach/Binder/Renderer reads it.  When
-- the six questions below are answered and written into
-- `knowledge/addon-dev/cooldown-manager.md`, delete this file, its `.toc` line, its command
-- and its `census` SavedVariables key.
--
-- WHY IT EXISTS.  `docs/roster-state-plan.md` Phase 2 carries six findings, and THREE of
-- them are "wrong by construction with an UNCONFIRMED TRIGGER" — we know the code is wrong,
-- we do not know whether the client ever produces the input that makes it matter.  That is
-- exactly the gap a capture closes, and nothing shipped can currently answer it: the
-- retired `/cdmp probe` took the struct dump with it, and `/cdmp hud layout` only reports
-- cooldownID -> spellID -> keybind.
--
-- THE QUESTIONS, and what each one decides:
--
--   Q1  Do any TAB-1 rows (Essential/Utility) set `hasAura` / `selfAura`?
--       -> §3.1.  `CooldownViewerItemMixin:ShouldBeActive()` is `cooldownID ~= nil`, so
--          `item:IsActive()` is CONSTANT TRUE on tab 1.  State gates the buff-item read on
--          those two flags rather than on family, and the result feeds `buffs`, which both
--          brains read.  Tyrant is one Essential row PLUS one TrackedBar row sharing a base
--          spellID — if the Essential row carries `selfAura`, the burst window reads
--          permanently open.  A live bug or a latent one: this decides which.
--
--   Q2  Does any row carry BOTH `overrideSpellID` and `overrideTooltipSpellID`?
--       -> §3.5.  Only then do State's two identity ladders disagree (`liveSpellID` takes
--          the tooltip first, correctly; `ns.DisplayIdentity` takes overrideSpellID first,
--          which is the reverse of Blizzard's).  That seam is where the v0.32.36 Diabolist
--          bug lived, so the fix is deliberately gated on evidence.
--
--   Q3  Does a FRESH `GetCooldownViewerCooldownInfo` carry the ELECTED `linkedSpellID`
--       (singular), or only the static `linkedSpellIDs` POOL (plural)?
--       -> BLOCKS PHASE 3 outright (cooldown-manager.md §2.5 `[gap]`).  Blizzard mutates
--          the provider's shared cached record in place, so a frame's view and a fresh read
--          are different objects and may disagree.  If the fresh read is always nil, the
--          keybind ladder must read `item:GetLinkedSpell()` off the FRAME.  Probed both
--          ways here, side by side, which is the only way to see a disagreement.
--
--   Q4  In restricted combat, does indexing a struct field ever THROW?
--       -> §3.9.  `Util.lua:160-163` pcalls the field access on a table that already passed
--          `issecrettable`, commenting that it can still throw; `St.Build` bare-indexes the
--          same shape outside any pcall.  The harness proved St.Build DIES on such a table
--          (`H.poison`).  Unknown is whether the client ever makes one.  Every field here is
--          read through its own pcall and classified `threw` separately from `SECRET` and
--          `nil` — collapsing those three is precisely how you conclude "Blizzard does not
--          populate this" when the truth is "we are not allowed to read it".
--
--   Q5  Does any cooldownID appear in TWO category sets?
--       -> a latent nondeterminism Phase 5 inherits.  `State.enumerate()` is first-wins over
--          `pairs(CATEGORY_NAME)`, whose order Lua does not define, so a duplicated cid
--          could be a PRESS on one login and an INPUT on the next.  Also captures whether
--          the hidden sentinels (HiddenSpell/HiddenAura) carry entries of their own, which
--          State asserts they do not.
--
--   Q6  Do `wasSetFromCharges/Cooldown/Aura` and `auraDataUnit` survive restricted combat?
--       -> cooldown-manager.md §7 `[gap]`, the highest-value open measurement there.  The
--          three `wasSetFrom*` booleans record WHICH of the four value sources won this
--          refresh, i.e. what the dial currently MEANS — an axis State does not have.
--          `auraDataUnit` is the only thing that says which side a bound aura is on.
--
-- ── DESIGN NOTES ────────────────────────────────────────────────────────────────────
--
-- 1. OOC AND IN COMBAT ARE THE SAME WALK, LABELLED.  Half these questions are ONLY about
--    the combat difference, so one capture proves nothing; `/cdmp census arm` fires the
--    in-combat one automatically a few seconds into the pull, because typing mid-rotation
--    is how you get a capture of standing still.
--
-- 2. NEVER FORMAT A SECRET, NEVER PERSIST ONE.  Every value goes through classify()/sample()
--    before it reaches string.format or SavedVariables.  A Secret Value that reaches `%s`
--    taints the string and poisons every row it lands in.
--
-- 3. FIVE-WAY CLASSIFICATION, NEVER A BOOLEAN.  num | bool | str | table | SECRET | nil |
--    threw.  See Q4 — the distinctions between the last three ARE the finding.
--
-- 4. IT WRITES TO DISK, not just chat.  WoW's chat frame has no copy/paste, so the one
--    output that has to reach the analysis machine is the one that cannot leave the client.
--    The chat summary is an eyeball convenience; `wowkb.cdmp census` is the record.
--    ⚠ SavedVariables flush on /reload or logout ONLY.
--
-- 5. ZERO PIPELINE COUPLING.  Reads only, everything pcall'd, no frame creation after load.
--    Safe to fire mid-combat.
local ADDON, ns = ...

ns.Census = {}
local Cs = ns.Census

local CAPTURES = 8    -- captures kept on disk (each is ~60 rows)

--------------------------------------------------------------------------------
-- The five-way read.  classify() names WHAT we got; sample() renders it only when
-- rendering is safe.  Deliberately a local copy rather than a call into AlertTape:
-- that file is scheduled for deletion and this one must outlive it.
--------------------------------------------------------------------------------
local function classify(ok, v)
  if not ok then return "threw" end
  if v == nil then return "nil" end
  if ns.IsSecret(v) then return "SECRET" end
  local t = type(v)
  if t == "table" then return ns.IsSecretTable(v) and "SECRET-TABLE" or "table" end
  return t          -- "number" | "boolean" | "string" | "function" | …
end

-- A DISK-SAFE rendering.  ns.Stash is the one guard for "this is about to be written to
-- SavedVariables": a secret degrades to the string "<secret>", and anything non-scalar
-- drops rather than persisting a live frame reference.
local function sample(ok, v)
  if not ok then return "<threw>" end
  if v == nil then return nil end
  if ns.IsSecret(v) then return "<secret>" end
  local t = type(v)
  if t == "number" or t == "boolean" or t == "string" then return ns.Stash(v) end
  return nil
end

-- Read ONE field through its OWN pcall.  This is the shape Q4 is about: the guard is on the
-- INDEX, not on the call that produced the table.
local function field(tbl, name)
  local v
  local ok = pcall(function() v = tbl[name] end)
  return { c = classify(ok, v), v = sample(ok, v) }
end

-- Call ONE method through its own pcall, when it exists at all.  "absent" is a distinct
-- answer from "threw" — a method Blizzard never defined is not a restriction.
local function method(obj, name)
  if not ns.HasMethod(obj, name) then return { c = "absent" } end
  local ok, v = pcall(obj[name], obj)
  return { c = classify(ok, v), v = sample(ok, v) }
end

-- The static candidate POOL, rendered as a list with per-element classification, so one
-- unreadable member does not hide the readable ones.
local function poolOf(info)
  local t
  if not pcall(function() t = info.linkedSpellIDs end) then return { c = "threw" } end
  if t == nil then return { c = "nil" } end
  if type(t) ~= "table" then return { c = type(t) } end
  if ns.IsSecretTable(t) then return { c = "SECRET-TABLE" } end
  local parts = {}
  local ok = pcall(function()
    for _, id in ipairs(t) do
      parts[#parts + 1] = ns.IsSecret(id) and "<secret>" or tostring(ns.Stash(id))
    end
  end)
  if not ok then return { c = "threw-iter" } end
  return { c = "table", n = #parts, v = table.concat(parts, ",") }
end

--------------------------------------------------------------------------------
-- Q5 — every (cooldownID -> which category SETS returned it).
--------------------------------------------------------------------------------
-- ⚠ Walks EVERY member of the enum, including the negative hidden sentinels, because
-- "HiddenSpell/HiddenAura carry no entries of their own" is a claim State makes and this is
-- the capture that checks it.
local function categoryWalk()
  local byCid, catError = {}, nil
  local E = Enum and Enum.CooldownViewerCategory
  if type(E) ~= "table" then return byCid, "Enum.CooldownViewerCategory absent" end
  if not (C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet) then
    return byCid, "GetCooldownViewerCategorySet absent"
  end
  if C_CooldownViewer.IsCooldownViewerAvailable then
    local ok, avail = pcall(C_CooldownViewer.IsCooldownViewerAvailable)
    if not ok then catError = "IsCooldownViewerAvailable threw"
    elseif not avail then catError = "IsCooldownViewerAvailable = false" end
  end
  for name, value in pairs(E) do
    if type(value) == "number" and type(name) == "string" then
      local ok, ids = pcall(C_CooldownViewer.GetCooldownViewerCategorySet, value, true)
      if ok and type(ids) == "table" then
        for _, id in ipairs(ids) do
          if type(id) == "number" and not ns.IsSecret(id) then
            byCid[id] = byCid[id] or {}
            table.insert(byCid[id], name)
          end
        end
      end
    end
  end
  return byCid, catError
end

--------------------------------------------------------------------------------
-- cooldownID -> live item frame (the frame half of Q3 and Q6).
--------------------------------------------------------------------------------
local function frameMap()
  local map, n = {}, 0
  if not ns.VIEWERS then return map, n end
  for _, v in ipairs(ns.VIEWERS) do
    local viewer = ns.GetViewer(v.frame)
    if viewer then
      for _, item in ipairs(ns.GetItemFrames(viewer)) do
        local cid = ns.ItemCooldownID(item)
        if cid and not map[cid] then
          map[cid] = { item = item, viewer = v.label or v.key }
          n = n + 1
        end
      end
    end
  end
  return map, n
end

--------------------------------------------------------------------------------
-- One capture.
--------------------------------------------------------------------------------
-- The documented Tier-1 struct (cooldown-manager.md §7), PLUS `linkedSpellID` singular —
-- which is NOT documented as part of the return and whose presence or absence IS Q3.
local STRUCT_FIELDS = {
  "cooldownID", "spellID", "overrideSpellID", "overrideTooltipSpellID",
  "linkedSpellID", "selfAura", "hasAura", "charges", "isKnown", "flags", "category",
}

-- The frame-side reads.  `GetSpellID` is Blizzard's OWN five-rung resolve, so comparing it
-- against the struct's fields is how a frame-only rung (1 or 2) becomes visible at all.
local FRAME_METHODS = { "GetSpellID", "GetBaseSpellID", "GetAuraSpellID", "GetLinkedSpell",
                        "IsActive", "IsShown", "GetCooldownID" }
local FRAME_FIELDS  = { "wasSetFromCharges", "wasSetFromCooldown", "wasSetFromAura",
                        "auraDataUnit", "hideWhenInactive", "cooldownID" }

function Cs.Capture(label)
  local combat = InCombatLockdown() and "CMB" or "OOC"
  local byCid, catError = categoryWalk()
  local frames, frameCount = frameMap()

  local rows, n = {}, 0
  for cid, cats in pairs(byCid) do
    n = n + 1
    local row = { cid = cid, cats = table.concat(cats, "+"), nCats = #cats }

    -- The struct, guarded exactly as State guards it: the CALL, then the secret-table
    -- verdict, then — the part State does NOT do — each field's own index.
    local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cid)
    if not ok then row.struct = "threw"
    elseif info == nil then row.struct = "nil"
    elseif type(info) ~= "table" then row.struct = type(info)
    elseif ns.IsSecretTable(info) then row.struct = "SECRET-TABLE"
    else
      row.struct = "table"
      row.f = {}
      for _, name in ipairs(STRUCT_FIELDS) do row.f[name] = field(info, name) end
      row.pool = poolOf(info)
      -- A readable base gives the row a human name, which is most of what makes a
      -- 60-row capture legible.
      local base = row.f.spellID
      if base and base.c == "number" then row.name = ns.SpellName(base.v) end
    end

    local fr = frames[cid]
    if fr then
      row.viewer = fr.viewer
      row.m, row.ff = {}, {}
      for _, name in ipairs(FRAME_METHODS) do row.m[name] = method(fr.item, name) end
      for _, name in ipairs(FRAME_FIELDS)  do row.ff[name] = field(fr.item, name) end
    end

    rows[#rows + 1] = row
  end

  table.sort(rows, function(a, b) return a.cid < b.cid end)

  local cap = {
    at = GetTime(), combat = combat, label = label or "manual",
    version = ns.version,
    -- The DETECTED spec name, not the ACTIVE one: the resolver stashes it even for an
    -- unsupported spec, so a capture from a passive character still says which one.
    spec = ns.detectedSpecName or "?",
    active = ns.ActiveSpec ~= nil,
    hero = ns.State and ns.State.ReadHero and (ns.State.ReadHero()) or nil,
    cids = n, frames = frameCount, catError = catError, rows = rows,
  }

  ns.db = ns.db or {}
  ns.db.census = ns.db.census or {}
  table.insert(ns.db.census, cap)
  while #ns.db.census > CAPTURES do table.remove(ns.db.census, 1) end
  Cs.last = cap
  return cap
end

--------------------------------------------------------------------------------
-- The chat summary — the six answers, read straight off the capture.
--------------------------------------------------------------------------------
-- Deliberately answers the QUESTIONS rather than dumping the rows: 60 rows in a chat frame
-- with no copy/paste is not a readout, it is a wall.  The rows are on disk.
local function isTab1(cats)
  return cats and (cats:find("Essential") or cats:find("Utility")) and true or false
end

local function summarise(cap)
  ns.Heading(string.format("CDM census — %s · %s%s · %s%s", cap.combat, cap.spec,
    cap.active and "" or " (passive)",
    cap.hero or "no hero", cap.catError and (" |cffff4040" .. cap.catError .. "|r") or ""))
  ns.Printf("  %d cooldownID(s), %d with a live item frame", cap.cids, cap.frames)

  local dual, q1, q2, threw, elected, poolOnly = {}, {}, {}, {}, 0, 0
  local wasSet, auraUnit = {}, {}
  for _, r in ipairs(cap.rows) do
    if r.nCats > 1 then dual[#dual + 1] = string.format("%d(%s)", r.cid, r.cats) end
    if r.f then
      -- Q1 — a tab-1 row carrying either aura flag.
      local ha, sa = r.f.hasAura, r.f.selfAura
      if isTab1(r.cats) and ((ha.c == "boolean" and ha.v) or (sa.c == "boolean" and sa.v)) then
        q1[#q1 + 1] = string.format("%d %s(hasAura=%s selfAura=%s)", r.cid,
          r.name or "?", tostring(ha.v), tostring(sa.v))
      end
      -- Q2 — both static override fields present on one row.
      if r.f.overrideSpellID.c == "number" and r.f.overrideTooltipSpellID.c == "number" then
        q2[#q2 + 1] = string.format("%d %s(ov=%s ovt=%s)", r.cid, r.name or "?",
          tostring(r.f.overrideSpellID.v), tostring(r.f.overrideTooltipSpellID.v))
      end
      -- Q3 — did the FRESH read carry the elected singular link?
      if r.f.linkedSpellID.c == "number" then elected = elected + 1
      elseif r.pool and r.pool.c == "table" and (r.pool.n or 0) > 0 then poolOnly = poolOnly + 1 end
      -- Q4 — any field whose INDEX raised.
      for name, e in pairs(r.f) do
        if e.c == "threw" then threw[#threw + 1] = string.format("%d.%s", r.cid, name) end
      end
    elseif r.struct ~= "table" then
      threw[#threw + 1] = string.format("%d:struct=%s", r.cid, tostring(r.struct))
    end
    -- Q6 — the frame-cached source flags and the aura's unit.
    if r.ff then
      for _, name in ipairs({ "wasSetFromCharges", "wasSetFromCooldown", "wasSetFromAura" }) do
        local e = r.ff[name]
        if e then wasSet[e.c] = (wasSet[e.c] or 0) + 1 end
      end
      local au = r.ff.auraDataUnit
      if au then auraUnit[au.c] = (auraUnit[au.c] or 0) + 1 end
    end
  end

  local function line(tag, q, list, none)
    if #list == 0 then ns.Printf("  |cff88ff88%s|r %s — %s", tag, q, none)
    else ns.Printf("  |cffffd100%s|r %s — %d: %s", tag, q, #list,
      table.concat(list, " ", 1, math.min(#list, 6))) end
  end
  line("Q1", "tab-1 rows with an aura flag", q1, "none (\u{00A7}3.1 is LATENT)")
  line("Q2", "rows with BOTH override fields", q2, "none (\u{00A7}3.5 is LATENT)")
  ns.Printf("  |cff%s|rQ3 elected linkedSpellID on a FRESH read: %d row(s); pool-only: %d",
    elected > 0 and "ffd100" or "88ff88", elected, poolOnly)
  line("Q4", "struct fields whose INDEX raised", threw, "none this capture")
  local dualTag = (#dual == 0) and "  |cff88ff88Q5|r" or "  |cffffd100Q5|r"
  ns.Printf("%s cids in >1 category set — %s", dualTag,
    (#dual == 0) and "none" or table.concat(dual, " "))
  local function census(t)
    local parts = {}
    for k, v in pairs(t) do parts[#parts + 1] = k .. "=" .. v end
    return #parts > 0 and table.concat(parts, " ") or "(no frames)"
  end
  ns.Printf("  Q6 wasSetFrom* %s | auraDataUnit %s", census(wasSet), census(auraUnit))
  ns.Print("  |cffffd100/reload to flush|r, then: wowkb.cdmp census")
end

--------------------------------------------------------------------------------
-- The armed in-combat capture.
--------------------------------------------------------------------------------
-- Created at LOAD, never in combat (frame discipline).  One-shot: it disarms itself, so an
-- armed session cannot quietly keep capturing every pull for the rest of the evening.
local arm = CreateFrame("Frame")
local DELAY = 4       -- seconds into the pull; long enough for the first GCDs to have run
arm:SetScript("OnEvent", function(self)
  self:UnregisterAllEvents()
  ns.Printf("census armed \u{2192} capturing in %ds\u{2026}", DELAY)
  C_Timer.After(DELAY, function()
    local ok, cap = pcall(Cs.Capture, "armed")
    if not ok then return ns.Printf("|cffff4040census failed:|r %s", tostring(cap)) end
    summarise(cap)
  end)
end)

--------------------------------------------------------------------------------
ns.RegisterCommand("census",
  "TEMPORARY: dump the raw CDM struct + frame fields (arm | dump | clear); "
  .. "bare = capture now",
  function(rest)
    rest = (rest or ""):lower():gsub("%s+", "")
    if rest == "arm" then
      arm:RegisterEvent("PLAYER_REGEN_DISABLED")
      return ns.Print("census ARMED — pull, and it captures "
        .. DELAY .. "s in. |cffffffff/cdmp census|r for an OOC one first.")
    elseif rest == "clear" then
      if ns.db then ns.db.census = {} end
      Cs.last = nil
      return ns.Print("census cleared")
    elseif rest == "dump" then
      if not Cs.last then return ns.Print("nothing captured this session") end
      return summarise(Cs.last)
    end
    summarise(Cs.Capture("manual"))
  end)
