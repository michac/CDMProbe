-- Flight.lua — THE ACCEPTANCE RECORDER.  One command in, one report out.
--
-- ⚠ TEMPORARY-ISH, in the AlertTape/Assist mould: it exists so a *release's* acceptance
-- pass costs the player two actions instead of ten.  Unlike those two it is not tied to a
-- single question, so it survives as long as we keep flying builds — but it is a
-- diagnostic, not pipeline, and nothing reads it.
--
-- WHY IT EXISTS.  Every phase of this project ends with an in-game pass, and the pass kept
-- being written down as a CHECKLIST OF SLASH COMMANDS: `/cdmp hud coverage`, then again
-- after a spec swap, then `/cdmp hud status` mid-pull, then `/cdmp assist` mid-pull, then
-- `/reload`, then a decision-log extract.  That is the wrong shape twice over — it asks
-- the player to type during a GCD, and it makes the ACCEPTANCE CRITERIA something a human
-- eyeballs in a chat dump rather than something a machine checks.  The decision log
-- already solved this: record structurally, extract on the desktop.  This is that, applied
-- to the whole acceptance pass.
--
-- THE FLOW IS TWO STEPS:
--     /cdmp flight        arm it (turns the HUD on, samples immediately)
--     …play…              pull a dummy, swap spec/hero, pull again — NO typing
--     /reload             flush SavedVariables
--     uv run python -m wowkb.cdmp flight        the PASS/FAIL report
--
-- HOW IT SAMPLES.  A 1 Hz ticker, recording only on a change of the ANSWER SHAPE — the
-- `AlertTape`/`Assist` dedup-by-class idiom, because a timestamp change is noise and a
-- change in what the client ANSWERS is the finding.  Combat entry/exit, a spec swap and a
-- talent/hero swap force an immediate sample, so the interesting transitions are never
-- missed by up to a second.  A whole session is typically a handful of rows.
--
-- ⚠ IT MUST NOT PERTURB WHAT IT MEASURES.  The single most important thing this records is
-- that `Coverage.Get()` in combat comes back STALE and never reports the roster blind — so
-- the sampler calls the real `Coverage.Get()`, on the real combat path, rather than a
-- private copy that could pass while the shipping path fails.  Same for the assist probe:
-- it is `ns.Assist.Probe()`, the shipping reader.
local ADDON, ns = ...

ns.Flight = {}
local F = ns.Flight

local CAP    = 120    -- sample rows kept (dedup by answer-shape keeps this tiny)
local PERIOD = 1.0

local ticker, ev

--------------------------------------------------------------------------------
-- The answer shape — what makes a sample worth keeping.
--------------------------------------------------------------------------------
-- Deliberately NOT the whole record: cue counts and timestamps move every tick and would
-- turn the ring into a log.  This is the set of facts an acceptance criterion is written
-- against, so a new row means an ANSWER changed.
function F.Key(s)
  local c, a = s.cov, s.assist
  return table.concat({
    tostring(s.specID), tostring(s.hero), s.combat and "combat" or "ooc",
    tostring(c.ok), tostring(c.reason), tostring(c.stale),
    tostring(c.blind), tostring(c.unknownN),
    a.available, a.action, a.rotation, a.next0, a.next1,
  }, "|")
end

--------------------------------------------------------------------------------
-- One sample.
--------------------------------------------------------------------------------
-- Everything here is either a plain count or a value already through `ns.Stash` — the one
-- guard for "this is about to be written to SavedVariables" (a Secret Value degrades to
-- the string "<secret>", which is itself the finding; a table drops to nil).
local function readCoverage()
  local rep = ns.Coverage.Get()
  local c = rep.counts or {}
  local out = {
    ok = rep.ok and true or false, reason = rep.reason, stale = rep.stale and true or false,
    scanned = rep.scanned or 0, unreadable = rep.unreadableRows or 0,
    okN = c.ok or 0, virtualN = c.virtual or 0, expectedN = c.expected or 0,
    blind = c.blind or 0, unknownN = c.unknown or 0, total = c.total or 0,
    verdicts = {},
  }
  -- The per-id verdicts ride EVERY row, not just the first: the acceptance criteria are
  -- per-id ("Incinerate reads virtual, not blind"), and a summary count cannot answer them.
  -- ~39 tiny records against a handful of rows is nothing on disk.
  for _, e in ipairs(rep.entries or {}) do
    out.verdicts[#out.verdicts + 1] = {
      id = e.spellID, v = e.verdict, cov = e.coverage, n = #(e.rows or {}),
      known = e.known,
      -- `kind` rides along because the desktop report cannot otherwise tell an AURA from a
      -- BUTTON, and the two have completely different expectations about having an icon:
      -- auras live in the BUFF viewers, which `HudLayout.Scan` does not walk at all.  The
      -- first flight's tracked-but-not-displayed cross-check was unreadable without it.
      kind = e.kind,
    }
  end
  return out
end

local function readAssist()
  local p = ns.Assist.Probe()
  return { available = p.available.class, action = p.actionSpell.class,
           rotation = p.rotation.class, next0 = p.next0.class, next1 = p.next1.class,
           -- The VALUE too, when it read plainly — "readable in combat" is the rider's
           -- whole question and a class alone cannot show the answer was sensible.
           next0Value = ns.Stash(p.next0.value), next1Value = ns.Stash(p.next1.value) }
end

-- The layout, only on the transitions that can change it — a spec or hero swap is exactly
-- when the keybind ladder's fall-through is under test (Phase 3's Diabolist half).
local function readLayout()
  local layout = ns.HudLayout.Scan()
  local cds = ns.State.Build(false).cooldowns or {}
  local drew = {}
  for _, k in ipairs((ns.HudDriver.lastDraw and ns.HudDriver.lastDraw.keybinds) or {}) do
    drew[k.anchorTo] = k.keybind
  end
  local out = {}
  for cid, e in pairs(layout) do
    out[#out + 1] = { cid = cid, spellID = ns.Stash(e.spellID),
                      name = e.spellID and ns.SpellName(e.spellID) or nil,
                      key = cds[cid] and ns.Stash(cds[cid].keybind) or nil,
                      drew = ns.Stash(drew[cid]) }
  end
  table.sort(out, function(x, y) return x.cid < y.cid end)
  return out
end

function F.Snapshot(reason)
  local rows, unit, window = ns.State.AuraFrameCapability()
  local bs = ns.HudBinds.stats or {}
  local s = {
    at = GetTime(), reason = reason,
    combat = InCombatLockdown() and true or false,
    specID = ns.detectedSpecID, specName = ns.detectedSpecName,
    hero = ns.ActiveSpec and ns.ActiveSpec.heroResolution or nil,
    cov = readCoverage(),
    assist = readAssist(),
    aura = { rows = rows, unit = unit, window = window },
    binds = { bound = bs.bound, slots = bs.slots, scans = bs.scans },
    cues = ns.HudDriver.lastCues, keys = ns.HudDriver.lastKeys,
    err = ns.HudDriver.lastError,
  }
  s.key = F.Key({ specID = s.specID, hero = s.hero, combat = s.combat,
                  cov = s.cov, assist = s.assist })
  return s
end

function F.Sample(reason)
  if not F.armed then return end
  local store = ns.db.flight
  if type(store) ~= "table" or type(store.samples) ~= "table" then return end
  local s = F.Snapshot(reason)
  local last = store.samples[#store.samples]
  if last and last.key == s.key then return end
  if #store.samples >= CAP then return end
  -- The layout only on a real transition — on a 1 Hz tick it is 17 unchanged rows.
  if reason ~= "tick" then s.layout = readLayout() end
  store.samples[#store.samples + 1] = s
end

--------------------------------------------------------------------------------
-- Arm / disarm
--------------------------------------------------------------------------------
-- ⚠ ARMING WIPES THE RING.  A flight is one session by definition, and an extractor that
-- has to guess where the last pass ended is the ambiguity this whole file removes.
function F.Arm()
  ns.db.flight = { started = date and date("%Y-%m-%d %H:%M:%S") or "?",
                   version = ns.version, samples = {} }
  F.armed = true
  if not ev then
    ev = CreateFrame("Frame")
    -- The four transitions an acceptance criterion is written across.  Forced rather than
    -- left to the ticker so the combat-entry row — the most important one in the file — is
    -- never up to a second late.
    ev:RegisterEvent("PLAYER_REGEN_DISABLED")
    ev:RegisterEvent("PLAYER_REGEN_ENABLED")
    ev:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    ev:RegisterEvent("TRAIT_CONFIG_UPDATED")
    ev:SetScript("OnEvent", function(_, event)
      -- One frame later: Coverage invalidates on the same two build events and we want the
      -- REBUILT answer, not the one we raced.
      C_Timer.After(0, function() pcall(F.Sample, event) end)
    end)
  end
  if not ticker then ticker = C_Timer.NewTicker(PERIOD, function() pcall(F.Sample, "tick") end) end
  if not ns.HudOn() then ns.SetHud(true) end   -- the decision log needs the pipeline running
  F.Sample("arm")
end

function F.Disarm()
  F.armed = false
  if ticker then ticker:Cancel(); ticker = nil end
end

--------------------------------------------------------------------------------
-- The command
--------------------------------------------------------------------------------
local function count()
  local st = ns.db and ns.db.flight
  return (st and st.samples and #st.samples) or 0
end

ns.RegisterCommand("flight",
  "ARM THE ACCEPTANCE RECORDER — the one command an in-game pass needs. Turns the HUD on, "
  .. "then records every change of answer (coverage, assist, aura-frame, keybinds, layout) "
  .. "through combat, spec and hero swaps, with no further typing. Then /reload and run "
  .. "`wowkb.cdmp flight` for the PASS/FAIL report. 'off' stops it; 'status' shows progress.",
  function(rest)
    rest = (rest or ""):lower()
    if rest:find("off") then
      F.Disarm()
      return ns.Printf("flight recorder |cffff8080OFF|r — %d sample(s) held. "
        .. "|cffffffff/reload|r then |cffffffffwowkb.cdmp flight|r.", count())
    end
    if rest:find("status") then
      return ns.Printf("flight recorder %s — %d sample(s).",
        F.armed and "|cff88ff88ARMED|r" or "|cffff8080off|r", count())
    end
    F.Arm()
    ns.Heading("flight recorder |cff88ff88ARMED|r — now just play.")
    ns.Print("  1. pull a dummy as |cffffffffDestruction|r and play a normal rotation")
    ns.Print("  2. swap |cffffffffhero tree|r (Diabolist <-> Hellcaller) and pull again")
    ns.Print("  3. swap to |cffffffffDemonology|r and pull again")
    ns.Print("  4. |cffffffff/reload|r, then on the desktop: "
      .. "|cffffffffuv run python -m wowkb.cdmp flight|r")
    ns.Print("  |cff808080no further commands — combat entry, spec and hero swaps all "
      .. "record themselves. /cdmp flight status to check it is still counting.|r")
  end)
