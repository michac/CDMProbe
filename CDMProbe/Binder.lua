-- Binder.lua — Stage 3 of the W4 pipeline: Guidance + Layout -> **Binder** -> DrawList.
--
-- WHY THIS EXISTS (docs/archive/w4-phase4-binder-plan.md, architecture.md Stage-3).  The
-- pipeline is State -> Coach -> Guidance -> Binder -> DrawList -> Renderer.  The
-- Coach (Stage 2) decides: it emits a BASE-spellID-keyed, colour-free, GEOMETRY-free
-- Guidance (the W4 re-layer — cooldownID is transport the Coach never speaks).  The
-- Renderer (Stage 4) draws: it consumes a handle-keyed, positioned DrawList and never
-- makes a decision.  The Binder is the seam that turns one into the other — a pure
-- GEOMETRY / BINDING merge, and it OWNS the spellID -> cooldownID resolution:
--
--   * cues:        Layout{cooldownID -> {spellID}} + Guidance.cues{spellID} -> DrawList.
--                  For each DISPLAYED icon, look its Coach cue up by the icon's spellID,
--                  stamp the corner-dot geometry, pass the emphasis TOKEN through (colour
--                  stays the Renderer's job), look the keybind up by the entry's spellID —
--                  anchoring to the icon's cooldownID.  (Ring/glow is emphasis-derived in
--                  the Renderer now, so there is no glow flag to set.)  An icon
--                  the Coach did NOT signal still gets an EMPTY CUE (no emphasis -> no dot)
--                  as long as it has a keybind, so the key hint rides every button (P5d).
--                  A spellID cue whose ability isn't in a displayed icon viewer is DROPPED
--                  (the Coach ranked it, but there's no icon to anchor to).
--   * panel:       Guidance.sequence -> DrawList.panel (self-anchored).
--   * resourceBars: Guidance.resourceBars[] -> DrawList.resourceBars[] (self-anchored, stacked).
--
-- COLOUR-FREE BY CONTRACT: the Binder never resolves a token to RGBA (guidance-
-- contract.json).  It also holds NO geometry constants of its own — the dot corner,
-- panel + bar positions live in ns.HudGeometry, which the Renderer's
-- `/cdmp rendertest` fixtures read too, so the two producers agree by construction.
--
-- PURE FACTORY, like Coach/Renderer: Binder.New(cfg) / __index, deterministic
-- in -> out.  Everything volatile arrives in the two Bind args (the Guidance and the
-- Layout), so a golden-derived fixture can arbitrate it off-game (binder_spec.lua).
--
-- THE TWO SEAMS (both cfg-injected, mirroring the Coach's cfg.shardCost):
--   * geometry    the shared ns.HudGeometry (overridable for a test / retheme).
--   * keybindFor  fn(spellID) -> string | nil.  TEST-ONLY now: LIVE keybinds come from
--                 STATE (the single resolver), stitched onto each layout entry by the
--                 driver, so a cue prefers `layout[cid].keybind` and only falls back to
--                 this seam when the layout carries none (the fixture path).
--
-- THE cooldownID <-> spellID BRIDGE is the LAYOUT (it carries both), not the Binder:
-- Guidance keys cues by BASE spellID and the keybind scan keys by spellID too, while the
-- Renderer anchors by cooldownID.  The Layout — built live from the CDM RefreshLayout
-- hook, in test from a fixture — maps each displayed cooldownID to its spellID, and the
-- Binder reads that map (cue = cues[layout[cid].spellID]), never re-deriving identity.
local ADDON, ns = ...

ns.Binder = {}
local B = ns.Binder
B.__index = B

--------------------------------------------------------------------------------
-- Construction.  cfg (all optional):
--   geometry    the shared geometry table (defaults to ns.HudGeometry).
--   keybindFor  fn(spellID) -> string   the LIVE keybind reader (wraps HudBinds)
--               when wired; a fixture map in the golden harness.
--------------------------------------------------------------------------------
function B.New(cfg)
  cfg = cfg or {}
  local self = setmetatable({}, B)
  self.geometry   = cfg.geometry or ns.HudGeometry
  self.keybindFor = cfg.keybindFor
  return self
end

-- Resolve a keybind for a spellID through the injected seam.  A missing reader, a
-- nil spellID, or a blank/absent binding all collapse to nil (no keybind hint) —
-- never a placeholder, mirroring HudBinds' "a fake key is worse than none".
local function keybindOf(self, spellID)
  if not spellID or not self.keybindFor then return nil end
  local k = self.keybindFor(spellID)
  if type(k) == "string" and k ~= "" then return k end
  return nil
end

--------------------------------------------------------------------------------
-- cues — the layout-gated geometry/keybind merge.
--------------------------------------------------------------------------------
function B:bindCues(guidance, layout)
  local G = self.geometry
  local cues = guidance.cues or {}
  layout = layout or {}

  -- Iterate the LAYOUT (every displayed icon), not just the Coach's cues.  A cue is
  -- emitted for any displayed item that has an EMPHASIS (a Coach signal) OR a KEYBIND.
  -- The keybind-only case is an EMPTY CUE — no emphasis, so the Renderer draws the key
  -- hint but no dot/glow.  This is how keybinds ride EVERY button (cued or not) with no
  -- separate DrawList channel (W4 P5d): the keybind is identity chrome, not a signal.
  -- A cooldownID the Layout doesn't display is never iterated, so off-screen cues drop
  -- for free; an uncued icon with no keybind emits nothing.
  local keys = {}
  for cid in pairs(layout) do keys[#keys + 1] = cid end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

  local out = {}
  for _, cid in ipairs(keys) do
    local entry = layout[cid]
    -- THE spellID->cooldownID JOIN (the W4 re-layer).  Guidance cues are keyed by BASE
    -- spellID (the Coach's vocabulary); the Layout carries the spellID<->cooldownID bridge
    -- per displayed icon, so we look the cue up by the icon's spellID and emit the cue
    -- anchored to its cooldownID (`G.cue(cid, …)` -> anchorTo = cid, unchanged).  This is
    -- where the summon-drop bug dies: an ability displays through its Essential row, which
    -- IS in the Layout, so its cue draws; the TrackedBar cid never reached the Coach at all.
    local cue = (entry and entry.spellID ~= nil) and cues[entry.spellID] or nil
    -- draw=false demotes to "no emphasis" (the keybind may still ride).
    local emphasis = (cue and cue.draw ~= false) and cue.emphasis or nil
    -- Prefer the keybind STATE already resolved (stitched onto the layout live by the
    -- driver, keyed by cooldownID) — State is the SINGLE keybind resolver.  Fall back to
    -- the cfg seam only for the test path (a fixture layout carries no keybind).
    local keybind = (entry and entry.keybind) or keybindOf(self, entry and entry.spellID)
    if emphasis or keybind then
      out[#out + 1] = G.cue(cid, emphasis, keybind)
    end
  end
  return out
end

--------------------------------------------------------------------------------
-- panel — Guidance.sequence -> a self-anchored titled step list.  Only when the
-- sequence asks to show; the Renderer's v1 panel draws state/keybind/label per row,
-- so the step note (a pass-through the panel doesn't render yet) is not carried.
--------------------------------------------------------------------------------
function B:bindPanel(guidance)
  local seq = guidance.sequence
  if not seq or not seq.show then return nil end
  local steps = {}
  for i, s in ipairs(seq.steps or {}) do
    steps[i] = { label = s.label, keybind = s.keybind, state = s.state }
  end
  return self.geometry.panel(seq.title, steps)
end

--------------------------------------------------------------------------------
-- resourceBars — the ARRAY of power meters (multi-spec Phase 3), each stamped with
-- geometry and STACKED vertically by index.  value/max/powerType/display pass through;
-- `incoming` is not forwarded (the discrete pip row doesn't render a projection yet), and
-- `display` rides along so the Renderer can route discrete vs continuous.  A single-power
-- spec (Demo) yields a one-element array at the unchanged position.
--------------------------------------------------------------------------------
function B:bindResources(guidance)
  local bars = guidance.resourceBars
  if not bars then return nil end
  local out = {}
  for i, r in ipairs(bars) do
    out[i] = self.geometry.resourceBar(r.value, r.max, r.powerType, i - 1, r.display)
  end
  return out
end

--------------------------------------------------------------------------------
-- Bind — the one public entry.  Guidance + Layout in, DrawList out.
--------------------------------------------------------------------------------
function B:Bind(guidance, layout)
  guidance = guidance or {}
  return {
    cues = self:bindCues(guidance, layout),
    panel = self:bindPanel(guidance),
    resourceBars = self:bindResources(guidance),
  }
end
