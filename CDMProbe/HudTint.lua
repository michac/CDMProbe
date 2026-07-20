-- HudTint.lua — DORMANT.  Not wired to anything; nothing calls Install().
--
-- This is the leaf-method icon-repaint machinery discovered in M1 (notes.md §9,
-- feasibility questions F1/F5).  v1 leaves Blizzard's icons NATIVE and untouched
-- — desaturating + tinting them measurably hurt swipe/countdown legibility, which
-- defeats the point of keeping the icons at all — so this code is deliberately
-- inert.  It is KEPT, not deleted, for exactly one reason: it is the machinery an
-- optional solid-colour / green-phosphor mode would need, and rediscovering it
-- cost a whole build iteration.
--
-- The finding it encodes (source: Blizzard_CooldownViewer/CooldownViewer.lua @
-- 68453): Blizzard re-colours the icon from MANY paths, most of them OUTSIDE
-- RefreshData.
--   RefreshIconColor        — SPELL_UPDATE_USABLE (776), range-check (785),
--                             cooldownID-set (715): sets ITEM_USABLE_COLOR = WHITE
--   RefreshIconDesaturation — OnCooldownDone (743)
--   RefreshSpellTexture     — OnSpellUpdateIconEvent (191): SetTexture resets both
-- Hooking only RefreshData (v0.5.1) missed the usable/range paths and still
-- flashed white.  So: hook the three LEAF methods and re-force our colour AFTER
-- Blizzard, making us the last writer on every path.
--
-- These methods are Mixin()-copied onto EACH item frame, so a hook on the shared
-- mixin table would not reach already-created frames — hook the item INSTANCE,
-- guarded once per frame.
--
-- To revive: set ns.HudTint.enabled = true, point ns.HudTint.colorFor at a
-- spellID -> r,g,b function, and call ns.HudTint.Install(item) from HudCore's
-- bind pass.
local ADDON, ns = ...

ns.HudTint = { enabled = false, fires = 0, colorFor = nil }
local T = ns.HudTint

local LEAF = { "RefreshIconColor", "RefreshIconDesaturation", "RefreshSpellTexture" }

-- The light re-apply: only the two things Blizzard's leaf methods overwrite.
function T.Apply(item)
  local icon = item and item.Icon
  if not icon then return end
  local r, g, b = 1, 1, 1
  if T.colorFor then
    local ok, cr, cg, cb = pcall(T.colorFor, ns.ItemSpellID(item))
    if ok and cr then r, g, b = cr, cg, cb end
  end
  if ns.HasMethod(icon, "SetDesaturated") then icon:SetDesaturated(true) end
  if ns.HasMethod(icon, "SetVertexColor") then icon:SetVertexColor(r, g, b) end
  if ns.HasMethod(icon, "SetAlpha") then icon:SetAlpha(1) end   -- keep it, never hide
end

-- Undo: hand the icon back to Blizzard.
function T.Restore(item)
  local icon = item and item.Icon
  if not icon then return end
  if ns.HasMethod(icon, "SetDesaturated") then icon:SetDesaturated(false) end
  if ns.HasMethod(icon, "SetVertexColor") then icon:SetVertexColor(1, 1, 1) end
end

-- hooksecurefunc can never be undone, so every callback is gated on T.enabled —
-- which is false, which is why installing this is currently a no-op at runtime.
function T.Install(item)
  if item.__hudTintHooked then return end
  local hooked = false
  for _, method in ipairs(LEAF) do
    if ns.HasMethod(item, method) then
      hooksecurefunc(item, method, function(self)
        if T.enabled then T.fires = T.fires + 1; T.Apply(self) end
      end)
      hooked = true
    end
  end
  item.__hudTintHooked = hooked
end
