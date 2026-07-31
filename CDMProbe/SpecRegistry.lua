-- SpecRegistry.lua — the spec registry + active-spec resolver (multi-spec Phase 1).
--
-- THE SEAM.  Before this file, SpecDemonology.lua clobbered ns.SpecIDs / SpecInfo /
-- SpecPowerDelta / … unconditionally at load — two specs could never coexist, because
-- the last file loaded owned the globals.  Now each spec file self-registers a `spec`
-- OBJECT into ns.Specs (keyed by numeric specID), and the resolver DERIVES the legacy
-- ns.Spec* globals from whichever spec is active.  Every existing consumer keeps reading
-- ns.SpecIDs / ns.SpecInfo / … untouched — only this file knows a swap is possible.
--
-- Phase 5 makes activation DYNAMIC: the resolver below reads the player's real spec on
-- login and on PLAYER_SPECIALIZATION_CHANGED, activates the matching REGISTERED spec, or
-- goes passive (ActiveSpec = nil + a status line) when none is registered.  Registration
-- stays static per spec file; only *which* spec is active is now detected, not hardcoded.
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
-- contract the "no profile for <spec>" UX is built on.  `ns.Specs` is the only statement
-- of which specs have a profile; any spec absent from it resolves to this passive state,
-- by design.
function ns.SetActiveSpec(specID)
  local spec = ns.Specs[specID]
  ns.ActiveSpec = spec
  for _, k in ipairs(ns.SpecFields) do
    ns[k] = spec and spec[k] or nil
  end
end

-- BUILD-SCOPED CACHE INVALIDATION.  A spec brain may cache a fact that is constant for a
-- BUILD but not for a character.  Such a spec exposes `Invalidate()`; this drops EVERY
-- registered spec's cache, not just the active one, so swapping away and back cannot
-- resurrect a stale answer.  pcall'd: it runs from event handlers, where a throw must
-- never wedge the resolver.
-- ⚠ No spec implements `Invalidate` today — Destruction's hero-tree cache moved into
-- State (invalidated on SPELLS_CHANGED with the rest of the client reads).  The seam is
-- kept because it is the sanctioned place for the next build-scoped cache; if you add
-- one, this is already wired to the two events that can move it.
function ns.InvalidateSpecCaches()
  for _, spec in pairs(ns.Specs) do
    if type(spec.Invalidate) == "function" then pcall(spec.Invalidate, spec) end
  end
end

--------------------------------------------------------------------------------
-- Phase 5 — the live resolver.
--------------------------------------------------------------------------------
-- Detect the player's real spec and activate the matching REGISTERED profile, or clear
-- to passive when none is registered.  Everything here is pure Lua (SetActiveSpec is a
-- table rebind, the cache clears are wipes/flag-flips), so it is taint-free and safe to
-- run in combat — combat spec swaps are NOT deferred.  `ns.detectedSpecID/Name` are
-- stashed even for an unsupported spec so the status line can name what we saw.
function ns.ResolveActiveSpec()
  local idx = GetSpecialization and GetSpecialization()
  if not idx then return end   -- no spec chosen yet (fresh char) — leave passive, no churn
  local specID, specName = GetSpecializationInfo(idx)
  if type(specID) ~= "number" then return end   -- unreadable / secret — leave state as-is

  local changed = (specID ~= ns.detectedSpecID)
  ns.detectedSpecID   = specID
  ns.detectedSpecName = specName
  -- Already resolved to this exact spec (supported or passive) — nothing to rebind.
  if not changed and ns.ActiveSpec == ns.Specs[specID] then return end

  ns.SetActiveSpec(specID)   -- activate the registered spec, or clear to passive

  if changed then
    -- New spec: drop caches scoped to the PREVIOUS spec so the new one never reads a
    -- stale per-spellID estimate.  HudBinds self-invalidates on the same event, but the
    -- napkin has no listener of its own — this is the one cache the resolver must clear.
    -- pcall'd: these run inside an event handler, where a throw must never wedge the swap.
    -- ⚠ DIRECT calls inside the pcall — no `ns.X and ns.X.Y` existence guard.  A guard here
    -- would turn a renamed Reset into "the napkin silently keeps the old spec's estimates
    -- across a respec", which is the same silent-no-op class as the v0.32.25 outage.  The
    -- pcall reports a real throw; a missing definition is a bug and should be one.
    pcall(ns.HudNapkin.Reset)
    pcall(ns.HudBinds.Invalidate)
    ns.InvalidateSpecCaches()
  end
end

-- Initial detection: fold into the ns.OnLogin chain.  SpecRegistry loads right after
-- Probe (which defines the base ns.OnLogin), so `prev` is Probe's body; HudDriver's outer
-- wrapper runs this whole chain BEFORE its C_Timer SetHud(true), so ActiveSpec is resolved
-- before the HUD ever enables.
local prevOnLogin = ns.OnLogin
function ns.OnLogin()
  if prevOnLogin then prevOnLogin() end
  ns.ResolveActiveSpec()
end

-- Live swaps: a small event frame of our own (HudBinds' frame reacts too — both fine).
--
-- TRAIT_CONFIG_UPDATED is the second registration and it is NOT redundant (field-fix B): a
-- HERO-tree swap changes the build without changing the spec, so PLAYER_SPECIALIZATION_
-- CHANGED never fires for it and a hero cache keyed only on that event would stay stale
-- until relog.  Resolve on both; the resolver early-returns when nothing actually changed,
-- so the extra event costs a couple of table reads.
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
ev:RegisterEvent("TRAIT_CONFIG_UPDATED")
ev:SetScript("OnEvent", function(_, event)
  if event == "TRAIT_CONFIG_UPDATED" then pcall(ns.InvalidateSpecCaches) end
  pcall(ns.ResolveActiveSpec)
end)
