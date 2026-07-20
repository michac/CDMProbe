-- HudNapkin.lua — the early-warning engine.  "When is this up?", answered.
--
-- WHY IT EXISTS.  The single most valuable thing this tool can do, per the user:
-- "firing cooldown abilities as soon as they are up is probably going to be the
-- biggest win — I believe that requires signalling me EARLY that they're going
-- to be ready."  Without anticipation, a dot flips NEVER -> ROTATION at the
-- INSTANT the cooldown lands, which mid-GCD is already too late to weave.  The
-- lead time IS the feature.
--
-- THE MECHANISM (promoted from Probes.lua's `casts` probe, which was logging
-- only).  We cannot read a live cooldown remaining — that's a Secret Value.  But
-- two things ARE readable: the moment a cast SUCCEEDS, and the spell's BASE
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
--      clears the napkin outright (HudState calls Clear on that edge).  If CDR or
--      a reset proc brought the ability up early, the dot goes ROTATION at once
--      regardless of what the estimate said.
--   2. EXPIRY NEVER CLAIMS READINESS.  If the estimate runs out with no edge
--      seen, the state is "should be up, unconfirmed" and is SHOWN as that.  We
--      never promote a dot to ROTATION on an estimate — that is the one thing
--      that would make the dot lie.  Haste-scaled recharge and CDR make the
--      estimate run long as often as short; the doctrine from notes.md §1 is
--      round down, fire early, and yield to the observed edge.
--   3. READABILITY IS CHECKED, NOT ASSUMED.  milestones.md §7 carries a STANDING
--      ASSUMPTION that UNIT_SPELLCAST_SUCCEEDED's spellID is readable in all
--      combat contexts.  It is confirmed in a delve and at an open-world dummy
--      and has NEVER been confirmed in a raid.  If it reads secret, this module
--      records that and `hud status` reports "napkin unavailable" rather than
--      silently tracking nothing.  A feature that goes dark in the content it
--      matters most in should be visible, not inferred later from a shrug.
local ADDON, ns = ...

ns.HudNapkin = {
  casts    = {},     -- spellID -> { started, length }
  readable = nil,    -- nil = no player cast seen yet; true/false = spellID legible
  seen     = 0,      -- SUCCEEDED events with a readable spellID
  secret   = 0,      -- ...and with a secret one (the raid-context risk, counted)
  tracked  = 0,      -- ...of those, how many had a base cooldown worth tracking
  cleared  = 0,      -- napkins retired by an observed Available edge (ground truth)
}
local N = ns.HudNapkin

-- ~2 GCDs of warning.  THIS is the number the in-game pass tunes: the early
-- warning has to arrive in time to actually change the next global, and if 3s
-- isn't enough lead, this is the knob (not the visuals).
N.SOON_LEAD = 3.0

local ev = CreateFrame("Frame")
local started = false

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
    N.casts[spellID] = { started = GetTime(), length = len }
    N.tracked = N.tracked + 1
  end
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

-- Ground truth arrived.  Called from HudState on an Available edge.
function N.Clear(spellID)
  if type(spellID) ~= "number" then return end
  if N.casts[spellID] then
    N.casts[spellID] = nil
    N.cleared = N.cleared + 1
  end
end

function N.Start()
  if started then return end
  started = true
  ev:SetScript("OnEvent", function(_, _, unit, castGUID, spellID)
    -- RegisterUnitEvent already filters to the player; the pcall is because a
    -- throw in an event handler is silent and this must never take the HUD down.
    pcall(onSucceeded, unit, castGUID, spellID)
  end)
  ev:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
end

function N.Stop()
  started = false
  ev:UnregisterAllEvents()
  wipe(N.casts)
end

-- Is the whole feature actually live?  Reported rather than assumed — see (3).
function N.StatusText()
  if N.readable == true then
    return string.format("|cff88ff88live|r — %d cast(s) read, %d tracked, %d cleared by a ready edge",
      N.seen, N.tracked, N.cleared)
  elseif N.readable == false then
    return string.format("|cffff4040unavailable|r — SUCCEEDED spellID reads <secret> here (%d event(s)); anticipation is OFF in this context", N.secret)
  end
  return "|cff808080not probed|r — cast something to find out"
end

function N.PrintStatus()
  ns.Printf("   napkin (anticipation, lead %.1fs): %s", N.SOON_LEAD, N.StatusText())
  if N.readable ~= true then return end
  for spellID, c in pairs(N.casts) do
    local left = math.max(0, c.started + c.length - GetTime())
    ns.Printf("     %s  base %ds  %s", ns.SpellName(spellID) or tostring(spellID),
      c.length, left > 0 and string.format("~%.1fs", left)
        or "|cffffd100should be up, unconfirmed|r")
  end
end
