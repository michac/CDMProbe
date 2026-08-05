-- AlertTape.lua — a TARGETED, TEMPORARY discovery instrument for the CDM alert channel.
--
-- ⚠ THIS FILE IS MEANT TO BE DELETED.  It is not part of the pipeline and nothing in
-- State/Coach/Binder/Renderer reads it.  It exists to answer a small set of open
-- questions about `CooldownViewerItemMixin:TriggerAlertEvent`; once those answers are
-- settled game-wide invariants in knowledge/addon-dev/api-events-and-discovery.md §2.8,
-- delete this file, its `.toc` line, its command and its SavedVariables key.  ONE question,
-- ONE tape, a clear end date — not a kitchen sink that outlives its purpose.
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
-- Enum value -> name, so a row says "PandemicTime", not "2".
--------------------------------------------------------------------------------
-- PROMOTED to `ns.AlertEventName` (Util.lua) in Phase 4, alongside
-- `ns.ReadValidAlertTypes` before it: this file is scheduled for deletion and the roster
-- coverage report needs the same map.  The local alias keeps the two call sites below
-- unchanged while there is exactly ONE map.
local eventName = function(v) return ns.AlertEventName(v) end

--------------------------------------------------------------------------------
-- The three-way read.  classify() names WHAT we got; sample() renders it only when
-- it is safe to render.  Both are pcall'd: a restricted read may throw outright.
--------------------------------------------------------------------------------
-- PROMOTED to `ns.ClassOf` (Util.lua) alongside CurveLab.lua: this file, Assist.lua and
-- CurveLab.lua each held a private copy, and three copies is the trigger.  Only the
-- `ok` wrapper stays local — "the call threw" is a CALL outcome, not a value class, and
-- collapsing the two is how a refusal starts reading as a nil.
local function classify(ok, v)
  if not ok then return "threw" end
  return ns.ClassOf(v)
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
-- WHICH BUILD RAISED THIS EDGE?
--------------------------------------------------------------------------------
-- ⚠ ADDED 2026-07-31, and it is a CORRECTNESS fix, not a labelling nicety.  Both channels
-- dedup by a key built from `cid`, and a spec swap WITHOUT a /reload keeps recording into
-- the same session — so a cooldownID shared between two specs (the class-wide utilities,
-- the shared summons) had its counts SUMMED ACROSS BUILDS under one row, silently.  "Fired
-- 14x" would be 9 on Destruction plus 5 on Demonology, and nothing said so.
--
-- The build goes INTO the dedup key, so rows from two builds can never merge, and onto the
-- row, so each one says where it came from.  DecisionLog solves the same problem with its
-- `# config` re-stamp; this is the same idea keyed rather than stamped, because these rows
-- are a deduped SET rather than an ordered stream.
local function buildTag()
  local spec = ns.detectedSpecName or "?"
  -- Direct call: State owns the hero read, and since v0.32.43 its cache is invalidated by
  -- an always-on frame, so this is the live tree even with the HUD off.
  local name, id = ns.State.ReadHero()
  return spec .. "/" .. tostring(name or id or "?")
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
    build   = buildTag(),   -- the build at session open; every ROW carries its own too
    events  = {},   -- "build|cid|event|combat" -> { build, cid, event, combat, n, first, last }
    fields  = {},   -- "build|cid|combat|class" -> { build, cid, combat, class, n, …, sample }
    elig    = {},   -- "build|cid" -> { build, cid, spellID, name, viewer, types }
  }
  tape[#tape + 1] = sess
  while #tape > SESSIONS do table.remove(tape, 1) end
  T.session = sess
  -- The eligibility baseline is captured INTO the session, automatically.  It is not
  -- optional context — without it, "PandemicTime never appeared" is unreadable, because
  -- we cannot tell "it fired and we missed it" from "this spell was never eligible".
  -- Taken lazily here (rather than only from the command) so EVERY session carries its
  -- own baseline even when the tape was already on across a /reload.  pcall'd: a baseline
  -- failure must not stop the tape recording.
  pcall(T.CaptureEligibility)
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
  local build = buildTag()

  -- A BUILD CHANGE MID-SESSION re-takes the eligibility baseline, because the old one
  -- describes a tracked set that no longer exists — and without a baseline for the new
  -- build, "PandemicTime never appeared" is unreadable there.  Automatic rather than a
  -- remembered `/cdmp alerts probe`: the step you have to remember is the step you skip.
  if sess.lastBuild ~= build then
    sess.lastBuild = build
    pcall(T.CaptureEligibility)
  end

  -- Channel 1 — the event tape.  Deduped, but COUNTED: how often matters.
  local ekey = build .. "|" .. tostring(cid) .. "|" .. ename .. "|" .. combat
  local row = sess.events[ekey]
  if row then
    row.n, row.last = row.n + 1, now
  elseif countOf(sess.events) < CAP then
    sess.events[ekey] = { build = build, cid = cid, event = ename, combat = combat,
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
  local fkey = build .. "|" .. tostring(cid) .. "|" .. combat .. "|" .. class
  local frow = sess.fields[fkey]
  if frow then
    frow.n, frow.last = frow.n + 1, now
    -- Keep the freshest readable sample; a later row may be readable where an earlier
    -- one was not, and the actual numbers are what tell us the window is real.
    frow.sample = string.format("pStart=%s pEnd=%s trig=%s isIn=%s", pStartV, pEndV, trigV, inPV)
  elseif countOf(sess.fields) < CAP then
    sess.fields[fkey] = {
      build = build, cid = cid, combat = combat, class = class, event = ename,
      n = 1, first = now, last = now,
      sample = string.format("pStart=%s pEnd=%s trig=%s isIn=%s", pStartV, pEndV, trigV, inPV),
    }
  end
end

--------------------------------------------------------------------------------
-- `/cdmp alerts` — the command surface.
--------------------------------------------------------------------------------
-- ELIGIBILITY (Q3): which alert types each tracked cooldown can even raise, via
-- `ns.ReadValidAlertTypes` — the guarded reader in Util.lua.  A plain out-of-combat read.
-- The read itself was PROMOTED out of this file (Phase 3 housekeeping) because Phase 4's
-- roster coverage probe is built on it and this file is scheduled for deletion; what stays
-- here is only the capture bookkeeping and the formatting.  ⚠ The API under-reports — see
-- ns.ReadValidAlertTypes' own note.
--
-- ⚠ THIS WRITES TO SAVEDVARIABLES, not just chat.  An earlier cut printed it to chat only,
-- which was useless: WoW's default chat frame has no copy/paste, so the one output that has
-- to reach the analysis machine was the one output that could not leave the client.  The
-- durable record is the capture; the chat print is a convenience eyeball.  Same reason the
-- decision log has always gone to disk.
--
-- It is also captured AUTOMATICALLY when a session opens, so it cannot be forgotten.
function T.CaptureEligibility()
  local sess = T.session
  if not sess then return nil, "no session" end
  if not ns.VIEWERS then
    sess.eligError = "no viewers"
    return nil, sess.eligError
  end
  local n = 0
  for _, v in ipairs(ns.VIEWERS) do
    local viewer = ns.GetViewer(v.frame)
    if viewer then
      for _, item in ipairs(ns.GetItemFrames(viewer)) do
        local cid = ns.ItemCooldownID(item)
        -- Keyed by BUILD|cid, not cid: after a spec swap the same cooldownID can describe a
        -- different row, and the old baseline must not shadow the new one.
        local build = buildTag()
        local ekey = build .. "|" .. tostring(cid)
        if cid and not sess.elig[ekey] then
          local base = ns.ItemBaseSpellID(item)
          local types, err = ns.ReadValidAlertTypes(cid)
          local list
          if types then
            local parts = {}
            for _, t in ipairs(types) do
              -- Never format a secret; an unreadable member is named as such, not dropped.
              parts[#parts + 1] = ns.IsSecret(t) and "SECRET" or eventName(t)
            end
            list = #parts > 0 and table.concat(parts, ",") or "(none)"
          else
            list = "<" .. (err or "unreadable") .. ">"
          end
          sess.elig[ekey] = {
            build = build, cid = cid, spellID = base, viewer = v.label, types = list,
            name = (base and ns.SpellName(base)) or "?",
          }
          n = n + 1
        end
      end
    end
  end
  sess.eligError = nil
  return n
end

local function probeEligibility()
  ensureSession()
  local n, err = T.CaptureEligibility()
  ns.Heading("CDM alert eligibility — C_CooldownViewer.GetValidAlertTypes(cooldownID)")
  if not n then return ns.Printf("  |cffff4040%s|r", tostring(err)) end
  local sess = T.session
  for _, r in pairs(sess.elig) do
    ns.Printf("  [%s] cid=%s %s |cffffffff%s|r", r.viewer, tostring(r.cid), r.name, r.types)
  end
  ns.Printf("  %d tracked cooldown(s) — |cff88ff88saved to the capture|r; "
    .. "|cffffd100/reload|r then: wowkb.cdmp alerttape", n)
end

local function dumpTape()
  local sess = T.session
  if not sess then return ns.Print("  tape empty this session (nothing recorded yet)") end
  ns.Heading("Alert tape — this session")
  ns.Printf("  ELG %d cooldown(s)%s", countOf(sess.elig),
    sess.eligError and (" |cffff4040" .. sess.eligError .. "|r") or "")
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
      ensureSession()          -- opens the session AND captures the eligibility baseline
      ns.Print("alert tape |cff88ff88ON|r — the HUD must also be on (/cdmp hud) for the "
        .. "item hooks to install. Pull, then |cffffd100/reload|r to flush.")
      local sess = T.session
      ns.Printf("  eligibility baseline: %s",
        sess.eligError and ("|cffff4040" .. sess.eligError .. "|r")
          or ("|cff88ff88" .. countOf(sess.elig) .. " cooldown(s) captured|r"))
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
