-- HudLayout.lua — the LIVE Layout + registry source for the W4 pipeline (Phase 5a).
--
-- WHY THIS EXISTS (docs/archive/w4-phase5-cutover-plan.md 5a, architecture.md Stage-3).  The
-- Binder (Stage 3) merges the Coach's cooldownID-keyed Guidance with a **Layout** —
-- geometry/identity per displayed icon, keyed the SAME way — and the Renderer (Stage 4)
-- needs a **registry** mapping each handle to its live Blizzard item frame.  Both come
-- from the SAME walk of the CDM icon viewers: `HudCore.rebind()` already walks exactly
-- those frames (cooldownID + spellID + item frame per icon) and `State.itemFrameMap()`
-- already maps cooldownID -> frame.  This is that walk RE-HOMED as a clean producer:
--
--   layout[cooldownID]   = { spellID = <base>, side = "TOPRIGHT" }   -> the Binder
--   registry[cooldownID] = <Blizzard item frame>                     -> the Renderer
--
-- Two design points the cutover plan pins down:
--   * cooldownID keys are **NUMBERS** (key-type consistency #5).  Live State keys
--     `cooldowns` by number, the Coach's cue keys are those same numbers, so the
--     Layout and the registry must key by number too — else the Binder's
--     layout-presence filter drops every cue silently.  (The golden JSON used string
--     keys; that is a fixture artefact, internally consistent there.)
--   * `spellID` is the **BASE** id (`ns.ItemBaseSpellID`).  The keybind seam resolves
--     off the base (the v0.7.0 finding-3 rule: the action bar holds the base spell,
--     not a Demonic Art override), so the Binder looks the keybind up by this id.
--   * `side` is carried but NOT yet consumed — v1 draws every dot in the TOPRIGHT
--     corner (cutover decision 2).  The field keeps the door open for a later
--     per-icon side without a Layout shape change.
--
-- THE PURE / IMPURE SPLIT.  `Build(entries)` is a PURE function of a list of resolved
-- `{ cooldownID, spellID, frame }` records -> (layout, registry); busted arbitrates it
-- (hudlayout_spec.lua).  `Scan()` is the impure half: it walks the live icon viewers,
-- resolves each item's ids the same Secret-Value-guarded way the rest of the addon
-- does, and hands the records to Build.  Nothing here draws — 5a is inspection only.
local ADDON, ns = ...

ns.HudLayout = {}
local L = ns.HudLayout

-- The icon viewers that get cue dots (the pressable rows).  Buff viewers carry procs,
-- not press cues, so they are NOT in the Layout — mirrors HudCore's ICON_VIEWERS.
local ICON_VIEWERS = { "EssentialCooldownViewer", "UtilityCooldownViewer" }

-- v1: every dot rides the icon's upper-right corner (cutover decision 2).  Carried on
-- each entry so a later per-icon side is a data change, not a Layout-shape change.
L.SIDE = "TOPRIGHT"

--------------------------------------------------------------------------------
-- Build — PURE.  A list of resolved icon records -> (layout, registry).
--------------------------------------------------------------------------------
-- Each `entries[i]` = { cooldownID = <number>, spellID = <base or nil>, frame = <any> }.
-- An entry whose cooldownID is not a number is DROPPED (an unreadable/secret id can't
-- key a table — keying a Secret Value taints).  FIRST cooldownID wins, so a spell
-- tracked under two cooldownIDs keeps the first frame (mirrors State.itemFrameMap's
-- `if not map[cid]` dedup).  layout carries only { spellID, side }; the frame lives in
-- the registry (the Binder must never see a live frame — invariant #6).
function L.Build(entries)
  local layout, registry = {}, {}
  for _, e in ipairs(entries or {}) do
    local cid = e.cooldownID
    if type(cid) == "number" and layout[cid] == nil then
      layout[cid] = { spellID = e.spellID, side = L.SIDE }
      registry[cid] = e.frame
    end
  end
  return layout, registry
end

--------------------------------------------------------------------------------
-- Scan — IMPURE.  Walk the live icon viewers and resolve each item, then Build.
--------------------------------------------------------------------------------
-- The same frames HudCore.rebind walks; the same id resolvers the whole addon uses
-- (ns.ItemCooldownID / ns.ItemBaseSpellID, both Secret-Value-guarded — they return nil
-- rather than a poisoned number).  An item with no readable cooldownID is skipped by
-- Build.  Returns (layout, registry) ready for the Binder + the Renderer's Register.
function L.Scan()
  local entries = {}
  for _, name in ipairs(ICON_VIEWERS) do
    local viewer = ns.GetViewer and ns.GetViewer(name)
    if viewer then
      local items = ns.GetItemFrames and ns.GetItemFrames(viewer) or {}
      for _, item in ipairs(items) do
        entries[#entries + 1] = {
          cooldownID = ns.ItemCooldownID and ns.ItemCooldownID(item) or nil,
          spellID    = ns.ItemBaseSpellID and ns.ItemBaseSpellID(item) or nil,
          frame      = item,
        }
      end
    end
  end
  return L.Build(entries)
end
