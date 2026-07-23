-- HudGradTest.lua — DOES SetGradient ACTUALLY DO ANYTHING ON THIS CLIENT?  M4.6c.
--
-- WHY.  Three rounds of the white-cue investigation have now turned on an
-- assumption nobody verified: that `Texture:SetGradient` applies. It never
-- throws, so `pcall` proves nothing; the first watchdog tried to catch the
-- failure by reading `GetVertexColor` and returned 1/1/1 for EVERY level
-- including ones the player confirms render green — i.e. that read cannot see
-- the rendered colour at all, so it falsified nothing. Player, play-test 6:
-- "Doesn't look like we're getting gradients anywhere anymore?"
--
-- THE INSIGHT THAT MAKES THIS TESTABLE WITHOUT READING PIXELS.  We do not need
-- to know what the bar LOOKS like. We need to know how the API mutates state we
-- CAN read. `GetVertexColor` is readable, so run an ordered experiment on a
-- throwaway texture and record the readback after each step:
--
--   1. SetColorTexture(green)            -> does it set the vertex colour at all?
--   2. ...then SetGradient(green->soft)  -> does the gradient CLOBBER it back to white?
--   3. SetVertexColor(green)             -> does the plain setter work?
--   4. ...then SetGradient               -> same clobber question, other path
--   5. SetGradient FIRST, then SetColorTexture -> does the colour wipe the gradient?
--
-- Whatever the answers, they are FACTS about this client rather than inference,
-- and they decide the cue's paint order. The most likely single explanation of
-- the whole saga is step 2 returning white: that would mean SetGradient resets
-- the vertex colour, so a bar whose base was white (pre-v0.26.0) renders white
-- whenever the gradient itself fails to draw -- intermittently, exactly as
-- reported.
--
-- ⚠ WHAT THIS CANNOT TELL US: whether the gradient RENDERS. There is no pixel
-- readback. It tells us how the calls interact, which is the part we have been
-- guessing at. Say so in the output rather than overclaiming a third time.
--
-- Deliberately a ONE-SHOT on demand (`/cdmp gradtest`), not a ticker: it mutates
-- a scratch texture nobody draws, and it needs no combat, no pull, no timing.
local ADDON, ns = ...

ns.HudGradTest = {}
local G = ns.HudGradTest

local TEST = { 0.30, 1.00, 0.48 }        -- the ROTATION green, so results map
                                         -- directly onto the real cue paint
local scratch

local function ensureScratch()
  if scratch then return scratch end
  -- Parented to a hidden frame: this must never be visible, and must never share
  -- state with a live cue texture.
  local host = CreateFrame("Frame", nil, UIParent)
  host:Hide()
  host:SetSize(1, 1)
  scratch = host:CreateTexture(nil, "OVERLAY")
  scratch:SetSize(16, 16)
  return scratch
end

-- Read the vertex colour as three rounded numbers, or nil if the read fails.
local function readVC(t)
  local ok, r, g, b = pcall(t.GetVertexColor, t)
  if not ok or type(r) ~= "number" then return nil end
  local function q(x) return math.floor(x * 100 + 0.5) / 100 end
  return { q(r), q(g), q(b) }
end

local function fmt(c)
  if not c then return "<unreadable>" end
  return string.format("%.2f/%.2f/%.2f", c[1], c[2], c[3])
end

local function isWhite(c)
  return c and c[1] > 0.9 and c[2] > 0.9 and c[3] > 0.9
end

local function near(c, want)
  if not c then return false end
  for i = 1, 3 do if math.abs(c[i] - want[i]) > 0.06 then return false end end
  return true
end

-- Run the experiment; returns a plain-scalar table for the structured store.
function G.Run()
  local t = ensureScratch()
  local out = { at = date("%Y-%m-%d %H:%M:%S") }

  out.hasSetGradient   = ns.HasMethod(t, "SetGradient") and true or false
  out.hasSetVertex     = ns.HasMethod(t, "SetVertexColor") and true or false
  out.hasCreateColor   = (type(CreateColor) == "function")

  local function grad()
    local solid = CreateColor(TEST[1], TEST[2], TEST[3], 1.0)
    local soft  = CreateColor(TEST[1], TEST[2], TEST[3], 0.35)
    return pcall(t.SetGradient, t, "HORIZONTAL", solid, soft)
  end

  -- 1/2 — the CURRENT paint order (v0.26.0): colour texture, then gradient.
  pcall(t.SetColorTexture, t, TEST[1], TEST[2], TEST[3], 1)
  local afterColor = readVC(t)
  local gradOK = grad()
  local afterGrad = readVC(t)

  -- 3/4 — the same question via the plain vertex setter.
  pcall(t.SetTexture, t, "Interface\\Buttons\\WHITE8X8")
  pcall(t.SetVertexColor, t, TEST[1], TEST[2], TEST[3], 1)
  local afterVertex = readVC(t)
  grad()
  local afterVertexGrad = readVC(t)

  -- 5 — reverse order: does SetColorTexture WIPE a gradient set before it?
  grad()
  pcall(t.SetColorTexture, t, TEST[1], TEST[2], TEST[3], 1)
  local afterReverse = readVC(t)

  out.gradientCallOK    = gradOK and true or false
  out.afterColor        = fmt(afterColor)
  out.afterColorGrad    = fmt(afterGrad)
  out.afterVertex       = fmt(afterVertex)
  out.afterVertexGrad   = fmt(afterVertexGrad)
  out.afterReverse      = fmt(afterReverse)

  -- THE VERDICTS — each a direct consequence of one readback, so a reader can
  -- check the reasoning against the numbers above rather than trusting the label.
  out.colorTextureSetsVertex = near(afterColor, TEST)
  out.gradientClobbersVertex = (near(afterColor, TEST) and isWhite(afterGrad)) or
                               (near(afterVertex, TEST) and isWhite(afterVertexGrad))
  out.vertexSetterWorks      = near(afterVertex, TEST)
  G.last = out
  return out
end

function G.Report()
  local r = G.last or G.Run()
  ns.Heading("SetGradient behaviour on THIS client (M4.6c) — facts, not inference")
  ns.Printf("  API present: SetGradient=%s  SetVertexColor=%s  CreateColor=%s  call ok=%s",
    tostring(r.hasSetGradient), tostring(r.hasSetVertex),
    tostring(r.hasCreateColor), tostring(r.gradientCallOK))
  ns.Print("  readback of GetVertexColor after each step (target 0.30/1.00/0.48):")
  ns.Printf("    1. SetColorTexture(green)          -> %s", r.afterColor)
  ns.Printf("    2. ...then SetGradient             -> %s", r.afterColorGrad)
  ns.Printf("    3. SetVertexColor(green)           -> %s", r.afterVertex)
  ns.Printf("    4. ...then SetGradient             -> %s", r.afterVertexGrad)
  ns.Printf("    5. SetGradient then SetColorTexture-> %s", r.afterReverse)
  ns.Print(" ")
  if r.gradientClobbersVertex then
    ns.Print("  |cffffd100SetGradient RESETS the vertex colour to white.|r  That is the")
    ns.Print("  whole white-cue mystery: pre-v0.26.0 the base WAS white, so any frame")
    ns.Print("  where the gradient failed to draw rendered white — intermittently.")
  elseif not r.colorTextureSetsVertex then
    ns.Print("  |cffffd100SetColorTexture does NOT write the vertex colour|r — so the old")
    ns.Print("  watchdog was reading a channel the paint path never touches, which is")
    ns.Print("  why it reported white for every level including ones that render green.")
  else
    ns.Print("  No clobber seen: the vertex colour survives SetGradient.  That KILLS the")
    ns.Print("  reset hypothesis — the intermittent white came from somewhere else.")
  end
  ns.Print("  |cff808080⚠ This cannot see whether the gradient RENDERS — there is no pixel")
  ns.Print("  readback.  It establishes how the calls interact, nothing more.|r")
end
