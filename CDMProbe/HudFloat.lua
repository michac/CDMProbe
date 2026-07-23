-- HudFloat.lua — floating reward text over the character.  E (M4.4).
--
-- The loudest member of the C/D/E cast-feedback family: after a BURST-window
-- press lands, the ability's name floats up over the character and fades.  It
-- fires AFTER the cast and only echoes what you DID, so it carries no instruction
-- — it is the payoff for landing the burst (A3's "make BURST shout"), never a
-- call.  Audio stays M6; this is visual-only (the HudChrome no-PlaySound fence is
-- untouched).
--
-- POOLED rising/fading FontStrings (the M1 idiom, known-feasible).  Each float
-- animates up ~40px over ~1.2s while fading, then returns to the pool.  Anchored
-- to the player NAMEPLATE when shown, falling back to a fixed screen point above
-- centre when the personal nameplate is off (availability varies by setting).
local ADDON, ns = ...

ns.HudFloat = {}
local F = ns.HudFloat

local RISE = 40     -- px risen over the lifetime
local DUR  = 1.2    -- seconds, rise + fade
local POOL = {}     -- reusable FontStrings, returned on animation finish
local host          -- a UIParent child that owns the floats

local function ensureHost()
  if host then return host end
  host = CreateFrame("Frame", nil, UIParent)
  host:SetFrameStrata("HIGH")   -- above the world, below full-screen dialogs
  host:SetSize(1, 1)
  return host
end

-- Anchor a float over the player: the personal nameplate when it exists, else a
-- fixed screen point above centre.  The nameplate anchor is pcall'd — anchoring
-- to a protected frame is normally fine, but a fallback keeps it working if the
-- nameplate is off (or the SetPoint is ever refused).
local function anchor(fs)
  fs:ClearAllPoints()
  local np = C_NamePlate and C_NamePlate.GetNamePlateForUnit
    and C_NamePlate.GetNamePlateForUnit("player")
  if np and pcall(fs.SetPoint, fs, "BOTTOM", np, "TOP", 0, 12) then return end
  fs:ClearAllPoints()
  fs:SetPoint("CENTER", UIParent, "CENTER", 0, 140)
end

local function acquire()
  local fs = table.remove(POOL)
  if fs then return fs end
  fs = ensureHost():CreateFontString(nil, "OVERLAY")
  local ag = fs:CreateAnimationGroup()
  local tr = ag:CreateAnimation("Translation")
  tr:SetDuration(DUR); tr:SetOffset(0, RISE); tr:SetSmoothing("OUT")
  local fade = ag:CreateAnimation("Alpha")
  fade:SetFromAlpha(1); fade:SetToAlpha(0); fade:SetDuration(DUR); fade:SetSmoothing("IN")
  ag:SetScript("OnFinished", function()
    fs:Hide()
    POOL[#POOL + 1] = fs
  end)
  fs.ag = ag
  return fs
end

-- text — the ability name.  opts.loud makes it bigger + gold (Tyrant reads
-- loudest, mirroring A3's cue-bar emphasis).
function F.Say(text, opts)
  if type(text) ~= "string" or text == "" then return end
  opts = opts or {}
  local fs = acquire()
  ns.SetFont(fs, opts.loud and 32 or 22, "OUTLINE")
  if opts.loud then
    fs:SetTextColor(1.00, 0.86, 0.35)   -- gold: the loudest reward (Tyrant)
  else
    fs:SetTextColor(0.92, 0.96, 1.00)   -- near-white
  end
  fs:SetText(text)
  anchor(fs)
  fs:SetAlpha(1)
  fs:Show()
  fs.ag:Stop()
  fs.ag:Play()
end
