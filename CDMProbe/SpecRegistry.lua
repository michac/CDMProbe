-- SpecRegistry.lua — the spec registry + active-spec resolver (multi-spec Phase 1).
--
-- THE SEAM.  Before this file, SpecDemonology.lua clobbered ns.SpecIDs / SpecInfo /
-- SpecPowerDelta / … unconditionally at load — two specs could never coexist, because
-- the last file loaded owned the globals.  Now each spec file self-registers a `spec`
-- OBJECT into ns.Specs (keyed by numeric specID), and the resolver DERIVES the legacy
-- ns.Spec* globals from whichever spec is active.  Every existing consumer keeps reading
-- ns.SpecIDs / ns.SpecInfo / … untouched — only this file knows a swap is possible.
--
-- Phase 1 sets the active spec STATICALLY (SpecDemonology self-activates 266 at load).
-- Live spec-detection on login / PLAYER_SPECIALIZATION_CHANGED is Phase 5.
local ADDON, ns = ...

ns.Specs = ns.Specs or {}

-- The exported surface a spec owns.  The resolver rebinds EXACTLY these fields from the
-- active spec, so every existing `ns.Spec*` call site keeps working with zero churn.
-- Because the field names are identical to today's global names, the rebind is a straight
-- `ns[k] = spec[k]` copy — no per-field translation.
ns.SpecFields = {
  "SpecGroups", "SpecIDs", "SpecBindAlias", "SHARD_CAP", "Spec",
  "SpecNoCue", "SpecProcGlow", "SpecStacks", "SpecOpener", "SpecBurst",
  "SpecInfo", "SpecColor", "SpecPole", "SpecGhost", "SpecPowerDelta",
}
-- NOTE: `spec.powers` (the Phase-3 resource array) is deliberately NOT a SpecField —
-- State reads it off ns.ActiveSpec.powers directly (the same object-read pattern Phase 2
-- used for self.SHARD_CAP), so ns stays uncluttered by a rarely-read array.

-- Register a spec object under its numeric specID.  Called at load by each spec file.
function ns.RegisterSpec(specID, spec)
  ns.Specs[specID] = spec
end

-- Set the active spec and re-bind the legacy globals from it.  An unknown/unsupported
-- specID leaves ActiveSpec = nil and CLEARS every legacy field to nil — the passive-HUD
-- contract Phase 5 builds its "no profile for <spec>" UX on.  Phase 1 only ever activates
-- Demonology (266).
function ns.SetActiveSpec(specID)
  local spec = ns.Specs[specID]
  ns.ActiveSpec = spec
  for _, k in ipairs(ns.SpecFields) do
    ns[k] = spec and spec[k] or nil
  end
end
