-- Binder.lua — Stage 3 of the W4 pipeline: Guidance + Layout -> **Binder** -> DrawList.
--
-- WHY THIS EXISTS (docs/w4-phase4-binder-plan.md, architecture.md Stage-3).  The
-- pipeline is State -> Coach -> Guidance -> Binder -> DrawList -> Renderer.  The
-- Coach (Stage 2) decides: it emits a cooldownID-keyed, colour-free, GEOMETRY-free
-- Guidance.  The Renderer (Stage 4) draws: it consumes a handle-keyed, positioned
-- DrawList and never makes a decision.  The Binder is the seam that turns one into
-- the other — a pure GEOMETRY / BINDING merge:
--
--   * cues:        Guidance.cues{cooldownID -> {emphasis}} -> DrawList.cues[].  For
--                  each cooldownID the Layout says is DISPLAYED, stamp the corner-dot
--                  geometry, pass the emphasis TOKEN through (colour stays the
--                  Renderer's job), look the keybind up by the entry's spellID, and
--                  set the glow flag.  A cue whose cooldownID isn't on screen is
--                  DROPPED (you can't decorate an icon the CDM isn't showing).
--   * panel:       Guidance.sequence -> DrawList.panel (self-anchored).
--   * resourceBar: Guidance.resourceBar -> DrawList.resourceBar (self-anchored).
--
-- COLOUR-FREE BY CONTRACT: the Binder never resolves a token to RGBA (guidance-
-- contract.json).  It also holds NO geometry constants of its own — the dot corner,
-- glow rule, panel + bar positions live in ns.HudGeometry, which the Renderer's
-- `/cdmp rendertest` fixtures read too, so the two producers agree by construction.
--
-- PURE FACTORY, like Coach/Renderer: Binder.New(cfg) / __index, deterministic
-- in -> out.  Everything volatile arrives in the two Bind args (the Guidance and the
-- Layout), so a golden-derived fixture can arbitrate it off-game (binder_spec.lua).
--
-- THE TWO SEAMS (both cfg-injected, mirroring the Coach's cfg.shardCost):
--   * geometry    the shared ns.HudGeometry (overridable for a test / retheme).
--   * keybindFor  fn(spellID) -> string | nil.  Live: wraps HudBinds.Get.  Test: a
--                 fixture map.  The Binder does NOT scan the action bars itself.
--
-- THE cooldownID <-> spellID BRIDGE is the LAYOUT (it carries both), not the Binder:
-- Guidance keys cues by cooldownID; the keybind scan keys by spellID.  The Layout —
-- built live from the CDM RefreshLayout hook, in test from a fixture — maps each
-- displayed cooldownID to its spellID, and the Binder reads that map, never
-- re-deriving identity.
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

  -- Keep only cooldownIDs the Layout says are DISPLAYED (drop the rest), and honour
  -- an explicit draw=false.  Sorted for a deterministic array (the Renderer keys by
  -- anchorTo and doesn't care about order — this is just stable output).
  local keys = {}
  for cid, cue in pairs(cues) do
    if cue and cue.draw ~= false and layout[cid] then
      keys[#keys + 1] = cid
    end
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

  local out = {}
  for _, cid in ipairs(keys) do
    local cue = cues[cid]
    local entry = layout[cid]
    local keybind = keybindOf(self, entry and entry.spellID)
    out[#out + 1] = G.cue(cid, cue.emphasis, keybind)
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
-- resourceBar — value/max/powerType through, geometry stamped on.  The v1 bar is a
-- discrete pip row (the Renderer reads value/max/powerType only), so `incoming` and
-- `display` are not forwarded — they land when the bar renders a projection.
--------------------------------------------------------------------------------
function B:bindResource(guidance)
  local r = guidance.resourceBar
  if not r then return nil end
  return self.geometry.resourceBar(r.value, r.max, r.powerType)
end

--------------------------------------------------------------------------------
-- Bind — the one public entry.  Guidance + Layout in, DrawList out.
--------------------------------------------------------------------------------
function B:Bind(guidance, layout)
  guidance = guidance or {}
  return {
    cues = self:bindCues(guidance, layout),
    panel = self:bindPanel(guidance),
    resourceBar = self:bindResource(guidance),
  }
end
