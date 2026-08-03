-- CoachRetribution.lua — the RETRIBUTION PALADIN decision brain (spec 70).
--
-- WHAT THIS IS.  The three methods the generic Coach shell delegates to, hung on the spec
-- object SpecRetribution.lua registered, plus this spec's tunables:
--   spec:Context(state, env)               fold the pulse into whole-board facts
--   spec:RankWinner(ctx, excluded)         the flat priority list — first usable line wins
--   spec:Escalate(winnerKey, level, ctx)   ROTATION -> LATE, from READABLE overdue-ness only
-- The shell (Coach.lua) owns Classify / Emit / ResourceBars and never learns a spell id.
--
-- THE LIST IT IMPLEMENTS is specs/retribution/rotation.md (the spec of record, distilled
-- from the Tier-1 simc APL `ActionPriorityLists/default/paladin_retribution.simc` @ ab7b0b8,
-- 2026-08-01).  Line numbers L1-L12 below are that document's, so the two can be diffed by
-- eye.  Where a line's real gate is not readable the degradation is stated AT the line
-- rather than faked — the standing rule is that absence of a read never becomes a positive
-- claim.
--
-- HOW RETRIBUTION DIFFERS FROM THE TWO WARLOCK BRAINS, structurally:
--   * THE RESOURCE IS PLAIN.  Holy Power is 0-5 with modifier 1, so the exact rail and the
--     display rail are the SAME integer.  There is no fragment arithmetic, no unit boundary,
--     no `*Frags` naming — and deliberately so: Destruction's `cost * FRAGS_PER_SHARD` would
--     be a silent 1x no-op here that teaches the next reader the wrong lesson.
--   * NO RESOURCE BAR IS DRAWN.  `display = "none"` (SpecRetribution.lua): the power rides
--     the whole rail into the decision log's `PW:` column and the Renderer skips it.
--   * NO BURST SETUP BLOCK.  Nothing is held for Avenging Wrath — no partner summon, no
--     pooling — so it is a plain on-cooldown line, and Escalate has no window suppression.
--     Structurally Destruction, not Demonology.
--   * CHARGES ARE EVERYWHERE.  Destruction had ONE charged ability; here SIX of the nine
--     Essential buttons keep their cooldown on a SpellCategory with RecoveryTime = 0, so the
--     napkin is blind on most of the spec and usable() carries far more weight.  See its
--     header — this is the spec's defining observability fact.
--   * THE SPENDER IS A FRAME, NOT A BUTTON.  Hammer of Light, Final Verdict and the Templar
--     strikes all arrive as spell OVERRIDES on tracked frames.  That channel is readable in
--     restricted combat, which is the whole reason Templar is the v1 profile.
--
-- LOAD ORDER.  Loads right after SpecRetribution.lua (so ns.Specs[70] exists) and may sit
-- before Coach.lua: every ns.Coach.* reference here is runtime-only, never touched at load.
local ADDON, ns = ...

local spec = ns.Specs[70]   -- the Retribution object registered by SpecRetribution.lua

--------------------------------------------------------------------------------
-- Tunables (seconds / Holy Power).  Fields on the spec object, so a sibling spec's values
-- can never leak in as file-locals.
--------------------------------------------------------------------------------
spec.LATE_LEAD = 4.0    -- a probably-up press left elapsed this long => overdue.  Read by
                        -- the shell's Classify off ns.ActiveSpec.LATE_LEAD.

-- The spender cost, IN HOLY POWER — the only unit this spec has.  ALWAYS resolved live
-- through env.shardCostFn (talent-modifiable); this is only the fallback for a harness or an
-- unreadable read.  Never hardcode a cost at a call site.
-- ⚠ 3, NOT 5 (T1 DB2: SpellPower @ 12.0.7 — Templar's Verdict, Divine Storm, Final Verdict
-- and Hammer of Light all read PowerType 9, cost 3).  The KB's "spend at 5 Holy Power" is a
-- POOLING rule, and reading it as a cost would double every gate in this file.
spec.SPENDER_COST_FALLBACK = 3

-- ⚠ THE ONE GENUINELY UNSETTLED READ (the ART_FROM_RITUAL precedent).  rotation.md L1 is
-- "if Hammer of Light is armed, press it", and the unambiguous source for that is the
-- OVERRIDE on the spender frame — a transformed spender IS an armed Hammer of Light.  The
-- tempting second source is the Light's Deliverance buff (433674), and it is NOT equivalent:
-- Light's Deliverance is a STACKING buff that grants a free Hammer of Light at its
-- threshold, and the stack count is a Secret Value.  If the buff is simply present for most
-- of the cycle — which is what a stacking ramp does — treating its presence as "armed" would
-- jam L1 above Execution Sentence and Avenging Wrath permanently.
-- So the default is FALSE: only a visible transform arms it.  Flip this only if
-- `/cdmp hud layout` + the decision log show 433674 present ONLY while a free Hammer of
-- Light is genuinely available.  A one-line, one-place reversal, deliberately not a guess
-- baked into the cascade.
spec.RET_HOL_FROM_BUFF = false

local function ids()
  return ns.SpecIDs or {}
end

-- Honest pulse-number reader: a non-number reads nil, never a guess.
local function num(v) return type(v) == "number" and v or nil end

--------------------------------------------------------------------------------
-- Context — the whole-board facts the cascade reads (contract: Coach.lua's header).
--------------------------------------------------------------------------------
function spec:Context(state, env)
  local S = ids()
  local abilities = state.abilities or {}

  local factsByBase = {}
  for _, entry in pairs(abilities) do
    local rec = ns.Coach.Classify(entry, state)
    if rec and rec.base then
      -- One record per base spellID by construction (State already folded the CDM's N rows
      -- of an ability into one pressable representative).
      factsByBase[rec.base] = rec
    end
  end

  -- Buff PRESENCE off the domain view's spellID-keyed set.  Secrecy is already folded in by
  -- State (an unreadable aura is absence there, never a false true).  ⚠ PRESENCE ONLY —
  -- every Retribution proc that matters has a secret stack count and a secret duration, so
  -- there is nothing else to read.  That is what kills all four of simc's free-Hammer-of-
  -- Light timing clauses (rotation.md Deviation 1).
  local function buffActive(spellID)
    return (state.buffs and state.buffs[spellID] == true) or false
  end

  -- The in-flight projection, derived from the pulse's cast history.
  local sums = ns.Coach.InflightPower(state, ns.SpecPowerDelta)

  -- ── THE HOLY POWER RAIL ────────────────────────────────────────────────────
  -- Shared arithmetic (ns.Coach.PowerContext): the exact read, the display-value fallback
  -- when the client refuses, the cap fallbacks, and the ctx.powers fold.  ⚠ Holy Power's
  -- modifier is 1, so `rails.HolyPower.value` is simply Holy Power — there is no second unit
  -- in this spec and nothing here is named `*Frags`.
  local bars, rails = ns.Coach.PowerContext(state, self, sums)
  local hpRail = rails.HolyPower or {}

  local ctx = {
    facts = factsByBase,
    mode = state.mode,
    hp = hpRail.value,
    hpIncoming = hpRail.incoming or 0,
    hpMax = hpRail.max or self.HP_CAP,
    hpProjected = hpRail.projected,
    atCap = hpRail.atCap or false,
    powerReadable = hpRail.readable or false,
  }
  ctx.powers = bars

  -- The live spender cost, resolved once per pulse.  The shell owns the INJECTED reader
  -- (env.shardCostFn = cfg.shardCost); this brain owns WHICH spell costs and the fallback.
  -- ⚠ NO UNIT CONVERSION.  ns.ShardCost returns the cost in the power's DISPLAY units and
  -- Holy Power's divisor is 1, so display units ARE exact units.  Destruction multiplies by
  -- 10 at this exact point; copying that here would be a silent 10x error.
  local function costOf(spellID, fallback)
    if env and env.shardCostFn and spellID then
      local c = env.shardCostFn(spellID)
      if type(c) == "number" and c > 0 then return c end
    end
    return fallback
  end
  ctx.spenderCost = costOf(S.TEMPLARS_VERDICT, self.SPENDER_COST_FALLBACK)

  -- ── Readiness, CHARGE-AWARE ────────────────────────────────────────────────
  -- An ability with a charge banked is usable even while its recharge timer runs, so a
  -- charged ability's readiness is NOT its cooldown state.  `ns.ReadCharges` is combat-gated
  -- (C_Spell.GetSpellCharges reads secret in restricted combat), so the EXACT count is an
  -- out-of-combat luxury; in a pull State carries a napkin estimate, biased to UNDERCOUNT.
  --
  -- ⚠ FOR A CHARGED ABILITY THE COUNT IS AUTHORITATIVE — the cooldown state is NOT, and
  -- trusting it is what made the HUD recommend Conflagrate at ZERO charges on 190 of 194 log
  -- lines.  The mechanism, measured: the CDM raises `Available` every time a CHARGE is
  -- restored but never raises `OnCooldown` at all for a charged ability, so State's
  -- ready-edge latches true on the first charge and is never cleared — `cd` then reads
  -- `ready` forever.  The napkin cannot rescue it either, because a charged spell's
  -- RecoveryTime is 0 in DB2 and the base-cooldown countdown has nothing to count.
  --
  -- ⚠ AND ON THIS SPEC THAT IS NOT AN EDGE CASE.  SIX of the nine Essential buttons —
  -- Judgment, Crusader Strike, Blade of Justice, Wake of Ashes, Hammer of Wrath and Avenging
  -- Wrath — keep their cooldown on a SpellCategory with RecoveryTime = 0 (T1 DB2 @ 12.0.7),
  -- so the napkin is blind on most of the rotation and this function is doing most of the
  -- work.  Whether a ONE-charge category is even marked `charges = true` on the CDM row is
  -- unknown offline; usable() is correct either way, because it consults the count only when
  -- there IS one.  @verify-ingame
  --
  -- Cloned verbatim from CoachDestruction.lua's usable() — deliberately, not incidentally.
  -- Two copies of a rule this expensive to learn are better than one generalisation that
  -- quietly acquires a spec's assumptions; if a third spec needs it, hoist it to shell kit
  -- then.
  local function chargeBanked(base)
    local row = base and abilities[base]
    local ch = row and row.charge
    if not ch then return false end
    local cur = num(ch.cur)
    return (cur ~= nil and cur >= 1) or false
  end
  local function usable(base)
    local rec = base and factsByBase[base]
    if not rec then return false end
    local ch = abilities[base] and abilities[base].charge
    if ch and ch.charged then
      local cur = num(ch.cur)
      if cur ~= nil then return cur >= 1 end
    end
    return rec.probablyUp or chargeBanked(base)
  end
  ctx.wingsUsable     = usable(S.AVENGING_WRATH)
  ctx.executionUsable = usable(S.EXECUTION_SENTENCE)
  ctx.tollUsable      = usable(S.DIVINE_TOLL)
  ctx.woaUsable       = usable(S.WAKE_OF_ASHES)
  ctx.bojUsable       = usable(S.BLADE_OF_JUSTICE)
  ctx.judgmentUsable  = usable(S.JUDGMENT)
  ctx.howUsable       = usable(S.HAMMER_OF_WRATH)
  ctx.fillerUsable    = usable(S.CRUSADER_STRIKE)

  -- ── The spender overrides (Templar + the Final Verdict talent) ─────────────
  -- WHICH tracked frame carries an armed Hammer of Light.  `holFrame` is a BASE spellID (the
  -- domain-view identity), never a cooldownID.  The shell relaxed Classify's `transformed`
  -- to the generic live ~= base, so the Retribution filter (`spends == "hp"`) is re-applied
  -- here and the overrides are told apart by the semantic **`spender`** field.
  -- ⚠ NEVER BRANCH ROTATION LOGIC ON `abbr`.  It is per-ID DISPLAY only, and the reason is
  -- recorded in SpecRetribution.lua: on Destruction a shared `abbr` made a capture unable to
  -- say which numeric override had surfaced, which was the exact question it was recording
  -- for.
  for base, rec in pairs(factsByBase) do
    if rec.transformed and rec.info and rec.info.spends == "hp" then
      if rec.info.spender == "hammer_of_light" then
        ctx.holFrame = base
      end
    end
  end
  ctx.lightsDeliverance = buffActive(S.LIGHTS_DELIVERANCE)
  -- "A Hammer of Light that should be pressed."  A visible transform is that; the Light's
  -- Deliverance buff only counts when RET_HOL_FROM_BUFF says so — see the tunable's note.
  ctx.holArmed = (ctx.holFrame ~= nil)
    or (self.RET_HOL_FROM_BUFF and ctx.lightsDeliverance)
    or false

  -- ── Proc presence (never a count, never a duration) ────────────────────────
  ctx.artOfWar        = buffActive(S.ART_OF_WAR)
  ctx.righteousCause  = buffActive(S.RIGHTEOUS_CAUSE)
  ctx.empyreanPower   = buffActive(S.EMPYREAN_POWER)
  ctx.empyreanLegacy  = buffActive(S.EMPYREAN_LEGACY)
  ctx.wingsUp         = buffActive(S.AVENGING_WRATH)

  -- ── Which spender the finisher block resolves to ───────────────────────────
  -- simc: `variable.ds_castable = (active_enemies>=3-(tempest&!jurisdiction)
  --                               | buff.empyrean_power.up) & !buff.empyrean_legacy.up`
  -- We have no target roster, so the enemy-count term becomes the MANUAL mode toggle — a
  -- player DECLARATION, never an observation, exactly as Destruction's Rain of Fire does.
  -- Both buff terms survive verbatim; Empyrean Legacy makes the next Templar's Verdict
  -- cleave, so it SUPPRESSES Divine Storm rather than enabling it.
  ctx.dsCastable = ((ctx.mode == "aoe") or ctx.empyreanPower) and not ctx.empyreanLegacy
  -- The BASE key the spender lines return.  ⚠ Resolved through `facts`, so an untracked
  -- Divine Storm falls back to Templar's Verdict rather than yielding no press at all.
  local dsKey, tvKey = factsByBase[S.DIVINE_STORM] and S.DIVINE_STORM,
                       factsByBase[S.TEMPLARS_VERDICT] and S.TEMPLARS_VERDICT
  ctx.spenderKey = (ctx.dsCastable and dsKey) or tvKey or dsKey

  -- ── The hero tree ──────────────────────────────────────────────────────────
  -- Read off the PULSE (State's talent-API read; TraitSubTree 48 = Templar, 50 = Herald of
  -- the Sun), and NEVER inferred from the tracked set.  That inference is field-fix B: on
  -- Destruction, deriving the tree from a tracked ability corrupted both answers at once on
  -- the first live session.
  -- ⚠ NO INFERENCE FALLBACK HERE, and that is deliberate rather than an omission.  On
  -- Destruction the fallback exists because the tree GATES rotation lines.  It does not
  -- here: L1 fires because a Hammer of Light transform is visible, which is a Templar fact
  -- that announces itself, and no other line branches on the tree at all.  A guessed tree
  -- would therefore buy nothing and could only mislead the log.
  ctx.hero = state.hero
  ctx.templar = (ctx.hero == "templar")

  -- ── The execute gate (L9's missing half) ───────────────────────────────────
  -- Target health at or below 20%.  This is NOT a Secret Value — it is ordinary unit data
  -- simply absent from the pulse, because State has no target channel at all.  The read
  -- below is written against the shape a target channel would take, so it is nil-safe today
  -- (=> false, the execute half never fires) and correct the day one is added.
  local tgt = state.target
  local hp = tgt and num(tgt.healthPct)
  ctx.targetExecute = (hp ~= nil and hp <= 20) or false

  return ctx
end

--------------------------------------------------------------------------------
-- RankWinner — THE FLAT PRIORITY LIST (specs/retribution/rotation.md L1–L12).
--    Evaluated top to bottom; the FIRST line whose ability is usable is the one press.
--    Returns winnerKey, level, note.
--------------------------------------------------------------------------------
-- `excluded` (contract: Coach.lua's header) matters here for the same reason it does on
-- Destruction: the SPENDER sits on three lines (L1 as Hammer of Light, L4 the anti-overcap
-- dump, L8 the main dump) and Blade of Justice on two (L7 procced, L10 plain).  All of them
-- key on the same base spellID — including the transform line, which rides its base frame —
-- so one exclusion drops every occurrence.
function spec:RankWinner(ctx, excluded)
  local S = ids()
  -- Holy Power throughout, plain integers: `projected` is the live rail plus the signed
  -- in-flight delta.  There is no second unit in this spec.
  local projected = ctx.hpProjected or ctx.hp or 0

  -- The Coach decides in BASE spellIDs, so key() is IDENTITY — it only gates on the ability
  -- being TRACKED (present in ctx.facts).  An untracked line yields nil and evaluation
  -- continues; that is exactly how Retribution degrades on a Radiant Glory build (no
  -- Avenging Wrath button) or if Hammer of Wrath never gets a virtual row.
  local function key(base) return (base and ctx.facts[base]) and base or nil end

  -- pick — the line's candidate, or nil to keep evaluating.
  local function pick(k, level, note)
    if k and k ~= excluded then return k, level, note end
    return nil
  end
  local k, lv, nt

  -- L1 — HAMMER OF LIGHT, whenever it is armed.  The Templar payoff, and the top of simc's
  -- finisher block.  It rides the spender frame as an OVERRIDE, so a transformed spender IS
  -- an armed Hammer of Light — no separate readiness read exists or is needed.
  -- ⚠ simc's four free-proc TIMING clauses are dropped (rotation.md Deviation 1): they are
  -- all `buff.X.remains < gcd*N`, and buff durations are Secret Values in combat.  simc's
  -- FIRST clause — "if this is the paid one, just press it" — is what we implement, and
  -- pressing a free proc early is the safe direction: the cost is a little optimisation,
  -- where holding risks wasting it outright.
  -- Affordability still gates it: Hammer of Light costs 3 Holy Power like every finisher.
  if ctx.holArmed and projected >= ctx.spenderCost then
    local target = ctx.holFrame or ctx.spenderKey
    k, lv, nt = pick(target, "ROTATION", "Hammer of Light")
    if k then return k, lv, nt end
  end

  -- L2 — Execution Sentence on cooldown.  ⚠ simc pairs it with Wake of Ashes
  -- (`cooldown.wake_of_ashes.remains<gcd`) and that handshake is dropped: a cooldown-remains
  -- read of ANOTHER ability is secret in combat, and the napkin that normally covers for it
  -- has nothing to count down from here (WoA's RecoveryTime is 0 — see usable()'s header).
  if ctx.executionUsable then
    k, lv, nt = pick(key(S.EXECUTION_SENTENCE), "ROTATION"); if k then return k, lv, nt end
  end

  -- L3 — Avenging Wrath on cooldown: the whole burst window, as a plain press.  Nothing is
  -- staged for it and nothing is held, so it never reads as a hold.  On a Radiant Glory
  -- build the button does not exist and this line simply finds nothing — a free degradation
  -- that needs no talent read.
  if ctx.wingsUsable then
    k, lv, nt = pick(key(S.AVENGING_WRATH), "ROTATION"); if k then return k, lv, nt end
  end

  -- L4 — SPEND AT CAP, unless Wake of Ashes is ready.  simc:
  -- `call_action_list,name=finishers,if=holy_power=5&cooldown.wake_of_ashes.remains`.
  -- ⚠ THE SECOND CLAUSE IS NOT A DETAIL.  At cap with WoA READY you press WoA anyway (L5),
  -- because WoA ARMS HAMMER OF LIGHT and the armed spender is worth more than the overcap.
  -- `cooldown.wake_of_ashes.remains` means "WoA is on cooldown", which is `not woaUsable` —
  -- one of the few cooldown-remains terms in this APL that survives as a boolean.
  -- ⚠ THE AFFORDABILITY TERM IS NOT REDUNDANT even though cap >= cost today.  simc applies
  -- an implicit resource check to every action, and the cost is read LIVE — so a talent that
  -- ever raised a spender above the cap would otherwise make this line cue a press that
  -- fails.  Every line in this file carries its ability's real gate; this one is no exception.
  if projected >= (ctx.hpMax or 5) and projected >= ctx.spenderCost and not ctx.woaUsable then
    k, lv, nt = pick(ctx.spenderKey, "ROTATION", "at cap"); if k then return k, lv, nt end
  end

  -- L5 — Wake of Ashes on cooldown.  Arms Hammer of Light for 20s, which is the reason L4
  -- steps aside for it.
  if ctx.woaUsable then
    k, lv, nt = pick(key(S.WAKE_OF_ASHES), "ROTATION"); if k then return k, lv, nt end
  end

  -- L6 — Divine Toll on cooldown.
  if ctx.tollUsable then
    k, lv, nt = pick(key(S.DIVINE_TOLL), "ROTATION"); if k then return k, lv, nt end
  end

  -- L7 — Blade of Justice on an Art of War / Righteous Cause proc (a free instant).  Both
  -- are tracked buffs, so this is ordinary readable presence.
  if ctx.bojUsable and (ctx.artOfWar or ctx.righteousCause) then
    local note = ctx.artOfWar and "Art of War" or "Righteous Cause"
    k, lv, nt = pick(key(S.BLADE_OF_JUSTICE), "ROTATION", note); if k then return k, lv, nt end
  end

  -- L8 — SPEND.  simc's unconditional `call_action_list,name=finishers` in the middle of the
  -- generator list.  Which spender: Divine Storm when `dsCastable`, else Templar's Verdict
  -- (or Final Verdict, its talent override, which rides the same frame).
  if projected >= ctx.spenderCost then
    local note = ctx.dsCastable and "Divine Storm" or nil
    k, lv, nt = pick(ctx.spenderKey, "ROTATION", note); if k then return k, lv, nt end
  end

  -- L9 — Hammer of Wrath, WHILE AVENGING WRATH IS UP.  ⚠ Its real gate is
  -- `target.health.pct<20 | buff.avenging_wrath.up | talent.walk_into_light`, and we can read
  -- exactly one of those three.  So outside wings, in genuine execute range, we simply MISS
  -- the press — a missed cue, never a wrong one (rotation.md Deviation 4).  `targetExecute`
  -- is structurally false today and is read anyway, so the day State grows a target channel
  -- this line is already correct.
  -- ⚠ DOUBLY DEGRADED: Hammer of Wrath is not in the tracked set at all, so this can only
  -- ever fire if the virtual-row walk picks it up.  @verify-ingame
  if ctx.howUsable and (ctx.wingsUp or ctx.targetExecute) then
    local note = ctx.wingsUp and "wings" or "execute"
    k, lv, nt = pick(key(S.HAMMER_OF_WRATH), "ROTATION", note); if k then return k, lv, nt end
  end

  -- L10 — Blade of Justice on cooldown, no proc needed.
  if ctx.bojUsable then
    k, lv, nt = pick(key(S.BLADE_OF_JUSTICE), "ROTATION"); if k then return k, lv, nt end
  end

  -- L11 — Judgment on cooldown.
  if ctx.judgmentUsable then
    k, lv, nt = pick(key(S.JUDGMENT), "ROTATION"); if k then return k, lv, nt end
  end

  -- L12 — the FILLER: the Crusader Strike frame, whatever override it is showing (Templar
  -- Strike / Templar Slash on Templar).  We press the FRAME and let the game decide which
  -- strike comes out, because the alternation is Blizzard's and not ours.  2 charges on a 6s
  -- recharge, which is why usable() reads the count first.
  if ctx.fillerUsable then
    k, lv, nt = pick(key(S.CRUSADER_STRIKE), "ROTATION"); if k then return k, lv, nt end
  end

  -- No press.  Honest, and visible in the decision log as `w:-` — which on this spec is the
  -- signature of "every builder is on cooldown and there is not enough Holy Power to spend",
  -- a real state rather than a bug.
  return nil
end

--------------------------------------------------------------------------------
-- Escalate — Retribution's readable overdue-ness.
--------------------------------------------------------------------------------
-- Two readable ways to be late, and NO window suppression: unlike Demonology (where a ready
-- summon inside the Tyrant window is a STAGED press, not a forgotten one), Retribution holds
-- nothing, so a ready burst button sitting idle is always genuinely late.
function spec:Escalate(winnerKey, level, ctx)
  if not winnerKey or level ~= "ROTATION" then return level end
  local S = ids()
  local rec = ctx.facts[winnerKey]
  if not rec then return level end

  -- 1. A burst cooldown left sitting past the lead.  `overdue` is computed by the shell off
  --    cd.changedAt, i.e. from how long it has READ ready — not from a napkin guess.
  --    ⚠ Only the three RecoveryTime-bearing cooldowns are listed.  Wake of Ashes is a burst
  --    button too, but its cooldown lives on a charge category, so its readiness edge is the
  --    charge-restore Available — which fires on every recharge and would make `overdue`
  --    meaningless.  Escalating on a signal we cannot trust is exactly what this method is
  --    forbidden to do.
  if (rec.base == S.AVENGING_WRATH or rec.base == S.EXECUTION_SENTENCE
      or rec.base == S.DIVINE_TOLL) and rec.overdue then
    return "LATE"
  end

  -- 2. The spender parked at a FULL Holy Power bar — the readable overcap dump, the
  --    analogue of Destruction's Chaos-Bolt-at-full-bar rule.  Gated on ACTUAL Holy Power,
  --    not the projection: an in-flight spender has already committed to draining the bar,
  --    so projecting it would call you late for something you are mid-way through fixing.
  --    No burst carve-out, because Retribution never pools for a window on purpose.
  --    ⚠ Note this deliberately does NOT respect L4's Wake-of-Ashes exception.  L4 declines
  --    to DUMP while WoA is ready; that is a priority choice.  Sitting at a genuinely full
  --    bar is still a readable mistake, and saying so is the whole job of LATE.
  if rec.base == ctx.spenderKey and ctx.hp
      and ctx.hp >= (ctx.hpMax or self.HP_CAP) then
    return "LATE"
  end

  return level
end
