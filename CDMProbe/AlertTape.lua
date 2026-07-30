-- AlertTape.lua — a TARGETED, TEMPORARY discovery instrument for the CDM alert channel.
--
-- ⚠ THIS FILE IS MEANT TO BE DELETED.  It is not part of the pipeline and nothing in
-- State/Coach/Binder/Renderer reads it.  It exists to answer a small set of open
-- questions about `CooldownViewerItemMixin:TriggerAlertEvent`; once those answers are
-- settled game-wide invariants in knowledge/addon-dev/api-events-and-discovery.md §2.8,
-- delete this file, its `.toc` line, its command and its SavedVariables key.  This is the
-- shape the retired `/cdmp probe` was supposed to have had: ONE question, ONE tape, a
-- clear end date — not a kitchen sink that outlives its purpose.
--
-- THE QUESTIONS (docs/status.md; KB §2.8):
--   Q1  Does `PandemicTime` fire at all, and does it fire IN COMBAT?
--   Q2  Are `pandemicStartTime` / `pandemicEndTime` / `IsInPandemicTime()` READABLE in
--       combat, or do they go secret like the aura data they are derived from?
--   Q3  Which alert types is each tracked cooldown even eligible for?
--       (`/cdmp alerts probe` — a plain OOC read, no tape needed.)
--   Q4  Do `ChargeGained` / `OnAuraApplied` / `OnAuraRemoved` fire in combat?  ChargeGained
--       matters directly: Conflagrate + Shadowburn are the first charged tracked abilities
--       and C_Spell.GetSpellCharges is secret in combat, so a gain EDGE may be the only
--       in-combat charge signal available.
--
-- ── DESIGN NOTES, because the failure modes here are subtle ──────────────────────────
--
-- 1. TWO CHANNELS, DEDUPED DIFFERENTLY.  `events` dedups on (cid, event, combat) but keeps
--    a COUNT plus first/last timestamps — frequency is itself a finding ("fired once per
--    application" and "fired every frame" have very different consequences), and a plain
--    change-only log would erase it.  `fields` dedups on the READABILITY CLASS, because a
--    10 Hz sampler of changing numbers would flood the ring while telling us nothing new;
--    only a class change is informative.
--
-- 2. THREE-WAY CLASSIFICATION, NEVER A BOOLEAN.  Every field read records one of
--    `num` / `bool` / `SECRET` / `nil` / `threw`.  Collapsing SECRET into nil is the
--    specific mistake that would make us conclude "Blizzard does not populate this" when
--    the truth is "we are not allowed to read it" — opposite implications for the design.
--    The KB states this as a rule: an instrument that cannot observe its subject must SAY
--    SO, not emit a plausible value.
--
-- 3. A BUILT-IN CONTROL GROUP.  We record all six alert types, including the two we
--    already know work (`Available` / `OnCooldown`).  If a capture shows those two but no
--    `PandemicTime`, the instrument is proven live and the absence is a real finding.  If
--    it shows nothing at all, the instrument is broken and proves nothing.  Without the
--    control, "no rows" is unfalsifiable.
--
-- 4. NEVER FORMAT A SECRET.  Every value that reaches string.format goes through
--    classify()/sample() first; a Secret Value that reaches `%s` taints the string and
--    poisons every row it lands in.
local ADDON, ns = ...

ns.AlertTape = {}
local T = ns.AlertTape

local CAP      = 400   -- unique rows kept per channel per session (dedup keeps this small)
local SESSIONS = 3     -- sessions kept on disk, mirroring the decision log

T.session = nil        -- in-memory handle; nil => the first Record of this load opens one

--------------------------------------------------------------------------------
-- Enum value -> name, built once (so a row says "PandemicTime", not "2").
--------------------------------------------------------------------------------
local NAMES
local function eventName(v)
  if not NAMES then
    NAMES = {}
    local A = Enum and Enum.CooldownViewerAlertEventType
    if type(A) == "table" then
      for name, value in pairs(A) do
        if type(value) == "number" and type(name) == "string" then NAMES[value] = name end
      end
    end
  end
  return NAMES[v] or ("?" .. tostring(v))
end

--------------------------------------------------------------------------------
-- The three-way read.  classify() names WHAT we got; sample() renders it only when
-- it is safe to render.  Both are pcall'd: a restricted read may throw outright.
--------------------------------------------------------------------------------
local function classify(ok, v)
  if not ok then return "threw" end
  if v == nil then return "nil" end
  if ns.IsSecret(v) then return "SECRET" end
  local t = type(v)
  if t == "number" then return "num" end
  if t == "boolean" then return "bool" end
  return t
end

local function sample(ok, v)
  if not ok or v == nil or ns.IsSecret(v) then return "-" end
  if type(v) == "number" then return string.format("%.2f", v) end
  return tostring(v)
end

-- Read one field/method off the item, returning (classString, sampleString).
local function readField(item, key)
  local ok, v = pcall(function() return item[key] end)
  return classify(ok, v), sample(ok, v)
end

local function readIsInPandemic(item)
  if not ns.HasMethod(item, "IsInPandemicTime") then return "absent", "-" end
  local ok, v = pcall(item.IsInPandemicTime, item, GetTime())
  return classify(ok, v), sample(ok, v)
end

--------------------------------------------------------------------------------
-- Session handling (mirrors DecisionLog's ring so the extractor shape is familiar).
--------------------------------------------------------------------------------
local function ensureSession()
  if T.session then return T.session end
  local tape = ns.db and ns.db.alerttape
  if type(tape) ~= "table" then
    tape = {}
    if ns.db then ns.db.alerttape = tape end
  end
  local sess = {
    started = date("%Y-%m-%d %H:%M:%S"),
    version = ns.version,
    events  = {},   -- "cid|event|combat" -> { cid, event, combat, n, first, last }
    fields  = {},   -- "cid|combat|class" -> { cid, combat, class, n, first, last, sample }
  }
  tape[#tape + 1] = sess
  while #tape > SESSIONS do table.remove(tape, 1) end
  T.session = sess
  return sess
end

local function countOf(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

--------------------------------------------------------------------------------
-- Record — called from State's alert hook for EVERY alert type (the control group).
--------------------------------------------------------------------------------
-- `cid` is already resolved and secret-guarded by the caller; `event` is already
-- confirmed non-secret there too.  A no-op unless the tape is explicitly enabled, so
-- shipping this costs a single boolean test per alert.
function T.Record(item, event, cid)
  if not (ns.db and ns.db.alerttape_on) then return end
  local sess = ensureSession()
  local now = GetTime()
  local combat = InCombatLockdown() and "combat" or "ooc"
  local ename = eventName(event)

  -- Channel 1 — the event tape.  Deduped, but COUNTED: how often matters.
  local ekey = tostring(cid) .. "|" .. ename .. "|" .. combat
  local row = sess.events[ekey]
  if row then
    row.n, row.last = row.n + 1, now
  elseif countOf(sess.events) < CAP then
    sess.events[ekey] = { cid = cid, event = ename, combat = combat,
                          n = 1, first = now, last = now }
  end

  -- Channel 2 — the field probe.  Deduped by READABILITY CLASS: a value change is noise,
  -- a class change is the answer to Q2.  Sampled on every alert (cheap, and alerts are
  -- rare) so we see the fields both in and out of combat without a polling loop.
  local pStartC, pStartV = readField(item, "pandemicStartTime")
  local pEndC,   pEndV   = readField(item, "pandemicEndTime")
  local trigC,   trigV   = readField(item, "pandemicAlertTriggerTime")
  local inPC,    inPV    = readIsInPandemic(item)
  local class = string.format("pStart=%s pEnd=%s trig=%s isIn=%s", pStartC, pEndC, trigC, inPC)
  local fkey = tostring(cid) .. "|" .. combat .. "|" .. class
  local frow = sess.fields[fkey]
  if frow then
    frow.n, frow.last = frow.n + 1, now
    -- Keep the freshest readable sample; a later row may be readable where an earlier
    -- one was not, and the actual numbers are what tell us the window is real.
    frow.sample = string.format("pStart=%s pEnd=%s trig=%s isIn=%s", pStartV, pEndV, trigV, inPV)
  elseif countOf(sess.fields) < CAP then
    sess.fields[fkey] = {
      cid = cid, combat = combat, class = class, event = ename,
      n = 1, first = now, last = now,
      sample = string.format("pStart=%s pEnd=%s trig=%s isIn=%s", pStartV, pEndV, trigV, inPV),
    }
  end
end

--------------------------------------------------------------------------------
-- `/cdmp alerts` — the command surface.
--------------------------------------------------------------------------------
-- ELIGIBILITY (Q3) is a plain out-of-combat read and needs no tape at all:
-- C_CooldownViewer.GetValidAlertTypes(cooldownID) is a public API returning the alert
-- types valid for that cooldown.  Run this FIRST — it is the baseline the tape gets
-- compared against, and if a spell is not PandemicTime-eligible then its absence from the
-- tape is expected rather than a finding.
local function probeEligibility()
  ns.Heading("CDM alert eligibility — C_CooldownViewer.GetValidAlertTypes(cooldownID)")
  if not (C_CooldownViewer and C_CooldownViewer.GetValidAlertTypes) then
    return ns.Print("  |cffff4040C_CooldownViewer.GetValidAlertTypes absent|r")
  end
  if not ns.VIEWERS then return ns.Print("  no viewers") end
  local seen, shown = {}, 0
  for _, v in ipairs(ns.VIEWERS) do
    local viewer = ns.GetViewer(v.frame)
    if viewer then
      for _, item in ipairs(ns.GetItemFrames(viewer)) do
        local cid = ns.ItemCooldownID(item)
        if cid and not seen[cid] then
          seen[cid] = true
          local base = ns.ItemBaseSpellID(item)
          local name = (base and ns.SpellName(base)) or "?"
          local ok, types = pcall(C_CooldownViewer.GetValidAlertTypes, cid)
          local list = "|cffff4040<unreadable>|r"
          if ok and type(types) == "table" then
            local parts = {}
            for _, t in ipairs(types) do
              if not ns.IsSecret(t) then parts[#parts + 1] = eventName(t) end
            end
            list = #parts > 0 and table.concat(parts, ", ") or "(none)"
          end
          ns.Printf("  [%s] cid=%s spell=%s  |cffffffff%s|r",
            v.label, tostring(cid), tostring(base), list)
          ns.Printf("        %s", name)
          shown = shown + 1
        end
      end
    end
  end
  ns.Printf("  %d tracked cooldown(s).", shown)
end

local function dumpTape()
  local sess = T.session
  if not sess then return ns.Print("  tape empty this session (nothing recorded yet)") end
  ns.Heading("Alert tape — this session")
  for _, r in pairs(sess.events) do
    ns.Printf("  EV  cid=%d %-14s %-6s n=%d", r.cid, r.event, r.combat, r.n)
  end
  for _, r in pairs(sess.fields) do
    ns.Printf("  FLD cid=%d %-6s n=%d  %s", r.cid, r.combat, r.n, r.class)
    ns.Printf("        sample: %s", r.sample)
  end
  ns.Printf("  %d event row(s), %d field row(s). |cffffd100/reload to flush to disk|r,"
    .. " then: wowkb.cdmp alerttape", countOf(sess.events), countOf(sess.fields))
end

ns.RegisterCommand("alerts",
  "CDM alert-channel tape (temporary instrument): on|off|probe|dump|clear",
  function(arg)
    arg = (arg or ""):lower():match("^%s*(%S*)")
    if arg == "on" then
      ns.db.alerttape_on = true
      ns.Print("alert tape |cff88ff88ON|r — the HUD must also be on (/cdmp hud) for the "
        .. "item hooks to install. Pull, then |cffffd100/reload|r to flush.")
    elseif arg == "off" then
      ns.db.alerttape_on = false
      ns.Print("alert tape |cffff4040OFF|r")
    elseif arg == "probe" then
      probeEligibility()
    elseif arg == "dump" then
      dumpTape()
    elseif arg == "clear" then
      ns.db.alerttape = {}
      T.session = nil
      ns.Print("alert tape cleared")
    else
      ns.Print("|cffffd100/cdmp alerts|r on | off | probe | dump | clear")
      ns.Print("  |cff88ff88probe|r — which alert types each tracked cooldown is eligible for (OOC read, no tape)")
      ns.Print("  |cff88ff88on|r    — record every TriggerAlertEvent + the pandemic fields")
      ns.Printf("  currently: %s", (ns.db and ns.db.alerttape_on) and "|cff88ff88ON|r" or "|cffff4040OFF|r")
    end
  end)
