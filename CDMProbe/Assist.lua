-- Assist.lua — ⚠ TEMPORARY DISCOVERY INSTRUMENT, MEANT TO BE DELETED.
--
-- In the AlertTape mould, and with the same end condition: it exists to answer ONE
-- question, and the moment the answer lands in
-- `knowledge/addon-dev/api-events-and-discovery.md` §2, delete this file, its `.toc` line
-- and the `assist`/`assist_on` saved-vars.  It is NOT in the pipeline and nothing reads it.
--
-- THE QUESTION.  Does `C_AssistedCombat.GetNextCastSpell()` return a READABLE spellID in
-- COMBAT?  If it does, Blizzard is handing us a ground-truth "what to press next" through
-- a channel that survives Secret Values — an independent oracle to diff the Coach against,
-- and a possible floor when everything else goes secret.  (Not a replacement: it is a
-- generic single-target rotation with no mode/AoE awareness and no burst planning, which
-- is the whole thing this project exists to do better.)
--
-- THE DESK READ SAYS YES, WHICH IS EXACTLY WHY IT NEEDS MEASURING.  From
-- `raw/addon-research/wow-ui-source` @ 4383ced (12.0.7.68887):
--   * `AssistedCombatDocumentation.lua` declares `GetNextCastSpell(checkForVisibleButton)
--     -> spellID` with NO Predicate entry at all.  Predicates are how the generated docs
--     declare when a return goes secret (security-taint-and-restricted-data.md §4.7);
--     the cooldown APIs carry them, this does not.
--   * Its `SecretArguments = "AllowedWhenUntainted"` governs whether a SECRET ARGUMENT may
--     be passed, not the return — the same annotation `C_SpellBook.IsSpellKnown` carries,
--     and roster-state-plan §6.1 already records that reading.  We pass a literal bool.
--   * `AssistedCombatManager.lua:323-336` calls it on an OnUpdate ticker and then does
--     `if spellID ~= self.lastNextCastSpellID` — a plain `~=` on the return, precisely the
--     operation §4.2's table says a secret cannot survive.  That code registers
--     PLAYER_REGEN_DISABLED and exists to run in combat.
-- This project's standing lesson is that a confident desk answer nobody flew is how the
-- keybind-cache bug survived — and Blizzard's own code being UNTAINTED means its evidence
-- is suggestive, not conclusive, for an addon caller.
--
-- TWO ADJACENT CALLS COME FREE.  `GetRotationSpells()` returns Blizzard's own list of the
-- spec's rotation spells — a second opinion on ROSTER COMPLETENESS, i.e. a cross-check for
-- the exact "did the author forget an ability?" risk §8 names.  `IsAvailable()` is the gate
-- to read first.
--
-- ⚠ DELIBERATELY SMALL.  `addon/CLAUDE.md`'s retired-`/cdmp probe` note says to add a
-- targeted command rather than resurrect the kitchen sink.  This is that command.
local ADDON, ns = ...

ns.Assist = {}
local A = ns.Assist

local CAP    = 200    -- ring rows kept (dedup by class keeps this tiny)
local PERIOD = 1.0    -- watch sample cadence

--------------------------------------------------------------------------------
-- The readability CLASS of a value — never the value itself.
--------------------------------------------------------------------------------
-- ⚠ `issecretvalue` IS ASKED BEFORE `type`, because `type()` returns the TRUE type of a
-- secret and therefore passes every subsequent test (security-taint-and-restricted-data.md
-- rule 13).  Getting this order wrong is how a secret reaches string.format.
local function classOf(v)
  if ns.IsSecret(v) then return "SECRET" end
  local t = type(v)
  if t == "table" then return ns.IsSecretTable(v) and "SECRET-table" or "table" end
  if t == "number" then return "num" end
  if t == "boolean" then return "bool" end
  if t == "nil" then return "nil" end
  return t
end

-- The guarded call, in Util.lua's house style: capability check, then pcall, then the
-- class.  An ABSENT namespace and a THROWING call are different findings and stay so.
local function call(name, ...)
  local C = C_AssistedCombat
  if type(C) ~= "table" or type(C[name]) ~= "function" then
    return { class = "absent" }
  end
  local ok, a, b = pcall(C[name], ...)
  if not ok then return { class = "threw", err = tostring(a) } end
  return { class = classOf(a), value = a, extra = b }
end

-- A spellID is only safe to name (or print) when it READ as a plain number.
local function nameOf(rec)
  if rec.class ~= "num" then return nil end
  return ns.SpellName(rec.value)
end

--------------------------------------------------------------------------------
-- A.Probe() — one sample of the whole surface.
--------------------------------------------------------------------------------
-- `GetNextCastSpell` is sampled on BOTH arguments: `false` asks the rotation outright,
-- `true` asks only for a spell with a visible button.  They can differ, and if only one of
-- them survives combat that is itself the answer.
function A.Probe()
  return {
    combat      = InCombatLockdown() and true or false,
    available   = call("IsAvailable"),
    actionSpell = call("GetActionSpell"),
    rotation    = call("GetRotationSpells"),
    next0       = call("GetNextCastSpell", false),
    next1       = call("GetNextCastSpell", true),
  }
end

-- The dedup key: the CLASSES, not the values.  A value change is noise here — the whole
-- question is whether the channel stays READABLE — and a class change is the answer.
-- This is AlertTape's idiom (`AlertTape.lua`, channel 2) reused deliberately.
function A.ClassKey(p)
  return table.concat({ p.combat and "combat" or "ooc", p.available.class,
                        p.actionSpell.class, p.rotation.class,
                        p.next0.class, p.next1.class }, "|")
end

--------------------------------------------------------------------------------
-- A.Lines(p) -> array of chat lines.  Split out of the command so busted can read the
-- readout without a chat frame, and so a secret can be proven never to reach a format.
--------------------------------------------------------------------------------
local function idLine(label, rec)
  local name = nameOf(rec)
  return string.format("  %-22s %s%s", label, rec.class,
    name and ("  (" .. name .. " " .. tostring(rec.value) .. ")") or "")
end

function A.Lines(p)
  local out = {}
  out[#out + 1] = string.format("  %-22s %s", "in combat", tostring(p.combat))
  -- IsAvailable returns (isAvailable, failureReason) — the gate to read first.
  local av = p.available
  out[#out + 1] = string.format("  %-22s %s%s", "IsAvailable()", av.class,
    (av.class == "bool")
      and ("  " .. tostring(av.value)
           .. (type(av.extra) == "string" and av.extra ~= "" and ("  \"" .. av.extra .. "\"") or ""))
      or "")
  out[#out + 1] = idLine("GetActionSpell()", p.actionSpell)
  -- The rotation list: ids only when the TABLE read plainly and each member reads plainly.
  local rot = p.rotation
  if rot.class == "table" then
    local parts, n = {}, 0
    local ok = pcall(function()
      for _, id in ipairs(rot.value) do
        n = n + 1
        if ns.IsSecret(id) then parts[#parts + 1] = "SECRET"
        else parts[#parts + 1] = string.format("%s(%s)", tostring(id), ns.SpellName(id) or "?") end
      end
    end)
    out[#out + 1] = string.format("  %-22s %s, %d entr%s", "GetRotationSpells()",
      ok and "table" or "threw-on-iterate", n, n == 1 and "y" or "ies")
    if ok and n > 0 then out[#out + 1] = "      " .. table.concat(parts, ", ") end
  else
    out[#out + 1] = string.format("  %-22s %s", "GetRotationSpells()", rot.class)
  end
  out[#out + 1] = idLine("GetNextCastSpell(false)", p.next0)
  out[#out + 1] = idLine("GetNextCastSpell(true)", p.next1)
  return out
end

--------------------------------------------------------------------------------
-- The watch ring — opt-in, OFF by default, recording only on a CLASS CHANGE.
--------------------------------------------------------------------------------
-- It is the only shape that answers "does it work in combat" without the player typing
-- during a GCD.  ⚠ SavedVariables flush on /reload, so read the ring after one.
local ticker

local function ringRow(p)
  return {
    t = GetTime(), key = A.ClassKey(p), combat = p.combat,
    available = ns.Stash(p.available.value),
    -- ns.Stash is the ONE guard for "this is about to be written to SavedVariables": a
    -- secret degrades to the STRING "<secret>" (itself the finding), a table drops to nil.
    next0 = ns.Stash(p.next0.value), next1 = ns.Stash(p.next1.value),
    next0Name = nameOf(p.next0), next1Name = nameOf(p.next1),
  }
end

function A.Sample()
  if not (ns.db and ns.db.assist_on) then return end
  local p = A.Probe()
  local key = A.ClassKey(p)
  local ring = ns.db.assist
  if type(ring) ~= "table" then ring = {}; ns.db.assist = ring end
  if ring[#ring] and ring[#ring].key == key then return end
  if #ring >= CAP then return end
  ring[#ring + 1] = ringRow(p)
end

function A.Watch(on)
  ns.db = ns.db or {}
  ns.db.assist_on = on and true or false
  if ticker then ticker:Cancel(); ticker = nil end
  if on then
    ticker = C_Timer.NewTicker(PERIOD, function() pcall(A.Sample) end)
    A.Sample()
  end
end

--------------------------------------------------------------------------------
-- The command
--------------------------------------------------------------------------------
local function dumpRing()
  local ring = (ns.db and ns.db.assist) or {}
  ns.Heading("assist watch ring — one row per READABILITY-CLASS change")
  if #ring == 0 then
    return ns.Print("  |cff808080empty|r — |cffffffff/cdmp assist watch|r to arm it "
      .. "(SavedVariables flush on /reload).")
  end
  for _, r in ipairs(ring) do
    ns.Printf("  %8.2f  %-6s  %s   next0=%s%s", r.t, r.combat and "combat" or "ooc", r.key,
      ns.Describe(r.next0), r.next0Name and ("  (" .. r.next0Name .. ")") or "")
  end
  ns.Printf("  %d row(s).", #ring)
end

ns.RegisterCommand("assist",
  "⚠ TEMPORARY probe of C_AssistedCombat — does GetNextCastSpell() survive combat? "
  .. "bare = one-shot readout; 'watch' arms a 1 Hz class-change sampler, 'off' stops it, "
  .. "'dump' reads the ring, 'clear' wipes it.",
  function(rest)
    rest = (rest or ""):lower()
    if rest:find("clear") then
      ns.db.assist = {}
      return ns.Print("assist ring cleared.")
    end
    if rest:find("dump") then return dumpRing() end
    if rest:find("off") then
      A.Watch(false)
      return ns.Print("assist watch |cffff8080OFF|r.")
    end
    if rest:find("watch") then
      A.Watch(true)
      return ns.Print("assist watch |cff88ff88ON|r — 1 Hz, recording only on a "
        .. "readability-CLASS change. Pull a dummy, then |cffffffff/reload|r and "
        .. "|cffffffff/cdmp assist dump|r.")
    end
    local p = A.Probe()
    ns.Heading("C_AssistedCombat — readability classes (never raw values)")
    for _, line in ipairs(A.Lines(p)) do ns.Print(line) end
    ns.Print("  |cff808080the answer to the open question is the CLASS of "
      .. "GetNextCastSpell in COMBAT. Run this mid-pull, or arm "
      .. "|cffffffff/cdmp assist watch|r|cff808080 and read the ring after a /reload.|r")
  end)

-- Re-arm across a /reload if it was left on (the watch is the whole point of the ring).
local prevOnLogin = ns.OnLogin
function ns.OnLogin()
  if prevOnLogin then prevOnLogin() end
  if ns.db and ns.db.assist_on then A.Watch(true) end
end
