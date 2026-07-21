-- HudScore.lua — the dot score.  A level, and the REASONS for it.
--
-- WHY THIS EXISTS (guidance-model.md §0.5.8.7).  M3b encoded state as colour,
-- luminance, thickness and glow, and five in-game passes said the same thing:
-- "yellow, purple etc. don't really have any meaning in isolation."  That's
-- correct and structural — hue carries GROUP, which is ambient IDENTITY, not
-- instruction.  No amount of re-tuning a colour makes an arbitrary encoding
-- instructive.  And there is no free visual channel left: hue = group,
-- saturation = resource pole, luminance = readiness, alpha = recede.
--
-- So the answer is a NEW OBJECT — a per-ability dot carrying an actionability
-- level — plus a text row saying WHY.  At a glance 1-2 dots say "these are your
-- live candidates"; the row beside each says what made it so.
--
-- THE GOVERNING PRINCIPLE is "inform, don't instruct": the HUD narrows the
-- field, the player chooses within it.  "Pick between 2-3 abilities instead of
-- 5."  Two consequences are baked into the rules below and neither is optional:
--
--   * The score is AUDITABLE, NEVER AN ORACLE.  Every level carries reasons, and
--     the reasons are what the row prints.  A dot you disagree with is a scoring
--     bug you can argue with; a dot with no reason is a design failure.
--   * Where the TRUE gate is a Secret Value we cannot read, we CAP AT AVAILABLE
--     and say so (`judgeable = false`).  A confidently-wrong ROTATION is worse
--     than no dot — §0.5.8.2(c) forbids it.
--
-- This module is a PURE FUNCTION of readable state.  It reads nothing secret,
-- owns no frames, starts no timers, and holds no spell constants of its own
-- (they all live in SpecDemonology).  LATE is applied by HudState, which owns
-- the `candidateSince` clock.
local ADDON, ns = ...

ns.HudScore = {}
local Sc = ns.HudScore

-- The four levels.  Deliberately few, and deliberately about ACTIONABILITY
-- rather than about the ability:
--   NEVER      you cannot press this now (gate closed or on cooldown)
--   AVAILABLE  you CAN press it; we're not calling it
--   ROTATION   this is a live candidate right now
--   LATE       it's been a live candidate for a while and you haven't pressed it
-- SOON is NOT a fifth level — it is a TREATMENT on NEVER (§0.5.8.7 §1).  An
-- anticipating dot never claims pressability, so it never needs filtering out.
Sc.LEVELS = { NEVER = "NEVER", AVAILABLE = "AVAILABLE",
              ROTATION = "ROTATION", LATE = "LATE" }

--------------------------------------------------------------------------------
-- Is a proc armed on this button?
--------------------------------------------------------------------------------
-- Reads the SAME ns.SpecProcGlow table that drives the M3b glow, on purpose: the
-- glow and the dot can then never disagree about what's armed.  Core -> Demonbolt
-- comes off aura presence; Art -> HoG comes off the live spell override, which is
-- the precise trigger (the Diabolic Ritual buff is present through most of the
-- accumulation, so its mere presence would be lit nearly all the time).
function Sc.ProcArmed(spellID)
  local St = ns.HudState
  if not (St and ns.SpecProcGlow) then return false end
  for sourceID, rule in pairs(ns.SpecProcGlow) do
    if rule.target == spellID then
      if rule.transform then
        if St.override[spellID] ~= nil then return true, rule.why or "armed" end
      elseif St.SourcePresent and St.SourcePresent(sourceID) then
        return true, rule.why or "proc up"
      end
    end
  end
  return false
end

--------------------------------------------------------------------------------
-- The score
--------------------------------------------------------------------------------
-- Returns nil for anything that carries no dot (aura viewer entries), else:
--   { level, reasons = {…}, candidate = bool, soon = bool, remain = n|nil }
-- `candidate` is the raw ROTATION-eligibility HudState clocks for LATE; `level`
-- is what to draw right now.
function Sc.For(key, e)
  local St = ns.HudState

  ------------------------------------------------------------------------------
  -- LIVE IDENTITY (M3c-b B1) — score the button that is ACTUALLY THERE
  ------------------------------------------------------------------------------
  -- M3c-a opened with `local id = e.baseSpellID or e.spellID` unconditionally,
  -- so a TRANSFORMED button was judged as the ability underneath it.  Observed
  -- live and it is the worst possible failure: `lit now` read "Grimoire: Fel
  -- Ravager - up - use on cooldown - waiting 18s" while that button had been
  -- overridden into Devour Magic, a purge.  The HUD was nagging the player to
  -- press a cooldown that wasn't on the bar.  §0.5.8.2(c): a confidently-wrong
  -- dot is worse than no dot.
  --
  -- Resolution order — override event, then the item's own reported spell, then
  -- the base:
  --   * `St.override` is the FAST PATH (COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED).
  --   * `e.spellID` is the FLOOR, and it is not redundant: the override is set
  --     when the pet is summoned, which can be BEFORE we start listening (login,
  --     /reload, HUD enabled mid-session).  A missed event and an absent event
  --     are indistinguishable, so bind-time polling has to back the event up.
  --     `rebind()` reads the live spell, which is exactly why B2's secret guard
  --     is what makes this trustworthy.
  --
  -- ⚠ THIS IS THE OPPOSITE CONVENTION FROM KEYBINDS, deliberately.  HudBinds
  -- resolves off the BASE (HudBinds.lua:175, the v0.7.0 finding-3 fix) precisely
  -- because the override is on no action bar.  Identity for BINDING is the base;
  -- identity for JUDGEMENT is what's live.  Do not "unify" them.
  local base   = e.baseSpellID or e.spellID
  local liveID = (base and St and St.override and St.override[base]) or e.spellID or base

  local info, known = ns.SpecInfo(liveID)
  -- Auras are INPUTS to the score, never scored themselves.
  if info.kind == "aura" then return nil end
  -- An override we have never heard of gets NO DOT AT ALL — it must never
  -- inherit the base's cadence, which is how "use on cooldown" ended up printed
  -- over a purge.  Silence is the honest answer for an ability we can't classify.
  if liveID ~= base and not known then return nil end

  local id = liveID
  local R = {}
  local out = { reasons = R, candidate = false }
  -- Say so on the row when the thing being scored isn't the thing underneath.
  if liveID ~= base then
    R[#R + 1] = string.format("now %s", ns.SpellName(liveID) or tostring(liveID))
  end

  ------------------------------------------------------------------------------
  -- gateMet — the resource gate, with the cost READ AT RUNTIME
  ------------------------------------------------------------------------------
  -- Costs are talent-dependent (Demonic Calling makes Dreadstalkers free; the
  -- Grimoire and Tyrant costs move with the build), so any number authored into
  -- the spec table is right for exactly one loadout and silently wrong for every
  -- other.  ns.ShardCost asks the client about the character actually logged in.
  --
  -- UTILITY IS NOT SHARD-GATED, so it is not asked about (§7.2 item 2).  The
  -- utility cap lives below the cooldown check — deliberately, because a
  -- defensive on cooldown really is NEVER and must not print "your call" — but
  -- that left the RESOURCE gate running first, so a costed utility ability
  -- exited at NEVER on a gate it should never have been offered.  With the
  -- v0.10.0 unfiltered-cost defect underneath it, that read as
  -- "Mortal Coil · NEVER · shards 3<750".  Skipping the block (rather than
  -- reordering the cap) keeps both facts true: no shard reason on a utility row,
  -- and cooldown still gates it.
  local cost = (info.cadence ~= "utility") and ns.ShardCost(id) or nil
  -- B4 — the SPEND-side projection.  While a cast is in flight the gate is
  -- evaluated against the POST-CAST shard state, not the live counter, so the
  -- board tells you what to press NEXT rather than what was true a GCD ago.
  -- HudState owns the double-deduction guard; here we only consume the answer
  -- and record that it IS one, because anything promoted by an estimate has to
  -- render hollow.
  local shards, projected
  if St and St.ProjectedShards then
    shards, projected = St.ProjectedShards()
  else
    shards = St and St.shards or nil
  end
  -- `projected` is only RELEVANT to abilities the shard figure actually judges:
  -- a shard-costed one (the gate) or a generator (the overcap guard, which is the
  -- other place the projected count can change a level — Demonbolt costs no
  -- shards but refunds 2, so a projection can be the difference between "core up,
  -- press it" and "would overcap").  Everything else keeps a solid dot because
  -- nothing about its score came off an estimate.
  local shardRelevant = (cost and cost > 0) or (info.generates ~= nil)
  out.projected = (projected and shardRelevant) and true or false
  -- Only SAY it on rows where the shard figure is actually part of the judgement.
  -- A utility ability is not shard-gated, so "cast in flight -> ~3 shards" on a
  -- defensive row is the same class of noise as the v0.10.0 "Mortal Coil ·
  -- shards 3<750" defect: a true sentence about the wrong ability.
  if out.projected then
    R[#R + 1] = string.format("cast in flight -> ~%d shards", shards)
  end
  local gateMet, gateUnknown = true, false
  if cost and cost > 0 then
    if shards == nil then
      -- Shards unreadable.  We do NOT guess in either direction: the ability
      -- stays pressable-as-far-as-we-know, but a gate we cannot evaluate can
      -- never justify a ROTATION call, so this caps at AVAILABLE below.
      gateUnknown = true
      R[#R + 1] = "shards unreadable"
    elseif shards >= cost then
      R[#R + 1] = string.format("shards %d>=%d", shards, cost)
    else
      gateMet = false
      R[#R + 1] = string.format("shards %d<%d", shards, cost)
    end
  end

  ------------------------------------------------------------------------------
  -- cdReady — and the napkin, which informs NEVER but never overrides it
  ------------------------------------------------------------------------------
  -- `ready == nil` means we have NEVER OBSERVED AN EDGE for this spell, and that
  -- is NOT ready.  Guessing here would need a secret read.  For a spell with no
  -- cooldown at all (Hand of Gul'dan, Demonbolt — the #1/#2 most-pressed buttons,
  -- 729/541 pooled casts) readiness is simply the wrong question: they never fire
  -- a cooldown edge and sat at "unknown" forever under M3b.  Their gate is
  -- resource/proc, which is exactly what the rules below score.
  local baseCD = ns.BaseCooldown(id) or 0
  local hasCD  = baseCD > 0
  local ready  = ns.HudChrome.GetReady(e.item)
  local cdReady = (not hasCD) or (ready == true)

  if hasCD and not cdReady then
    -- Look the napkin up under BOTH identities.  UNIT_SPELLCAST_SUCCEEDED
    -- reports the OVERRIDE spellID while a Demonic Art transform is armed, so a
    -- napkin filed under the transformed ID would be invisible to a base-ID
    -- lookup.  No overridable spell in the tracked set has a cooldown today, so
    -- this is pre-emptive — but it's a one-line miss that would look exactly
    -- like "anticipation just doesn't work on that button".
    local remain = ns.HudNapkin.Remaining(id)
    local remainID = id
    if remain == nil and base and base ~= id then
      remain = ns.HudNapkin.Remaining(base)
      remainID = base
    end
    out.remain = remain
    -- M3d — PROVENANCE on the countdown.  Two things can now fill the napkin and
    -- they carry different confidence: `(read)` is the client's own number for
    -- this cooldown, `(est)` is our base-cooldown arithmetic off an observed
    -- cast, which haste and CDR both drift.  The dot treatment does NOT change —
    -- SOON stays HOLLOW whatever the source, because it is a claim about the
    -- FUTURE and how it was sourced doesn't change that.  Only the word does.
    out.remainSource = remain and ns.HudNapkin.SourceOf(remainID) or nil
    local suffix = (out.remainSource == "read") and " (read)"
      or (out.remainSource and " (est)" or "")
    if remain == nil then
      -- These two are NOT the same fact and printing "on CD" for both is a lie
      -- the first time the HUD is enabled: every cooldown ability sits at
      -- ready == nil until we observe an edge, including ones that are up.  The
      -- level is still NEVER — we refuse to guess readiness, that's the design —
      -- but the REASON has to say which of the two it is, or the row is claiming
      -- knowledge it doesn't have.
      -- The wording STAYS.  It is still correct for a cold start that began IN
      -- COMBAT — where reads are secret and M3d's seeding cannot run — it will
      -- simply fire far less often now.
      R[#R + 1] = (ready == false) and "on CD" or "no edge seen yet"
    elseif remain > 0 then
      R[#R + 1] = string.format("~%.1fs%s", remain, suffix)
      -- The anticipation treatment.  Brightens and counts down, and says nothing
      -- about pressability — see the SOON note at the top.
      out.soon = remain <= (ns.HudNapkin.SOON_LEAD or 3.0)
    else
      -- The estimate ran out and no Available edge has confirmed it.  Haste and
      -- CDR drift both land here.  Named honestly rather than promoted.
      R[#R + 1] = "should be up, unconfirmed"
    end
  end

  if not (gateMet and cdReady) then
    out.level = Sc.LEVELS.NEVER
    return out
  end

  ------------------------------------------------------------------------------
  -- Caps — things we will not call, and why
  ------------------------------------------------------------------------------
  if info.cadence == "utility" then
    out.level = Sc.LEVELS.AVAILABLE
    R[#R + 1] = "utility — your call"
    return out
  end

  if info.judgeable == false then
    out.level = Sc.LEVELS.AVAILABLE
    R[#R + 1] = info.secretGate or "gate is a secret value — your call"
    return out
  end

  ------------------------------------------------------------------------------
  -- ROTATION — the opinion, kept small and stated
  ------------------------------------------------------------------------------
  -- Strictness is STRICT by decision: at any moment expect 1-2 of these, not 4-5.
  -- If the board is routinely 4+ lit, the RULES are too loose and that is what
  -- gets tightened — not the visuals.
  local rot = false
  -- ProcArmed is asked about the BASE, not the live ID: ns.SpecProcGlow keys its
  -- rules on the base button (`target`) and detects a transform by looking up
  -- `St.override[base]`.  Passing the transformed ID would silently never match.
  local armed, why = Sc.ProcArmed(base)
  -- The proc reason is recorded whether or not it ends up justifying a ROTATION.
  -- It has to be: RefreshGlows lights the glow off the SAME table, so a dot that
  -- capped at AVAILABLE without mentioning the proc would leave a lit glow and a
  -- silent row disagreeing on screen — the exact invariant this module's header
  -- claims (one source of truth for "is this proc up").
  if armed then R[#R + 1] = why end
  if armed and not gateUnknown then
    rot = true
  elseif info.cadence == "oncd" and cdReady and not gateUnknown then
    -- The burst summons: use on cooldown.  This is the rule the napkin exists to
    -- give lead time for.
    rot = true
    R[#R + 1] = "up — use on cooldown"
  elseif info.cadence == "gated" and info.primary and gateMet and not gateUnknown then
    -- Hand of Gul'dan at shards >= cost.  The gate reason is already in R —
    -- but ONLY if there was a gate to evaluate.  `ns.PowerCost` reports both
    -- "genuinely free" and "cost unreadable" as 0, so a costed spender whose cost
    -- went unreadable would otherwise light ROTATION permanently at 0 shards with
    -- an EMPTY reason list.  A gated ability with no readable gate has nothing to
    -- open, so it stays AVAILABLE and says why.
    if cost and cost > 0 then
      rot = true
    else
      -- Wording deliberately true in BOTH cases, because we cannot tell them
      -- apart: the cost may be genuinely free under a talent, or it may have
      -- read unreadable.  Either way there is no gate for us to watch open.
      R[#R + 1] = "no readable shard gate — your call"
    end
  end

  -- The overcap guard — the shipped §0.5.8.4 `softenAbove` rule, expressed as a
  -- level instead of a dimmer glow.  Demonbolt refunds +2, so from 4 shards
  -- pressing it wastes the refund; the proc is real, so the dot stays AVAILABLE
  -- (not NEVER) and says why.  Generalised off `generates` rather than spelled
  -- against Demonbolt, so a second generator inherits it for free.
  if rot and info.generates and shards and (shards + info.generates) > (ns.SHARD_CAP or 5) then
    rot = false
    R[#R + 1] = string.format("would overcap at %d", shards)
  end

  out.candidate = rot
  out.level = rot and Sc.LEVELS.ROTATION or Sc.LEVELS.AVAILABLE
  return out
end

-- The reasons, as one string.  This is what makes the score arguable.
function Sc.Why(sc)
  if not sc or not sc.reasons or #sc.reasons == 0 then return "" end
  return table.concat(sc.reasons, " · ")
end
