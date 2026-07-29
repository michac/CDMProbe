-- HudProcGlow.lua — DIM Blizzard's NATIVE proc glow (the spell-activation overlay) on
-- the live CDM icons, so it stops burying OUR cue chrome.
--
-- WHY THIS EXISTS (docs/status.md — the "subdue the proc glow" backlog item).  The
-- Cooldown Manager lights a loud gold spell-activation overlay on a proc'd icon
-- (Demonic Core -> Demonbolt).  It renders ABOVE our dots/rings and stomps them.  The
-- decision: don't redraw or replace it — just turn its ALPHA down.  Setting alpha on
-- the ALERT FRAME multiplies the whole glow WITHOUT fighting the proc animation (which
-- drives the child TEXTURES' alpha, not the frame's) — the exact lever proven in the
-- rendertest preview (Renderer.lua applyProcGlow / clearProcGlow).
--
-- HOW.  Post-hook each CDM item's RefreshOverlayGlow (CooldownViewer.lua:1124 ->
-- ShowAlert at :1130) — the method that shows/hides the native glow.  Re-applying the
-- dim on every proc RISING EDGE means it can't creep back to full.  Per-INSTANCE hook:
-- the mixin methods are Mixin()-copied per frame, so a hook on the shared table would
-- miss every already-created frame (the same reason State.installAlertHooks hooks per
-- instance).
--
-- SCOPED BY CONSTRUCTION.  We only ever hook CDM item frames (ns.VIEWERS ->
-- ns.GetItemFrames), so the dim can never touch the player's action bars — no separate
-- membership gate is needed.
--
-- TAINT-SAFE: hooksecurefunc + SetAlpha are combat-legal.
local ADDON, ns = ...

ns.HudProcGlow = {}
local M = ns.HudProcGlow

local DIM = 0.5   -- native-proc-glow alpha while the HUD is on (tunable dial)

-- Post-hook one item INSTANCE's RefreshOverlayGlow, once.  Guarded by a per-instance
-- flag (the methods are Mixin()-copied per frame — a shared-table hook would miss
-- already-created frames).  The callback is gated on HUD-on so a stranded hook (which
-- hooksecurefunc can NEVER remove) is inert once the HUD is off.
local function hookItem(item)
  if not item or item.__glowHooked then return end
  if not ns.HasMethod(item, "RefreshOverlayGlow") then return end
  item.__glowHooked = true
  hooksecurefunc(item, "RefreshOverlayGlow", function(self)
    if not (ns.HudOn and ns.HudOn()) then return end
    local a = self.SpellActivationAlert
    if a then a:SetAlpha(DIM) end
  end)
end

-- Walk our tracked CDM item frames (State's robust enumeration).  Reused for the
-- one-time hook install, the immediate dim pass, and the restore.
local function forEachItem(fn)
  if not ns.VIEWERS then return end
  for _, v in ipairs(ns.VIEWERS) do
    local viewer = ns.GetViewer and ns.GetViewer(v.frame)
    if viewer then
      for _, item in ipairs(ns.GetItemFrames(viewer)) do
        fn(item)
      end
    end
  end
end

-- Install (idempotent) — hook every current CDM item frame, then dim any glow ALREADY
-- showing this instant.  RefreshOverlayGlow only fires on a CHANGE, so a glow that lit
-- before we hooked wouldn't get re-dimmed until it next toggled; this closes that gap.
-- Cheap enough to re-run each tick so newly-pooled frames get hooked.
function M.Install()
  forEachItem(function(item)
    hookItem(item)
    local a = item.SpellActivationAlert
    if a then a:SetAlpha(DIM) end
  end)
end

-- Restore — the HUD went off: return every tracked item's alert frame to full alpha.
-- The hooks STAY installed (hooksecurefunc can't be removed); the HudOn() gate is what
-- keeps them inert.
function M.Restore()
  forEachItem(function(item)
    local a = item.SpellActivationAlert
    if a then a:SetAlpha(1) end
  end)
end
