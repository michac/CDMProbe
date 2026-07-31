-- Viewers.lua — locate the Cooldown Manager viewer frames, enumerate their item
-- frames, resolve each item's spellID, and dump the whole live API surface.
local ADDON, ns = ...

ns.VIEWERS = {
  { key = "essential", frame = "EssentialCooldownViewer", label = "Essential" },
  { key = "utility",   frame = "UtilityCooldownViewer",   label = "Utility"   },
  { key = "bufficon",  frame = "BuffIconCooldownViewer",  label = "Buff (icon)" },
  { key = "buffbar",   frame = "BuffBarCooldownViewer",   label = "Buff (bar)"  },
}

function ns.GetViewer(frameName)
  return _G[frameName]
end

-- Returns (itemFrames, howResolved).  Prefers the documented GetItemFrames()
-- method; falls back to filtering GetChildren() for item-looking frames.
function ns.GetItemFrames(viewer)
  if ns.HasMethod(viewer, "GetItemFrames") then
    local ok, frames = pcall(viewer.GetItemFrames, viewer)
    if ok and type(frames) == "table" then return frames, "GetItemFrames()" end
  end
  local out = {}
  if ns.HasMethod(viewer, "GetChildren") then
    for _, c in ipairs({ viewer:GetChildren() }) do
      if type(c) == "table" and (c.Cooldown or c.Icon or ns.HasMethod(c, "GetCooldownID")) then
        out[#out + 1] = c
      end
    end
  end
  return out, "GetChildren() filtered"
end

-- ⚠ THE SECRET-ID TRAP.  `type(secretValue) == "number"` is **TRUE**,
-- so the obvious guard — `if ok and type(id) == "number"` — HAPPILY RETURNS A
-- SECRET VALUE.  The buff viewer's GetSpellID() reads secret in combat
-- (probe-confirmed), so a rebind landing mid-fight used to write a secret into
-- `e.baseSpellID`, and every downstream `e.baseSpellID == spellID` then compared
-- one — poisoning the identity comparison that the whole proc-glow routing path runs
-- on.  A secret never escapes these functions again: every
-- strategy is ns.IsSecret-checked, an unreadable one FALLS THROUGH to the next,
-- and the last word is `nil` — "we don't know" — never a poisoned number.
local function readable(id)
  return type(id) == "number" and not ns.IsSecret(id)
end

-- The BINDING KEY.  cooldownID is the stable per-tracked-spell identity across relayouts
-- and reorders, and it is what the ENTIRE pipeline keys on: State keys `cooldowns` by it,
-- the Coach's cue keys resolve to it, and HudLayout.Build drops any entry whose cooldownID
-- is not a number.  Secret-guarded like every identity read (B2) — `type(secret)=="number"`
-- is TRUE, so an unguarded read would return a Secret Value that then taints every table
-- it keys.  nil means "we don't know", never a poisoned number.
--
-- ⚠ RESTORED 2026-07-30 after a TOTAL HUD OUTAGE.  This function used to live in
-- HudCore.lua, which was DELETED at the W4 cutover (d824557) — but HudLayout.Scan and
-- ns.ItemBaseSpellID both still called it through an `ns.ItemCooldownID and …` nil guard.
-- With the definition gone the guard silently evaluated to nil for EVERY icon, so
-- HudLayout.Build dropped every entry, the Layout came back empty, the Binder dropped
-- every cue, and the HUD drew nothing at all on any spec while still reporting itself ON.
-- `/cdmp hud layout` said "no icons".  Two things hid it: the nil guards turned a missing
-- function into a silent no-op instead of an error, and hudlayout_spec STUBS
-- ns.ItemCooldownID, so busted stayed green while the shipped code could never work.  Both
-- are fixed — the call sites now call it directly, and viewers_spec asserts the REAL
-- function exists.  Do not re-add a nil guard here; a missing definition must fail loudly.
function ns.ItemCooldownID(item)
  if type(item) ~= "table" then return nil end
  if readable(item.cooldownID) then return item.cooldownID end
  if ns.HasMethod(item, "GetCooldownID") then
    local ok, id = pcall(item.GetCooldownID, item)
    if ok and readable(id) then return id end
  end
  return nil
end

-- The BASE spell — `cooldownInfo.spellID`, before any override.  Deliberately NOT
-- `item:GetSpellID()`: `CooldownViewerItemDataMixin:GetSpellID()` prefers the aura /
-- linked / override / overrideTooltip spell (CooldownViewerItemData.lua:174), so
-- a Demonic Art transform (HoG -> Ruination) silently changes what that returns.
-- Anything keyed on ability IDENTITY — keybinds, the proc-glow registry — must
-- key on the base, or it misses for the whole duration of the transform.
function ns.ItemBaseSpellID(item)
  if ns.HasMethod(item, "GetBaseSpellID") then
    local ok, id = pcall(item.GetBaseSpellID, item)
    if ok and readable(id) then return id end
  end
  -- Fallback: the C_CooldownViewer info table carries the un-overridden spellID.
  -- Direct call, no nil guard — see the outage note on ns.ItemCooldownID above.  (It is
  -- already secret-guarded and already tries item.cooldownID, so the old
  -- `… or item.cooldownID` fallback only risked re-admitting a value the guard refused.)
  local cdID = ns.ItemCooldownID(item)
  if cdID and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
    local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
    if ok and type(info) == "table" and readable(info.spellID) then
      return info.spellID
    end
  end
  return nil
end

-- The DISPLAY identity of an item: the spell the icon actually SHOWS, which is not always
-- its base (Destruction's cid 66181 is Shadow Bolt 686 displaying Incinerate 29722).  The
-- policy lives in ns.DisplayIdentity so State's domain view and the Layout key on the same
-- vocabulary -- the Binder joins cues via `cues[entry.spellID]`, so if these two disagree
-- the join silently misses and the icon gets neither a cue nor a keybind.
--
-- Still resolves through the BASE first: `liveSpellID` is deliberately not consulted, so a
-- Demonic Art transform never changes an icon's identity mid-combat (the v0.7.0 finding-3
-- rule this file documents above is unchanged -- only the STATIC display override is new).
function ns.ItemDisplaySpellID(item)
  local base = ns.ItemBaseSpellID(item)
  if base == nil then return nil end
  local cdID = ns.ItemCooldownID(item)
  if cdID and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
    local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
    if ok and type(info) == "table" then
      local ov  = readable(info.overrideSpellID) and info.overrideSpellID or nil
      local ovt = readable(info.overrideTooltipSpellID) and info.overrideTooltipSpellID or nil
      return ns.DisplayIdentity(base, ov, ovt)
    end
  end
  return base
end

--------------------------------------------------------------------------------
-- ns.DisplayIdentity — the ONE rule for "which spell is this CDM row actually
-- showing?", shared by every producer that keys on a spell.
--------------------------------------------------------------------------------
-- A Cooldown Manager row's own spellID is not always the spell it DRAWS.  Destruction's
-- cid 66181 is Shadow Bolt 686 with its display overridden to Incinerate 29722, and on
-- DIABOLIST (where 686 reads isKnown) that is the row Blizzard puts on screen.  Every
-- consumer that keyed on the raw base therefore disagreed with what the player saw:
--   * State keyed `abilities[686]`, so the Coach's `facts[29722]` was nil and the
--     Incinerate line could never win  (0 wins in 225 Diabolist decisions, 2026-07-30);
--   * HudLayout published `spellID = 686`, so the Binder's cue join (`cues[entry.spellID]`)
--     missed, AND the keybind was looked up for Shadow Bolt — which is not on the bars.
-- Both symptoms are one cause, so the rule lives in ONE place and both producers call it.
--
-- ⚠ USE THE STATIC OVERRIDES, NEVER `liveSpellID` — the reasoning is stated in full at
-- State.lua's `displayedIdentities`, which unions the same two fields for the same reason.
--
-- Adopting an override is DELIBERATELY conservative — it must be a real, pressable
-- ability of the active spec:
--   * declared in the spec table   — an id we have no opinion about is not an identity;
--   * `kind == "button"`           — an aura row is an input, never a press;
--   * `expect ~= false`            — the transforms (Ruination / Infernal Bolt) and the
--                                    cast-id aliases declare they never own an icon.  A
--                                    transform must never become the identity of the frame
--                                    it merely rides.
-- Anything short of all three falls back to `base`, which is today's behaviour — so a spec
-- with no display-overridden rows is completely unaffected.
function ns.DisplayIdentity(base, overrideSpellID, overrideTooltipSpellID)
  if type(base) ~= "number" then return base end
  local shown = overrideSpellID
  if type(shown) ~= "number" or ns.IsSecret(shown) then shown = overrideTooltipSpellID end
  if type(shown) ~= "number" or ns.IsSecret(shown) or shown == base then return base end
  -- ⚠ NOT a banned nil guard.  ns.SpecInfo is a REBOUND global — SpecRegistry copies it off
  -- the active spec and leaves it nil on an unregistered spec (the passive path), so this is
  -- a STATE test, not a "did someone delete the definition" test.  Passive ⇒ no opinion about
  -- any id ⇒ the raw base is the honest identity.
  if type(ns.SpecInfo) ~= "function" then return base end
  local info, declared = ns.SpecInfo(shown)
  if not declared or type(info) ~= "table" then return base end
  if info.kind ~= "button" or info.expect == false then return base end
  return shown
end
