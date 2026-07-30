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
-- PHASE 2 IS THE MOVEABLE PANEL.  The root carries real extents (a mouse surface), drags
-- while UNLOCKED, and saves its point to `ns.db.virtualPanel`; `/cdmp panel` is the verb.
-- The drag/save/restore shape is BucketBinds' console verbatim (Console.lua saveGeom /
-- restoreGeom + the drag wiring) — including its one subtlety: `GetPoint`'s relativeTo is
-- DISCARDED and UIParent hardcoded on restore, so a saved position can never hold a stale
-- frame reference.
local ADDON, ns = ...

ns.HudVirtual = {}
local V = ns.HudVirtual

local SIZE, GAP = 40, 6

-- The root must stay GRABBABLE even with zero virtual rows (a spec whose whole rotation the
-- CDM tracks), so its width floors at this many icons.  Otherwise "unlock and drag it" would
-- be impossible exactly where you most want to pre-position the panel.
local MIN_ICONS = 3

-- Resting vs cued alpha.  The dim is deliberately readable rather than nearly-invisible: an
-- always-present icon that cannot be seen is not "always visible", it is clutter.
local DIM, LIT = 0.40, 1.00

-- Default position: below the discrete-pip resource bar (HudGeometry.BAR sits at CENTER,
-- dy -18), so our own chrome stacks as one group.  This is now the FALLBACK for "no saved
-- position" rather than the only position; keeping it here (not in HudGeometry) marks it as
-- this module's default rather than a shared contract constant.
local ANCHOR = { point = "CENTER", relPoint = "CENTER", dx = 0, dy = -52 }

-- Terminal/CRT chrome: a thin cool-grey edge, matching the `/cdmp rt` rig's placeholder
-- border.  Deliberately NOT a Blizzard icon border — the row should be apparent as the HUD's.
local EDGE = { 0.40, 0.40, 0.46, 1 }

-- The UNLOCK affordance: a terminal-green frame edge + caption, shown only while unlocked.
-- Same green as the Renderer's ROTATION token, so "this is the HUD's own widget" reads the
-- same way here as it does on a cue.
local UNLOCK_EDGE = { 0.30, 1.00, 0.48, 0.90 }

V.buttons = {}     -- base spellID -> our button frame (pooled, never destroyed)
V.unlocked = false -- drag mode: mouse enabled + chrome shown ONLY while true

--------------------------------------------------------------------------------
-- Extents — PURE.  The button row's footprint, floored so the frame stays grabbable.
--------------------------------------------------------------------------------
local function rowWidth(n)
  if not n or n < 1 then return 0 end
  return n * SIZE + (n - 1) * GAP
end

-- `(width, height)` of the root for `n` icons.  Exposed because Sync recomputes it every
-- pulse and the spec pins the floor (the zero-rows case).
function V.RootSize(n)
  return math.max(rowWidth(n), rowWidth(MIN_ICONS)), SIZE
end

-- Where button `index` of `total` starts, measured from the root's LEFT edge.  Below the
-- floor the row is PADDED to stay centred on the anchor, so a single icon sits exactly where
-- Phase 1 put it while the frame around it is still wide enough to grab.
local function buttonOffset(index, total)
  local w = V.RootSize(total)
  local pad = (w - rowWidth(total)) / 2
  return pad + ((index or 1) - 1) * (SIZE + GAP)
end

--------------------------------------------------------------------------------
-- Saved position (ns.db.virtualPanel) — BucketBinds' Console.lua shape
--------------------------------------------------------------------------------
function V.SavePosition()
  local db = ns.db and ns.db.virtualPanel
  if not (db and V.root) then return end
  -- ⚠ The relativeTo frame (2nd return) is DELIBERATELY discarded — see the header.
  local point, _, relPoint, x, y = V.root:GetPoint()
  db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
end

function V.RestorePosition()
  if not V.root then return end
  local db = (ns.db and ns.db.virtualPanel) or {}
  V.root:ClearAllPoints()
  if db.point then
    V.root:SetPoint(db.point, UIParent, db.relPoint or db.point, db.x or 0, db.y or 0)
  else
    V.root:SetPoint(ANCHOR.point, UIParent, ANCHOR.relPoint, ANCHOR.dx, ANCHOR.dy)
  end
end

-- Forget the saved position and snap back to the default anchor.
function V.ResetPosition()
  local db = ns.db and ns.db.virtualPanel
  if db then db.point, db.relPoint, db.x, db.y = nil, nil, nil, nil end
  V.RestorePosition()
end

--------------------------------------------------------------------------------
-- Frames (impure)
--------------------------------------------------------------------------------
-- The unlock chrome: four thin edge textures + a caption.  No `SetBackdrop` — that needs
-- BackdropTemplate, and four textures say the same thing with no template dependency.
local function buildUnlockChrome(root)
  local edges = {}
  local function edge(...)
    local t = root:CreateTexture(nil, "OVERLAY")
    t:SetColorTexture(UNLOCK_EDGE[1], UNLOCK_EDGE[2], UNLOCK_EDGE[3], UNLOCK_EDGE[4])
    t:Hide()
    edges[#edges + 1] = t
    return t
  end
  local top = edge()
  top:SetPoint("TOPLEFT", root, "TOPLEFT", -2, 2)
  top:SetPoint("TOPRIGHT", root, "TOPRIGHT", 2, 2)
  top:SetHeight(1)
  local bottom = edge()
  bottom:SetPoint("BOTTOMLEFT", root, "BOTTOMLEFT", -2, -2)
  bottom:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", 2, -2)
  bottom:SetHeight(1)
  local left = edge()
  left:SetPoint("TOPLEFT", root, "TOPLEFT", -2, 2)
  left:SetPoint("BOTTOMLEFT", root, "BOTTOMLEFT", -2, -2)
  left:SetWidth(1)
  local right = edge()
  right:SetPoint("TOPRIGHT", root, "TOPRIGHT", 2, 2)
  right:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", 2, -2)
  right:SetWidth(1)

  local caption = root:CreateFontString(nil, "OVERLAY")
  ns.SetFont(caption, 10)
  caption:SetText("CDMProbe")
  caption:SetTextColor(UNLOCK_EDGE[1], UNLOCK_EDGE[2], UNLOCK_EDGE[3], 1)
  caption:SetPoint("BOTTOMLEFT", root, "TOPLEFT", -2, 4)
  caption:Hide()

  V.chrome, V.caption = edges, caption
end

function V.ensureRoot()
  if not V.root then
    V.root = CreateFrame("Frame", nil, UIParent)
    V.root:SetSize(V.RootSize(0))
    -- MEDIUM = the action-bar strata, matching the Renderer's root: above the world, but
    -- COVERED by a full-screen panel (the map, the character sheet) rather than floating
    -- over it.  Our own widgets should behave like the rest of the combat UI.
    V.root:SetFrameStrata("MEDIUM")
    V.root:SetClampedToScreen(true)
    V.root:SetMovable(true)
    V.root:RegisterForDrag("LeftButton")
    V.root:SetScript("OnDragStart", function(self) self:StartMoving() end)
    V.root:SetScript("OnDragStop", function(self)
      self:StopMovingOrSizing()
      V.SavePosition()
    end)
    -- MOUSE OFF BY DEFAULT: the panel must never eat a click in normal play.  It is enabled
    -- only while unlocked (SetUnlocked), which is also the only time the chrome shows.
    V.root:EnableMouse(false)
    buildUnlockChrome(V.root)
    V.RestorePosition()
  end
  V.root:Show()
  return V.root
end

-- Unlocked: mouse on, chrome visible, icons forced to full alpha so you can see what you are
-- dragging.  Locked: chrome hidden, mouse off, only the icon remains.
function V.SetUnlocked(on)
  V.unlocked = on and true or false
  if not V.root then return end
  V.root:EnableMouse(V.unlocked)
  for _, t in ipairs(V.chrome or {}) do t:SetShown(V.unlocked) end
  if V.caption then V.caption:SetShown(V.unlocked) end
  for _, f in pairs(V.buttons) do
    if f:IsShown() then f:SetAlpha(V.unlocked and LIT or DIM) end
  end
end

-- One pooled button per base spellID, laid out left-to-right by `index` within a row of
-- `total`.  Returns nil (and creates nothing) if the frame does not exist yet and we are
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
  f:ClearAllPoints()
  f:SetPoint("LEFT", V.ensureRoot(), "LEFT", buttonOffset(index, total), 0)
  f:SetAlpha(V.unlocked and LIT or DIM)
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
  -- The root's extents track the icon count, so the mouse surface is exactly the button row
  -- (floored at MIN_ICONS).  Sized BEFORE the buttons lay out, since their offsets are
  -- measured from the root's LEFT edge.  Frame discipline holds: the root is created here
  -- only out of combat — but it IS created even with zero virtual rows, so `/cdmp panel`
  -- can pre-position the panel on a spec whose whole rotation the CDM tracks.
  if V.root or not InCombatLockdown() then
    V.ensureRoot():SetSize(V.RootSize(#ids))
  end
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
    -- While UNLOCKED every icon is held lit, so you can see what you are dragging; the cue
    -- reading resumes the moment it is locked again.
    if f:IsShown() then f:SetAlpha((V.unlocked or lit[id]) and LIT or DIM) end
  end
end

-- HUD off: clear our own chrome completely, so toggling leaves the screen pixel-clean.
-- Locking too — an unlock affordance on a hidden frame is a drag surface you cannot see.
function V.Clear()
  V.SetUnlocked(false)
  for _, f in pairs(V.buttons) do f:Hide() end
  if V.root then V.root:Hide() end
end

--------------------------------------------------------------------------------
-- `/cdmp panel` — the unlock verb
--------------------------------------------------------------------------------
-- Registered here rather than in Core: Core.lua loads first, and Mode.lua / AlertTape.lua
-- already register their own commands this way.  Parsed with AlertTape's STRICT token match
-- rather than HudDriver's substring `find`, because with four verbs a substring test would
-- match `lock` inside `unlock`.
local function unlockPanel()
  if not V.root then
    if InCombatLockdown() then
      ns.Print("|cffff4040cannot create the panel in combat|r — step out of combat, then "
        .. "|cffffffff/cdmp panel unlock|r.")
      return
    end
    V.ensureRoot()
  end
  V.SetUnlocked(true)
  ns.Print("virtual panel |cff88ff88UNLOCKED|r — drag it anywhere, then "
    .. "|cffffffff/cdmp panel lock|r.")
end

local function lockPanel()
  V.SetUnlocked(false)
  ns.Print("virtual panel |cffff4040LOCKED|r — position saved.")
end

ns.RegisterCommand("panel",
  "move OUR OWN icon row: unlock | lock | reset (bare toggles)",
  function(arg)
    arg = (arg or ""):lower():match("^%s*(%S*)")
    if arg == "unlock" then
      unlockPanel()
    elseif arg == "lock" then
      lockPanel()
    elseif arg == "reset" then
      V.ResetPosition()
      ns.Print("virtual panel position |cffffffffreset|r to the default (below the resource bar).")
    elseif arg == "" then
      if V.unlocked then lockPanel() else unlockPanel() end
    else
      ns.Print("|cffffd100/cdmp panel|r unlock | lock | reset  (bare toggles)")
      ns.Printf("  currently: %s",
        V.unlocked and "|cff88ff88UNLOCKED|r" or "|cffff4040LOCKED|r")
    end
  end)
