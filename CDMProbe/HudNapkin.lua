-- HudNapkin.lua — the early-warning engine.  "When is this up?", answered.
--
-- WHY IT EXISTS.  The single most valuable thing this tool can do, per the user:
-- "firing cooldown abilities as soon as they are up is probably going to be the
-- biggest win — I believe that requires signalling me EARLY that they're going
-- to be ready."  Without anticipation, a dot flips NEVER -> ROTATION at the
-- INSTANT the cooldown lands, which mid-GCD is already too late to weave.  The
-- lead time IS the feature.
--
-- THE MECHANISM.  We cannot read a live cooldown remaining — that's a Secret Value.
-- But two things ARE readable: the moment a cast SUCCEEDS, and the spell's BASE
-- cooldown length (static spell metadata, notes.md §1).  So:
--
--     on UNIT_SPELLCAST_SUCCEEDED(player, _, spellID):
--         napkin[spellID] = { started = GetTime(), length = BaseCooldown(spellID) }
--     remaining(spellID) := max(0, started + length - GetTime())
--
-- THIS IS THE ONLY DRIFTING INPUT IN THE WHOLE DESIGN, and it is deliberately
-- fenced so drift can only ever make the HUD EARLY, never WRONG:
--
--   1. THE OBSERVED EDGE IS GROUND TRUTH AND ALWAYS WINS.  An `Available` alert
--      clears the napkin outright (State.lua calls N.Clear on that edge).  If CDR or
--      a reset proc brought the ability up early, the cue goes ROTATION at once
--      regardless of what the estimate said.
--      ⚠ CAVEAT, and it is a real one: State's readiness fold consults the napkin's
--      `on-cooldown` verdict BEFORE `readyEdge`, deliberately, to win the just-cast
--      race — so a genuine mid-cooldown RESET proc can be held back for as long as the
--      estimate says.  Backlogged in docs/status.md ("the napkin's ready-edge
--      precedence"); the honest fix compares the edge's timestamp against the napkin
--      record's start so a FRESH edge wins and only a STALE one loses.
--   2. EXPIRY NEVER CLAIMS READINESS.  If the estimate runs out with no edge
--      seen, the state is "should be up, unconfirmed" and is SHOWN as that.  We
--      never promote a dot to ROTATION on an estimate — that is the one thing
--      that would make the dot lie.  Haste-scaled recharge and CDR make the
--      estimate run long as often as short; the doctrine from notes.md §1 is
--      round down, fire early, and yield to the observed edge.
--   3. READABILITY IS CHECKED, NOT ASSUMED.  UNIT_SPELLCAST_SUCCEEDED's spellID is
--      readable in every combat context we have measured, and taken as settled.  The
--      check stays anyway, because the cost of being wrong is a feature that silently
--      tracks nothing: if it ever reads secret, this module counts it (`N.secret`)
--      rather than leaving the reader to infer it from a shrug.
--
-- TWO WAYS TO FILL ONE STORE.  Out of combat the client tells us the real remaining
-- time (ns.ReadCooldown), and that lands here as a record with `source = "read"` rather
-- than in a parallel store — one countdown, so N.Remaining and the SOON treatment need
-- no special case.  Only PROVENANCE differs.  Precedence between the three sources:
--   1. an OBSERVED ALERT EDGE always wins — `Available` clears seed and estimate alike;
--   2. a SEED overwrites a cast-derived ESTIMATE (the client's own number beats our
--      base-cooldown arithmetic);
--   3. an ESTIMATE fills only what neither of the above has.
local ADDON, ns = ...

ns.HudNapkin = {
  casts    = {},     -- spellID -> { started, length, source = "cast"|"read" }
  readable = nil,    -- nil = no player cast seen yet; true/false = spellID legible
  seen     = 0,      -- SUCCEEDED events with a readable spellID
  secret   = 0,      -- ...and with a secret one (the go-dark risk, counted)
  tracked  = 0,      -- ...of those, how many had a base cooldown worth tracking
  cleared  = 0,      -- napkins retired by an observed Available edge (ground truth)
  seeded   = 0,      -- records written from a real client read, not arithmetic
}
local N = ns.HudNapkin

-- ~2 GCDs of warning.  THIS is the number the in-game pass tunes: the early
-- warning has to arrive in time to actually change the next global, and if 3s
-- isn't enough lead, this is the knob (not the visuals).
N.SOON_LEAD = 3.0

local ev = CreateFrame("Frame")
local evStarted = false

local function onSucceeded(_, _, spellID)
  if ns.IsSecret(spellID) then
    N.secret = N.secret + 1
    -- Only ever DOWNGRADE to false from unknown; a single readable cast is
    -- enough to prove the channel works, and one secret one doesn't unprove it.
    if N.readable == nil then N.readable = false end
    return
  end
  if type(spellID) ~= "number" then return end
  N.seen = N.seen + 1
  N.readable = true
  local len = ns.BaseCooldown(spellID)
  -- 0 is meaningful, not a failure: Hand of Gul'dan and Demonbolt have no
  -- cooldown at all, so there is nothing to count down and we store nothing.
  if type(len) == "number" and len > 0 then
    N.casts[spellID] = { started = GetTime(), length = len, source = "cast" }
    N.tracked = N.tracked + 1
  end
end

-- File a countdown from a REAL READ.  `started`/`length` are the client's
-- own startTime/duration in GetTime() units, so N.Remaining's arithmetic is
-- unchanged; only the provenance differs.
--
-- Deliberately unconditional: a seed OVERWRITES a cast-derived estimate
-- (precedence 2 above).  A fresh cast then overwrites the seed in turn, which is
-- also right — it is the newer observation of the two.
function N.Seed(spellID, started, length)
  if type(spellID) ~= "number" then return end
  if type(started) ~= "number" or type(length) ~= "number" then return end
  if length <= 0 then return end
  N.casts[spellID] = { started = started, length = length, source = "read" }
  N.seeded = N.seeded + 1
end

-- "read" | "cast" | nil.  The row prints this so the two countdowns stay
-- tellable apart — `~42.1s (read)` is the client's number, `~1.8s (est)` is our
-- base-cooldown arithmetic, and they carry different confidence.
function N.SourceOf(spellID)
  local c = N.casts[spellID]
  if not c then return nil end
  return c.source or "cast"
end

-- Seconds until the estimate says this comes up.  nil = we have no napkin for
-- it (never cast it this session, or it has none); 0 = "should be up,
-- unconfirmed" — the estimate has run out and no edge has confirmed it.
function N.Remaining(spellID)
  local c = N.casts[spellID]
  if not c then return nil end
  local left = c.started + c.length - GetTime()
  if left < 0 then return 0 end
  return left
end

-- The estimate ran out but no Available edge has landed.  This is the honest
-- name for the drift case, and the row prints it verbatim.
function N.Unconfirmed(spellID)
  return N.Remaining(spellID) == 0
end

-- Ground truth arrived.  Called from State.lua on an observed Available edge.
function N.Clear(spellID)
  if type(spellID) ~= "number" then return end
  if N.casts[spellID] then
    N.casts[spellID] = nil
    N.cleared = N.cleared + 1
  end
end

function N.Start()
  if evStarted then return end
  evStarted = true
  ev:SetScript("OnEvent", function(_, _, unit, castGUID, spellID)
    -- RegisterUnitEvent already filters to the player; the pcall is because a
    -- throw in an event handler is silent and this must never take the HUD down.
    pcall(onSucceeded, unit, castGUID, spellID)
  end)
  ev:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
end

-- Drop every per-spellID estimate, keeping the event listener alive.  Public so the
-- spec resolver can wipe the previous spec's estimates on a swap (the napkin keys are
-- base spellIDs, spec-scoped).
function N.Reset()
  wipe(N.casts)
end
