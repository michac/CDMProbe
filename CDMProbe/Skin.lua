-- Skin.lua — the visible experiment.  On Essential + Utility viewers, hide the
-- spell icon and paint a solid identity-colored block + short label, while
-- leaving Blizzard's *secure* Cooldown swipe running on top.  A low-frequency
-- watchdog re-applies after Blizzard re-lays-out / recycles item frames.
local ADDON, ns = ...

local SKIN_VIEWERS = { "EssentialCooldownViewer", "UtilityCooldownViewer" }
local ticker

-- Attach (once) our overlay widgets to a Blizzard item frame.
local function ensureOverlay(item)
  if item.__cdmp then return item.__cdmp end
  local o = {}

  local swatch = item:CreateTexture(nil, "ARTWORK", nil, 7) -- high sublevel: above the icon art
  swatch:SetAllPoints(item)
  o.swatch = swatch

  local label = item:CreateFontString(nil, "OVERLAY")
  label:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
  label:SetPoint("BOTTOM", item, "BOTTOM", 0, 1)
  o.label = label

  item.__cdmp = o
  return o
end

local function dimIcon(item, hidden)
  local icon = item.Icon
  if ns.HasMethod(icon, "SetAlpha") then
    icon:SetAlpha(hidden and 0 or 1)
  end
end

local function applyItem(item)
  local id = ns.ItemSpellID(item)
  local o = ensureOverlay(item)
  local r, g, b = ns.IdColor(id or 0)
  o.swatch:SetColorTexture(r, g, b, 0.92)
  local name = id and ns.SpellName(id)
  o.label:SetText(name and name:sub(1, 4):upper() or "?")
  dimIcon(item, true)
  o.swatch:Show()
  o.label:Show()
end

local function clearItem(item)
  local o = item.__cdmp
  if o then o.swatch:Hide(); o.label:Hide() end
  dimIcon(item, false)
end

local function forEachSkinItem(fn)
  for _, frameName in ipairs(SKIN_VIEWERS) do
    local viewer = ns.GetViewer(frameName)
    if viewer then
      local items = ns.GetItemFrames(viewer)
      for _, item in ipairs(items) do
        pcall(fn, item)   -- never let one weird frame break the sweep
      end
    end
  end
end

local function applyAll() forEachSkinItem(applyItem) end
local function clearAll() forEachSkinItem(clearItem) end

function ns.SetSkin(on)
  ns.db.skinOn = on and true or false
  if on then
    applyAll()
    if not ticker then ticker = C_Timer.NewTicker(0.5, applyAll) end -- watchdog
    ns.Print("skin |cff88ff88ON|r — Essential/Utility are now color blocks (icon hidden, Blizzard cooldown swipe kept).")
  else
    if ticker then ticker:Cancel(); ticker = nil end
    clearAll()
    ns.Print("skin |cffff8080OFF|r — Blizzard icons restored.")
  end
end

ns.RegisterCommand("skin", "toggle: hide icons -> color blocks on Essential+Utility (keeps the cooldown swipe)", function()
  ns.SetSkin(not ns.db.skinOn)
end)

-- Restore on login if it was left on.
function ns.RestoreSkin()
  if ns.db and ns.db.skinOn then
    C_Timer.After(1.0, function() ns.SetSkin(true) end)
  end
end
