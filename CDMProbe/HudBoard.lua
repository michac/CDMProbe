-- HudBoard.lua — the BOARD RESOLVER (W4b, A1+A2).
--
-- WHY THIS EXISTS.  The cue decision used to be smeared across three modules
-- (audit W4/A1): HudScore.For scored each item, HudState.Recompute re-decided in
-- the middle of its paint loop (filler board-resolution, LATE promotion, the SOON
-- treatment, SpecNoCue suppression, the Tyrant-yellow-until-real hold), and
-- HudChrome.SetCue/paintCue decided AGAIN (level -> palette key, emphasis -> fill
-- fraction).  The middle layer was the ONE slice with no busted coverage, and
-- every recent cue regression (Tyrant-yellow-with-no-shards, the churn thrash, the
-- Grimoire double-voice) lived exactly there.
--
-- THE SPLIT.  HudScore.For stays a PER-ITEM pure score.  HudBoard takes the whole
-- board of scores and resolves everything that needs to see MORE THAN ONE item or
-- PRIOR paint state, emitting one CUE DESCRIPTOR per key:
--
--     { draw, colorKey, fill, pulse, shardHold }
--
-- The display layer (HudChrome) then renders that descriptor VERBATIM — it looks
-- up the RGB for `colorKey`, sets the width from `fill`, breathes on `pulse`.  It
-- makes NO decisions.  So the thrice-regressed logic now lives in one pure
-- function busted can drive (see tests/spec/hudboard_spec.lua).
--
-- POLYMORPHISM BY COMPOSITION, not inheritance (design Q, 2026-07-24).  Lua has
-- metatables, but the seam a 2nd spec plugs into (M7) is DATA, exactly as
-- SpecDemonology already is: the engine holds no spell constants.  So HudBoard is
-- a FACTORY — `HudBoard.New(cfg)` binds the spec/cue policy (specNoCue, tyrantID,
-- shardCap, the fill/pulse maps) at construction and returns an instance.
-- HudState builds one Demonology instance today; a second spec builds another with
-- its own cfg; busted builds instances with fixture cfg.  No global spec state.
--
-- cfg IS THE EASY CASE, NOT A CEILING.  Today it carries only constants
-- (specNoCue / tyrantID / fill / pulse), which risks reading as a rotation DSL —
-- limited to what data can express.  It isn't the extension seam: because New
-- returns a metatable instance, a spec whose board LOGIC differs (not just its
-- numbers) overrides `Compute` (or a resolve sub-step) in pure Lua via __index, or
-- passes a function-valued cfg field.  So a second spec is never boxed into the
-- data form — code stays available.  Demo just needs constants, so that is all cfg
-- carries for now.
--
-- PURE of frames, timers, and the live client.  It reads NOTHING secret and calls
-- no API: everything volatile arrives in `ctx` (the scores, the shard count, the
-- clock, the combat flag, the prior paint state).  Deterministic in -> out, which
-- is the whole point — it makes the cue decision testable.
--
-- ⚠ ONE deliberate mutation.  Filler resolution and LATE promotion change the
-- TRUE level (they are logged and counted in `lit`), so they write `sc.level` /
-- append `sc.reasons` on the score objects `ctx.scores` hands in — those objects
-- are produced fresh by HudScore.For every Recompute and owned by this pass, so
-- mutating them is safe and matches what Recompute did inline.  The CUE-only
-- rewrites (Stabilise churn-damp, SOON, suppression, Tyrant hold) never touch
-- `sc.level`, so the row / log / `lit` keep reporting the true score.
local ADDON, ns = ...

ns.HudBoard = {}
local B = ns.HudBoard
B.__index = B

-- The level strings, matched to HudScore.LEVELS.  Kept as a local default so the
-- module loads (and busted runs) without HudScore present; cfg.levels overrides.
local LEVELS = { NEVER = "NEVER", AVAILABLE = "AVAILABLE",
                 ROTATION = "ROTATION", LATE = "LATE" }

-- CUE POLICY — the fill fraction and pulse period per colour key.  These moved
-- OUT of HudChrome (the old CUE_FILL / CUE[].pulse) because they are DECISIONS the
-- engine now makes; HudChrome keeps only the render resources (RGB + alpha).  A
-- cfg may override either map to reskin without touching the engine.
--   fill  — fraction of the icon-sized box the colour occupies (§4.4).
--   pulse — slow alpha-breathe period in seconds; nil = steady.
local DEFAULT_FILL  = { JUDGE = 0.25, SOON = 0.45, ROTATION = 0.80, LATE = 1.00, BURST = 1.00 }
local DEFAULT_PULSE = { SOON = 0.85, LATE = 1.3 }   -- JUDGE / ROTATION steady

-- cfg (all optional except the spec bindings):
--   specNoCue  live-id -> true : suppress the cue on this ability (Grimoires — the
--              burst pane owns them, an independent cue is a second voice).
--   tyrantID   the burst go-signal's spellID (yellow until shards are capped).
--   shardCap   full-bar shard count (Tyrant's "go is real" threshold).
--   lateAfter  seconds a candidate must idle before promoting to LATE.
--   fill/pulse cue policy maps (default above).
--   levels     the level-string table (default LEVELS).
--   stabilise  the churn-damp fn (default ns.HudScore.Stabilise) — injectable so a
--              spec test can drive it in isolation.
function B.New(cfg)
  cfg = cfg or {}
  local self = setmetatable({}, B)
  self.specNoCue = cfg.specNoCue or {}
  self.tyrantID  = cfg.tyrantID
  self.shardCap  = cfg.shardCap or 5
  self.lateAfter = cfg.lateAfter or 3.0
  self.fill      = cfg.fill or DEFAULT_FILL
  self.pulse     = cfg.pulse or DEFAULT_PULSE
  self.L         = cfg.levels or (ns.HudScore and ns.HudScore.LEVELS) or LEVELS
  self.stabilise = cfg.stabilise or (ns.HudScore and ns.HudScore.Stabilise)
  return self
end

-- The colour key a painted level maps to.  Was HudChrome.SetCue's `bkey` block:
-- SOON/ROTATION/LATE map straight across; a plain AVAILABLE only lights when it is
-- JUDGE-ready (a judgeable=false ability otherwise up — Implosion off cooldown).
-- Everything else returns nil = no cue.
local function colorKeyFor(paintKey, sc, L)
  if paintKey == "SOON" then return "SOON"
  elseif paintKey == L.ROTATION then return "ROTATION"
  elseif paintKey == L.LATE then return "LATE"
  elseif paintKey == L.AVAILABLE and sc.judgeReady then return "JUDGE"
  end
  return nil
end

-- ctx (per Compute call — everything volatile):
--   scores          key -> score table | false   (false = HudScore.For threw / no
--                   dot; nil keys are simply absent).  A score carries level /
--                   candidate / soon / projected / judgeReady / emphasis / cadence
--                   / reasons, exactly as HudScore.For returns.
--   live            key -> live spellID (S.LiveID) — for suppression + Tyrant.
--   prevScore       key -> the PREVIOUS pass's score (transition detection).
--   prevCueLevel    key -> the level the cue was PAINTED at last pass (Stabilise).
--   prevCueProjected key -> was that painted level projection-derived? (Stabilise).
--   candidateSince  key -> observed timestamp the candidacy began (LATE clock).
--   now, inCombat   the clock + the secure-lockdown flag.
--   shards          the live shard count (number | nil) — Tyrant's go-gate.
--
-- Returns a board:
--   cues            key -> descriptor { draw, colorKey, fill, pulse, shardHold }
--   transitions     list of { key, from, to, soon, projected, cleared } — the
--                   dot moves worth logging; HudState formats + feeds HudLog.
--   lit, litKeys    ROTATION/LATE count + their keys (the strictness signal).
--   cueLevelNext    key -> painted level to remember (Stabilise state).
--   cueProjectedNext key -> was it projection-derived (Stabilise state).
--   candidateSinceNext key -> the LATE clock to remember.
--   tyrantShardHold true when Tyrant is held yellow for shards (HudRow's SHARDS!
--                   call-out reads the descriptor's shardHold; this is the board
--                   summary kept for parity with the old S.tyrantShardHold).
function B:Compute(ctx)
  local L = self.L
  local out = {
    cues = {}, transitions = {}, lit = 0, litKeys = {},
    cueLevelNext = {}, cueProjectedNext = {}, candidateSinceNext = {},
    tyrantShardHold = false,
  }

  -- ── Phase 1 — board-aware FILLER resolution.  The filler (Shadow Bolt) is "what
  -- you press when nothing else is lit", so it can only be decided against the
  -- whole board, which the per-item scorer cannot see.  HudScore leaves it
  -- AVAILABLE; here it goes NEVER when a real call is up, else it IS the press
  -- (ROTATION in combat, but never a LATE candidate — a filler shouldn't nag).
  local anyRotation = false
  for _, sc in pairs(ctx.scores) do
    if sc and sc.level == L.ROTATION then anyRotation = true break end
  end
  for _, sc in pairs(ctx.scores) do
    if sc and sc.cadence == "filler" and sc.level == L.AVAILABLE then
      if anyRotation then
        sc.level = L.NEVER
        sc.reasons[#sc.reasons + 1] = "better options up"
      elseif ctx.inCombat then
        sc.level = L.ROTATION
        sc.candidate = false
        sc.reasons[#sc.reasons + 1] = "filler — nothing better up"
      end
    end
  end

  -- ── Phase 2 — per key: LATE clock, transition, lit count, cue descriptor.
  for key, sc in pairs(ctx.scores) do
    if sc then
      -- LATE — a NAG, so combat-gated on BOTH the clock and the promotion (they
      -- are one decision).  Out of combat no clock runs and no stamp is kept, so a
      -- candidate carries no stale timestamp into the pull (the M3e stamp bug).
      if sc.candidate and ctx.inCombat then
        local since = (ctx.candidateSince and ctx.candidateSince[key]) or ctx.now
        out.candidateSinceNext[key] = since
        if (ctx.now - since) >= self.lateAfter then
          sc.level = L.LATE
          sc.reasons[#sc.reasons + 1] = string.format("waiting %.0fs", ctx.now - since)
        end
      end
      -- (candidateSinceNext[key] left nil otherwise = clock cleared.)

      -- TRANSITION — a move of the level, or of soon/projected (both change what
      -- the dot CLAIMS even at an unmoved level).  The `why` string is built by
      -- HudState from the resolved score; here we only flag the move.
      local prev = ctx.prevScore and ctx.prevScore[key]
      if not prev or prev.level ~= sc.level
          or (prev.soon or false) ~= (sc.soon or false)
          or (prev.projected or false) ~= (sc.projected or false) then
        out.transitions[#out.transitions + 1] = {
          key = key, from = prev and prev.level, to = sc.level,
          soon = sc.soon or false, projected = sc.projected or false,
        }
      end

      -- LIT — the strictness signal (ROTATION or LATE).
      if sc.level == L.ROTATION or sc.level == L.LATE then
        out.lit = out.lit + 1
        out.litKeys[out.lit] = key
      end

      -- ── The CUE descriptor.  From here nothing touches sc.level: these are
      -- CLAIMS to the player, and the true score has already been fixed above.
      -- Stabilise — an ESTIMATE (in-flight shard projection) may not move a cue
      -- painted from a real reading (the churn gate).
      local painted = self.stabilise and self.stabilise(
        ctx.prevCueLevel and ctx.prevCueLevel[key],
        ctx.prevCueProjected and ctx.prevCueProjected[key], sc) or sc.level
      out.cueLevelNext[key]     = painted
      out.cueProjectedNext[key] = sc.projected or false

      -- SOON is a treatment on NEVER — an anticipating dot brightens + counts down
      -- but never claims pressability.
      local paintKey = (sc.soon and painted == L.NEVER) and "SOON" or painted

      -- TYRANT is yellow until the go is real: green on the burst button is the one
      -- signal that means "press NOW", so it is held to SOON until Tyrant is
      -- pressable AND shards are capped.  Unreadable shards read as NOT full — a
      -- green we cannot justify is the one we must not draw.
      local shardHold = false
      if self.tyrantID and ctx.live and ctx.live[key] == self.tyrantID
          and paintKey and paintKey ~= "SOON" then
        local held = ctx.shards
        local full = (type(held) == "number") and held >= self.shardCap
        if not full then paintKey = "SOON"; shardHold = true end
      end
      if shardHold then out.tyrantShardHold = true end

      -- SUPPRESSION — SpecNoCue abilities (Grimoires) carry no independent cue.
      local live = ctx.live and ctx.live[key]
      local suppressed = live and self.specNoCue[live] and true or false

      local colorKey = colorKeyFor(paintKey, sc, L)
      if suppressed or not colorKey then
        out.cues[key] = { draw = false, shardHold = shardHold }
      else
        local fill = (sc.emphasis == "burst") and self.fill.BURST
          or (self.fill[colorKey] or self.fill.JUDGE)
        out.cues[key] = {
          draw = true, colorKey = colorKey, fill = fill,
          pulse = self.pulse[colorKey], shardHold = shardHold,
        }
      end
    else
      -- No score (false) — losing a dot is a transition too, and a LOUD one: it is
      -- what an unrecognised override looks like (HudScore returns nil rather than
      -- inheriting the base's cadence).  Clear the cue and log the loss.
      local prev = ctx.prevScore and ctx.prevScore[key]
      if prev then
        out.transitions[#out.transitions + 1] =
          { key = key, from = prev.level, to = nil, cleared = true }
      end
      out.cues[key] = { draw = false }
    end
  end

  return out
end
