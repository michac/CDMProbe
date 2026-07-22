-- HudLog.lua — the PULL RECORDER.  M3e.
--
-- WHY THIS EXISTS.  Six milestones of code are shipped and three in-game passes
-- (§7.3, §7.4, §7.5) are stacked unclosed behind ONE measurement the tooling
-- cannot take.  §7.3 item 6 is the criterion all three inherit:
--
--     "In combat, `lit now` names 1-2 abilities and every reason holds up.
--      If it sits at 4+, tighten the RULES in HudScore — do not touch a colour."
--
-- and `lit now` is a SNAPSHOT YOU HAVE TO TYPE MID-PULL.  So the exit criterion
-- of three milestones was being answered from memory, after the fight, about a
-- line nobody could read while it mattered.
--
-- This is the same shape Probe.lua fixed once already (its header): six commands
-- that each had to be toggled BEFORE the interesting thing happened, replaced by
-- one always-recording report.  Strictness is the same class of thing — it is a
-- property of the moments you were BUSIEST, which are precisely the moments you
-- were not typing.  The same fix, pointed at the score.
--
--------------------------------------------------------------------------------
-- TWO STRUCTURES, and the split is the whole design
--------------------------------------------------------------------------------
--   * `events` — a ring of TRANSITIONS.  Written only when something CHANGES,
--     never per sample.  { at, kind, text }, kind in
--     dot | ready | mode | cap | cast | seed | combat | aoe | queue.
--     (`queue` = the M3c-c2 opener: armed / advanced / dissolved.)
--   * `hist`  — a HISTOGRAM of the lit count, bumped on every Recompute while in
--     combat: hist[n] = hist[n] + 1 where n = dots at ROTATION or LATE.
--
-- ⚠ A HISTOGRAM, NOT AN AVERAGE, and that is the point.  §7.3 item 6 asks
-- whether the board SITS at 4+.  A mean hides a board that is quiet 90% of the
-- time and lights five dots during every Tyrant window — the exact failure mode
-- "strictness" is about.  The distribution answers it; one number does not.
--
-- ⚠ SAMPLING AND TRANSITIONS MUST NOT SHARE A PATH.  A transition costs a
-- table.concat of the reasons (HudScore.Why); a sample costs one integer
-- increment.  Recompute runs at 4 Hz PLUS every edge, so the sample path stays
-- free of string work: Sample() returns true only on a NEW PEAK, and only then
-- does the caller pay to build the reason strings (see S.Recompute's tail).
--
--------------------------------------------------------------------------------
-- THE STORE
--------------------------------------------------------------------------------
-- On PLAYER_REGEN_ENABLED the pull closes and its summary is appended to a ring
-- of the last 5 pulls in SavedVariables.  NOTHING IS TYPED AND NOTHING IS
-- PRINTED — that is the milestone: if you had to ask for it, the recording would
-- again be scheduled against events that cannot be scheduled.
--
-- ⚠ STORED STRUCTURED, NOT THROUGH THE CAPTURE BUFFER.  ns.Print writes to
-- DEFAULT_CHAT_FRAME unconditionally (Core.lua), so driving BeginCapture /
-- EndCapture at every pull end would dump the whole report into chat every time
-- you left combat.  A table goes into ns.db.pulls instead — SavedVariables IS a
-- Lua file, so CDMProbeDB.pulls[3].hist reads perfectly off disk.
--
-- ⚠ THE /reload FLUSH TRAP IS UNCHANGED (Probe.lua:20-22).  SavedVariables only
-- flush on reload/logout, so a stale file looks EXACTLY like a recorder that
-- silently did nothing.  The readout restates it every time, on purpose.
local ADDON, ns = ...

ns.HudLog = {}
local L = ns.HudLog

local RING       = 256    -- transitions kept per pull
local PULLS      = 5      -- pulls kept on disk
local EVENT_TAIL = 40     -- events the short readout prints

local function now() return GetTime() end

local function newBuffer()
  return {
    opened  = now(),      -- when this buffer started collecting (the PROLOGUE)
    t0      = nil,        -- when combat started; nil until BeginPull
    events  = {},         -- circular, indexed 1..RING
    n       = 0,          -- total transitions ever written to this buffer
    hist    = {},         -- lit-count -> samples
    samples = 0,
    peak    = nil,        -- worst lit count seen
    peakAt  = nil,
    peakSet = nil,        -- the lit list WITH REASONS at that moment
  }
end

-- Always collecting.  Between pulls this buffer keeps the PROLOGUE — the seeding
-- pass that ran when you left the last fight, a /reload, a keybind rescan — and
-- rolls it into the next pull, which is exactly where §7.4's "what did a reload
-- actually seed?" question wants to read it.
L.cur  = newBuffer()
L.last = nil              -- the most recently closed pull, this session

--------------------------------------------------------------------------------
-- Writing
--------------------------------------------------------------------------------

-- A TRANSITION.  Callers must only reach here when something actually moved —
-- this is the path that is allowed to cost strings.
function L.Note(kind, text)
  local c = L.cur
  if not c then return end
  c.n = c.n + 1
  local slot = (c.n - 1) % RING + 1
  local e = c.events[slot]
  if e then
    e.at, e.kind, e.text = now(), kind, text     -- reuse; the ring is bounded
  else
    c.events[slot] = { at = now(), kind = kind, text = text }
  end
end

-- A SAMPLE.  One integer increment and two compares — no allocation, no strings.
-- Returns true when this sample set a NEW PEAK, which is the caller's cue (and
-- the ONLY cue) to pay for building the reason strings and hand them to L.Peak.
function L.Sample(n)
  local c = L.cur
  if not c or type(n) ~= "number" then return false end
  -- Out of combat the board is a resting state, not a measurement: §7.3's
  -- question is about the moments you were busy.  (InCombatLockdown is the
  -- secure-API lockdown flag — readable and branchable, the same precedent
  -- HudState's quiet() and B6's LATE gate already stand on.)
  if not InCombatLockdown() then return false end
  c.hist[n] = (c.hist[n] or 0) + 1
  c.samples = c.samples + 1
  if c.peak == nil or n > c.peak then
    c.peak, c.peakAt = n, now()
    return true
  end
  return false
end

function L.Peak(list)
  local c = L.cur
  if c then c.peakSet = list end
end

--------------------------------------------------------------------------------
-- Pull boundaries
--------------------------------------------------------------------------------

function L.BeginPull()
  local c = L.cur
  if not c then c = newBuffer(); L.cur = c end
  -- The prologue is KEPT (it is the run-up to this pull); only the clock is
  -- based, and the distribution starts empty so one pull's histogram is never
  -- contaminated by the last one's.
  c.t0 = now()
  c.hist, c.samples = {}, 0
  c.peak, c.peakAt, c.peakSet = nil, nil, nil
  L.Note("combat", "entered combat")
end

-- Snapshot a live buffer into a plain, disk-shaped table.  Times go RELATIVE to
-- the pull start here (once), so nothing downstream has to know about GetTime.
function L.Freeze(c)
  if not c then return nil end
  local base  = c.t0 or c.opened
  local kept  = math.min(c.n, RING)
  local start = c.n - kept
  local out = {
    at      = date("%Y-%m-%d %H:%M:%S"),
    version = ns.version,
    dur     = c.t0 and (now() - c.t0) or 0,
    samples = c.samples,
    hist    = {},
    peak    = c.peak,
    peakT   = c.peakAt and (c.peakAt - base) or nil,
    peakSet = c.peakSet,
    events  = {},
  }
  for k, v in pairs(c.hist) do out.hist[k] = v end
  for i = 1, kept do
    local e = c.events[(start + i - 1) % RING + 1]
    if e then
      out.events[#out.events + 1] = { t = e.at - base, kind = e.kind, text = e.text }
    end
  end
  if out.samples == 0 and #out.events == 0 then return nil end
  return out
end

function L.EndPull()
  local c = L.cur
  L.Note("combat", "left combat")
  local rec = L.Freeze(c)
  L.cur = newBuffer()
  if not rec then return end
  L.last = rec
  if not ns.db then return end                  -- pre-ADDON_LOADED; nothing to do
  ns.db.pulls = ns.db.pulls or {}
  local p = ns.db.pulls
  p[#p + 1] = rec
  while #p > PULLS do table.remove(p, 1) end
end

--------------------------------------------------------------------------------
-- The readout
--------------------------------------------------------------------------------

-- The histogram as ONE line.  Buckets at 4+ are coloured because they are the
-- finding: a fat 4+ tail is the instruction to tighten HudScore's RULES.
local function histLine(p)
  if not p.samples or p.samples == 0 then return "|cff808080no samples in combat|r" end
  local maxN = 0
  for k in pairs(p.hist) do if k > maxN then maxN = k end end
  local parts = {}
  for n = 0, maxN do
    local c = p.hist[n]
    if c then
      local pct = math.floor(c / p.samples * 100 + 0.5)
      parts[#parts + 1] = (n >= 4)
        and string.format("|cffff4040%d:%d%%|r", n, pct)
        or string.format("%d:%d%%", n, pct)
    end
  end
  return table.concat(parts, " ")
end

-- The verdict §7.3 item 6 asks for, stated rather than left to a feeling.
local function verdict(p)
  if not p.samples or p.samples == 0 then
    return "|cff808080no in-combat samples — pull something|r"
  end
  local fat = 0
  for n, c in pairs(p.hist) do if n >= 4 then fat = fat + c end end
  local pct = fat / p.samples * 100
  if pct >= 10 then
    return string.format("|cffff4040%.0f%% of the pull sat at 4+ lit|r — the RULES are too loose (tighten HudScore, not a colour)", pct)
  elseif pct > 0 then
    return string.format("|cffffd100%.0f%% at 4+|r — spiky but not resident; look at the peak set before touching anything", pct)
  end
  return "|cff88ff88never above 3 lit|r — strictness is holding"
end

-- `n` = how many trailing events to print (nil = EVENT_TAIL, 0 = none).
function L.Summary(p, tail)
  if not p then return ns.Print("  |cff808080no pull recorded|r") end
  ns.Printf("  |cffffd100%s|r  (v%s)   duration %.1fs   samples %d",
    p.at or "?", p.version or "?", p.dur or 0, p.samples or 0)
  ns.Printf("   lit %s", histLine(p))
  ns.Printf("   -> %s", verdict(p))
  if p.peak then
    ns.Printf("   peak: |cffffd100%d lit|r at +%.1fs", p.peak, p.peakT or 0)
    for _, s in ipairs(p.peakSet or {}) do ns.Printf("     %s", s) end
    if not p.peakSet or #p.peakSet == 0 then
      ns.Print("     |cff808080(no reasons captured — the peak was 0 lit)|r")
    end
  end
  tail = tail or EVENT_TAIL
  if tail > 0 and p.events and #p.events > 0 then
    local from = math.max(1, #p.events - tail + 1)
    ns.Printf("   events (%d of %d):", #p.events - from + 1, #p.events)
    for i = from, #p.events do
      local e = p.events[i]
      ns.Printf("    %+7.2fs %-6s %s", e.t or 0, e.kind or "?", e.text or "")
    end
  end
end

-- `/cdmp hud log` renders this.  `all` walks the whole on-disk ring.
function L.Print(all)
  ns.Heading(string.format("HUD pull log — M3e   (recording: %s)",
    (ns.Hud and ns.Hud.on) and "|cff88ff88on|r" or "|cffff4040HUD is OFF — nothing is being recorded|r"))
  local p = ns.db and ns.db.pulls or {}
  if all then
    if #p == 0 then return ns.Print("  |cff808080no pulls on record this session|r") end
    for i = 1, #p do
      ns.Printf(" |cff88ff88pull %d of %d|r", i, #p)
      L.Summary(p[i], 0)
    end
    ns.Print("  |cff808080(event tails are omitted for the ring — `hud log` prints the last pull's in full)|r")
  else
    L.Summary(p[#p] or L.last)
  end
  -- Restated EVERY time, deliberately: a stale file is indistinguishable from a
  -- recorder that did nothing, and that has cost us a session before.
  ns.Print("  |cffffd100/reload|r before reading CDMProbeDB.pulls off disk — SavedVariables only flush on reload/logout.")
end
