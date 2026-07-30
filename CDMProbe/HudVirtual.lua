-- HudVirtual.lua — OUR OWN icons for the rotation buttons the CDM tracks nowhere.
--
-- WHAT THIS IS (docs/virtual-cdm-plan.md, Phase 1).  State synthesises a domain-view row for
-- each ability the active spec's table declares as a rotation button and the Cooldown Manager
-- tracks nowhere — Destruction's INCINERATE, Demonology's SHADOW BOLT — keyed by base
-- spellID and handled by a NEGATIVE cooldownID (`-spellID`; real cooldownIDs are positive, so
-- collision is impossible by construction).  That makes the ability SELECTABLE.  This file is
-- the other half: it makes it VISIBLE, by pooling one button frame per virtual row and
-- returning `(layout, registry)` fragments the driver merges into the scanned Layout.
--
-- ⚠ THE DESIGN'S OWN SUCCESS CRITERION: `Binder.lua` and `Renderer.lua` MUST NOT CHANGE.  A
-- virtual entry has to arrive as *just another Layout entry plus a frame in the registry*,
-- and every existing stage must handle it without knowing.  If either file ever needs an
-- edit to accommodate this, the seam is wrong — stop and re-think rather than widening the
-- contract.  `V.Build` therefore delegates to `ns.HudLayout.Build` rather than stamping the
-- same shape by hand: the two agree by CONSTRUCTION, not by vigilance.
--
-- NATIVE ART, OUR CHROME (design.md pillar 1).  The icon texture is Blizzard's own
-- `C_Spell.GetSpellTexture` — the native art is the strongest non-colour signifier we have,
-- so borrowing it is the honest choice.  What we own is the frame around it, which is also
-- what keeps this from reading as a forgery of a Blizzard row.
--
-- NO SWIPE, NO COUNTDOWN, and that is fine: a 0-cooldown filler has nothing to sweep.  It is
-- the same reason State's zero-cooldown fence lands where it does — the one thing our own
-- icon genuinely cannot reproduce is exactly the thing these abilities do not need.
--
-- ALWAYS VISIBLE WHILE THE HUD IS ON, dimmed when uncued (settled at approval).  A floor
-- press that appears and disappears is worse than a constant one: the whole point is that the
-- player's eye has somewhere to land when nothing else is up.
--
-- FRAME DISCIPLINE.  Frames are created OUT OF COMBAT only and pooled thereafter, per the
-- project's standing rule.  A candidate that first appears mid-combat simply gets no frame
-- (and therefore no Layout entry, so no cue is emitted for it) until the next out-of-combat
-- tick — the under-show direction, and in practice a non-event since the HUD enables on login.
--
-- PHASE 1 IS A FIXED POSITION.  The draggable, saved-position frame + `/cdmp panel` is
-- Phase 2; this anchors below the resource bar so the HUD's owned chrome reads as one group.
local ADDON, ns = ...

ns.HudVirtual = {}
local V = ns.HudVirtual

local SIZE, GAP = 40, 6

-- Resting vs cued alpha.  The dim is deliberately readable rather than nearly-invisible: an
-- always-present icon that cannot be seen is not "always visible", it is clutter.
local DIM, LIT = 0.40, 1.00

-- Default position: below the discrete-pip resource bar (HudGeometry.BAR sits at CENTER,
-- dy -18), so our own chrome stacks as one group.  Phase 2 replaces this with a saved,
-- draggable position; keeping it here (not in HudGeometry) marks it as this module's
-- provisional default rather than a shared contract constant.
local ANCHOR = { point = "CENTER", relPoint = "CENTER", dx = 0, dy = -52 }

-- Terminal/CRT chrome: a thin cool-grey edge, matching the rendertest rig's placeholder
-- border.  Deliberately NOT a Blizzard icon border — the row should be apparent as the HUD's.
local EDGE = { 0.40, 0.40, 0.46, 1 }

V.buttons = {}     -- base spellID -> our button frame (pooled, never destroyed)

--------------------------------------------------------------------------------
-- Frames (impure)
--------------------------------------------------------------------------------
function V.ensureRoot()
  if not V.root then
    V.root = CreateFrame("Frame", nil, UIParent)
    V.root:SetSize(1, 1)
    V.root:SetPoint(ANCHOR.point, UIParent, ANCHOR.relPoint, ANCHOR.dx, ANCHOR.dy)
    -- MEDIUM = the action-bar strata, matching the Renderer's root: above the world, but
    -- COVERED by a full-screen panel (the map, the character sheet) rather than floating
    -- over it.  Our own widgets should behave like the rest of the combat UI.
    V.root:SetFrameStrata("MEDIUM")
  end
  V.root:Show()
  return V.root
end

-- One pooled button per base spellID, laid out left-to-right by `index` and centred as a row
-- of `total`.  Returns nil (and creates nothing) if the frame does not exist yet and we are
-- in combat — see the frame-discipline note in the header.
function V.ensureButton(spellID, index, total)
  local f = V.buttons[spellID]
  if not f then
    if InCombatLockdown() then return nil end
    local root = V.ensureRoot()
    f = CreateFrame("Frame", nil, root)
    f:SetSize(SIZE, SIZE)
    local edge = f:CreateTexture(nil, "BORDER")
    edge:SetPoint("TOPLEFT", f, "TOPLEFT", -1, 1)
    edge:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 1, -1)
    edge:SetColorTexture(EDGE[1], EDGE[2], EDGE[3], EDGE[4])
    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints(f)
    local tex = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(spellID)
    if tex then
      icon:SetTexture(tex)
      icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)   -- trim the stock icon border
    end
    f.icon = icon
    V.buttons[spellID] = f
  end
  local width = (total or 1) * SIZE + ((total or 1) - 1) * GAP
  f:ClearAllPoints()
  f:SetPoint("LEFT", V.ensureRoot(), "CENTER",
             -width / 2 + ((index or 1) - 1) * (SIZE + GAP), 0)
  f:SetAlpha(DIM)
  f:Show()
  return f
end

--------------------------------------------------------------------------------
-- Build — PURE.  A sorted list of base spellIDs -> (layout, registry).
--------------------------------------------------------------------------------
-- `frameFor(spellID, index, total)` supplies the frame (live: `V.ensureButton`; test: a
-- stub).  A candidate with no frame is DROPPED rather than carried with a nil frame: a
-- Layout entry the Renderer cannot anchor would let the Binder report the cue as bound while
-- nothing drew, which is exactly the silent-failure shape the decision log exists to expose.
--
-- Delegates to `ns.HudLayout.Build` so the fragments are, by construction, in the same shape
-- the live viewer walk produces — number-keyed, `{ spellID, side }`, frame in the registry.
function V.Build(ids, frameFor)
  ids = ids or {}
  local entries = {}
  for i = 1, #ids do
    local id = ids[i]
    if type(id) == "number" and not ns.IsSecret(id) then
      local frame = frameFor and frameFor(id, #entries + 1, #ids) or nil
      if frame then
        entries[#entries + 1] = { cooldownID = -id, spellID = id, frame = frame }
      end
    end
  end
  return ns.HudLayout.Build(entries)
end

--------------------------------------------------------------------------------
-- Sync — IMPURE.  Pool this pulse's frames and emit the fragments.
--------------------------------------------------------------------------------
-- The keybind is stitched here rather than by the driver: the driver's existing stitch reads
-- `pulse.cooldowns[cid]`, which is the RAW CDM view and has no negative keys (deliberately —
-- adding synthetic rows to the diagnostic view would muddy what it means).  `HudBinds`
-- resolves off the BASE spellID and never consulted the CDM, so it works here untouched.
function V.Sync(pulse)
  local ids = (pulse and pulse.virtual) or {}
  local layout, registry = V.Build(ids, V.ensureButton)
  for _, e in pairs(layout) do
    e.keybind = (ns.HudBinds and ns.HudBinds.Get and ns.HudBinds.Get(e.spellID)) or nil
  end
  -- Hide a button whose ability stopped being virtual — the CDM started tracking it, the
  -- player untalented it, or a respec changed the spec.  Pooled, never destroyed.
  local want = {}
  for i = 1, #ids do want[ids[i]] = true end
  for id, f in pairs(V.buttons) do
    if not want[id] then f:Hide() end
  end
  return layout, registry
end

--------------------------------------------------------------------------------
-- Reflect — raise a button out of its resting dim when the DrawList cues it.
--------------------------------------------------------------------------------
-- Reads the DrawList the driver already holds, so this module needs no guidance knowledge of
-- its own: a cue on a NEGATIVE handle carrying an emphasis token is, by construction, one of
-- ours.  (An emphasis-less cue is the Binder's keybind-only entry, which is not a press call
-- and must not light the icon.)
function V.Reflect(drawList)
  local lit = {}
  for _, c in ipairs((drawList and drawList.cues) or {}) do
    local h = c.anchorTo
    if type(h) == "number" and h < 0 and c.emphasis then lit[-h] = true end
  end
  for id, f in pairs(V.buttons) do
    if f:IsShown() then f:SetAlpha(lit[id] and LIT or DIM) end
  end
end

-- HUD off: clear our own chrome completely, so toggling leaves the screen pixel-clean.
function V.Clear()
  for _, f in pairs(V.buttons) do f:Hide() end
  if V.root then V.root:Hide() end
end
