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
-- 2026-08-01).  Line numbers L1-L11 below are that document's, so the two can be diffed by
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
-- through env.powerCostFn (talent-modifiable); this is only the fallback for a harness or an
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

  -- WHICH RESOURCE THIS SPEC'S COSTS ARE DENOMINATED IN.  Resolved from `spec.powers` by the
  -- shell kit, NOT written as a literal here — `Enum.PowerType.HolyPower` is 9, but a brain
  -- that hardcodes 9 is one refactor away from the Soul-Shard bug in the other direction.
  -- nil (no Enum / nothing declared) means every cost falls back to the declared constant,
  -- which is the honest degradation.
  ctx.costPowerType = ns.Coach.CostPowerType(self)

  -- The live spender cost.  The shell owns the INJECTED reader (env.powerCostFn =
  -- cfg.powerCost); this brain owns WHICH spell costs, in WHICH resource, and the fallback.
  -- ⚠ NO UNIT CONVERSION.  ns.ShardCost returns the cost in the power's DISPLAY units and
  -- Holy Power's divisor is 1, so display units ARE exact units.  Destruction multiplies by
  -- 10 at this exact point; copying that here would be a silent 10x error.
  --
  -- ⚠ A COST OF **0** IS AN ANSWER, NOT A REFUSAL, and this used to get it backwards.  The
  -- guard read `type(c) == "number" and c > 0`, so a genuinely FREE finisher — Divine Purpose
  -- (408459), an Empyrean Power Divine Storm, a Light's Deliverance Hammer of Light — came
  -- back as 0, was mistaken for "unreadable", and fell through to the fallback of 3.  The HUD
  -- then refused to cue a free spender at 0-2 Holy Power, which is exactly when it is worth
  -- the most.  This is the project's own ABSENT-IS-NEVER-ZERO rule run in reverse (a real
  -- zero impersonating a refusal).  Do not re-add the `> 0`.
  --
  -- ⚠⚠ BUT REMOVING THAT GUARD IS WHAT MADE THE FLIGHT OF 2026-08-03 CUE A SPENDER AT ZERO
  -- HOLY POWER, and the reason is worth reading before touching either half.  The guard was
  -- load-bearing for a second, ACCIDENTAL reason: the shell wired `ns.ShardCost`, which
  -- filters to Soul Shards, so a Paladin spender matched nothing and the reader (whose old
  -- contract returned 0 for "absent") answered 0.  `> 0` rejected it and the fallback of 3
  -- happened to be right.  Removing `> 0` was correct in itself and turned that silent
  -- mis-wiring into a live defect: `spenderCost = 0` makes L7's `projected >= cost` the
  -- tautology `projected >= 0`, so Final Verdict won at 0 Holy Power on 95 log lines.
  --
  -- THE REAL FIX IS BELOW THIS COMMENT AND BENEATH IT: the reader is now the GENERAL
  -- `env.powerCostFn`, asked about THIS SPEC'S resource (ns.Coach.CostPowerType, resolved
  -- from spec.powers), and `ns.PowerCost` is three-valued — nil means unreadable, 0 means
  -- explicitly free.  So the two zeros are finally different values and this guard can be
  -- what it always claimed to be.  ⚠ `nil` MUST fall through to the fallback; a spec whose
  -- cost cannot be read must under-promise, never cue a press that fails.
  local function costOf(spellID, fallback)
    if env and env.powerCostFn and spellID and ctx.costPowerType then
      local c = env.powerCostFn(spellID, ctx.costPowerType)
      if type(c) == "number" then return c end
    end
    return fallback
  end

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
  -- ⚠ AND ON THIS SPEC THAT IS NOT AN EDGE CASE.  FOUR of the nine Essential buttons —
  -- Judgment (category 1663), Crusader Strike (1627, 2 charges), Blade of Justice (2128) and
  -- Wake of Ashes (2285) — keep their cooldown on a CHARGE CATEGORY with RecoveryTime = 0
  -- (T1 DB2 @ 12.0.7), so `ns.BaseCooldown` reads 0 for them and this function is doing the
  -- work the cooldown read cannot.
  -- ⚠ THE COUNT WAS "SIX" HERE UNTIL 2026-08-03 AND IT WAS WRONG.  Avenging Wrath is not one
  -- (it carries CategoryRecoveryTime = 120000 on the SPELL row, so its base cooldown reads
  -- fine); Templar's Verdict and Divine Storm read 0 because they have NO cooldown at all,
  -- which is a different thing entirely; and the old list named Hammer of Wrath, which is not
  -- among the nine because it is not in the tracked set.  Getting a headline fact wrong in
  -- the direction of "worse than it is" is still getting it wrong.
  -- Whether a ONE-charge category is even marked `charges = true` on the CDM row is unknown
  -- offline; usable() is correct either way, because it consults the count only when there IS
  -- one.  @verify-ingame
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
  -- ⚠ A ONE-CHARGE POOL NEEDS BOTH SIGNALS — field-found 2026-08-03, and it is NOT a
  -- weakening of the Conflagrate rule below it.
  --
  -- For a pool of ONE, "you have a charge" and "it is off cooldown" ARE THE SAME FACT, so
  -- they cannot legitimately disagree.  For a pool of TWO they can, and routinely do: one
  -- charge banked while the second recharges is the normal state, which is exactly why the
  -- count has to outrank the cooldown there.
  --
  -- They DID disagree in the field, on 191 lines of one flight: `Judg=c10` (ten seconds of
  -- cooldown left) beside `Judg~1/1` (a charge available), and Judgment won on the count.
  -- The cause is the two-ladder hazard the state file documents: the COOLDOWN is read on the
  -- display identity, while CHARGES use `overrideSpellID or spellID` — rungs 4+5, because
  -- that is what Blizzard reads (ItemData.lua:283-288).  On a row whose identity flips —
  -- Judgment's does, it alternates with Hammer of Wrath in the tracked set — those two
  -- ladders resolve to DIFFERENT SPELLS, so we compared one ability's cooldown against
  -- another's charges.
  --
  -- Requiring both is the honest resolution: it needs no guess about which ladder was right,
  -- and it fails toward NOT promising a press.  Blade of Justice (no identity flip) reads
  -- consistently either way, so this costs nothing where the row is well-behaved.
  local function usable(base)
    local rec = base and factsByBase[base]
    if not rec then return false end
    local ch = abilities[base] and abilities[base].charge
    if ch and ch.charged then
      local cur = num(ch.cur)
      if cur ~= nil then
        if num(ch.max) == 1 then return cur >= 1 and (rec.probablyUp or false) end
        return cur >= 1
      end
    end
    return rec.probablyUp or chargeBanked(base)
  end
  ctx.wingsUsable     = usable(S.AVENGING_WRATH)
  ctx.executionUsable = usable(S.EXECUTION_SENTENCE)
  ctx.tollUsable      = usable(S.DIVINE_TOLL)
  ctx.woaUsable       = usable(S.WAKE_OF_ASHES)
  ctx.bojUsable       = usable(S.BLADE_OF_JUSTICE)
  ctx.judgmentUsable  = usable(S.JUDGMENT)
  ctx.fillerUsable    = usable(S.CRUSADER_STRIKE)

  -- ⚠ WHICH HAMMER OF WRATH ID?  Not a constant — whichever of the candidates the pulse
  -- actually carries, resolved most-specific first.  Three Paladin-side ids exist (24275 the
  -- class skill-line castable that owns the charge category, 326730 a second skill-line row,
  -- 1241288 the Midnight talent NODE, which `talents.md` marks PASSIVE — it grants the
  -- ability rather than being it).  This file used to ask for 24275 alone while `notes.md`
  -- claimed "whichever the client surfaces resolves the same cue" — a claim nothing
  -- implemented, so if the client had surfaced a different id the line could never fire.
  -- Same fix, same shape as CoachDestruction's `ctx.dotID`.
  -- Keyed by NAME, not by value: a `{ S.A, S.B }` literal would have a HOLE the moment any
  -- one id were nil, and ipairs stops at the first hole — silently dropping every candidate
  -- after it.
  local HOW_KEYS = { "HAMMER_OF_WRATH", "HOW_ALT", "HOW_TALENT" }
  for _, name in ipairs(HOW_KEYS) do
    local id = S[name]
    if id and factsByBase[id] then ctx.howKey = id; break end
  end
  ctx.howUsable = usable(ctx.howKey)

  -- ── The spender overrides (Templar + the Final Verdict talent) ─────────────
  -- WHICH tracked frame carries an armed Hammer of Light.  `holFrame` is a BASE spellID (the
  -- domain-view identity), never a cooldownID.  The shell relaxed Classify's `transformed`
  -- to the generic live ~= base, so the Retribution filter (`spends == "hp"`) is re-applied
  -- here and the overrides are told apart by the semantic **`spender`** field.
  -- ⚠ NEVER BRANCH ROTATION LOGIC ON `abbr`.  It is per-ID DISPLAY only, and the reason is
  -- recorded in SpecRetribution.lua: on Destruction a shared `abbr` made a capture unable to
  -- say which numeric override had surfaced, which was the exact question it was recording
  -- for.
  local holLive
  for base, rec in pairs(factsByBase) do
    if rec.transformed and rec.info and rec.info.spends == "hp" then
      if rec.info.spender == "hammer_of_light" then
        ctx.holFrame, holLive = base, rec.live
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
  -- ⚠ CRUSADE COUNTS AS WINGS.  Crusade (1253598) is the Avenging Wrath alternative, and
  -- `wingsUp` is the ONLY readable half of Hammer of Wrath's gate — so on a Crusade build,
  -- reading 31884 alone would leave that line permanently dark and the "wings" note wrong if
  -- it ever fired.  Whether the client surfaces Crusade as its own buff or as an override on
  -- 31884's row is unsettled; ORing both costs nothing and covers either.  @verify-ingame
  ctx.wingsUp         = buffActive(S.AVENGING_WRATH) or buffActive(S.CRUSADE)

  -- ── WHICH SPENDER — including Hammer of Light ──────────────────────────────
  -- ⚠ HAMMER OF LIGHT IS A SPENDER CHOICE, NOT A PRIORITY LINE, and getting that wrong is
  -- the correction of 2026-08-03.  It used to sit at L1, above Execution Sentence and
  -- Avenging Wrath, justified as "the top of simc's finisher block".  That is true and
  -- irrelevant: `actions.finishers` is only ever entered from `actions.generators`, and
  -- `actions.cooldowns` — which is where execution_sentence and avenging_wrath live — is
  -- called BEFORE generators (simc:21-22).  The KB agrees (AW 1, ES 2, HoL 3).  Since a
  -- hammer is armed for up to 20s after every Wake of Ashes, the old order deferred the
  -- burst buttons for a large fraction of every pull.
  --
  -- The faithful reading is simc's own: `hammer_of_light` is the FIRST entry in `finishers`,
  -- and the `divine_storm` / `templars_verdict` entries beneath it both carry
  -- `if=(!buff.hammer_of_light_ready.up|buff.hammer_of_light_free.up)` — i.e. *do not press
  -- an ordinary finisher while a hammer is ready*.  So "which finisher" resolves to Hammer
  -- of Light whenever it is armed, and the two spend LINES stay exactly where simc's two
  -- `call_action_list,name=finishers` entry points are.
  --
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
  ctx.spenderKey = (ctx.holArmed and ctx.holFrame)
    or (ctx.dsCastable and dsKey) or tvKey or dsKey

  -- The cost of THE SPENDER WE WILL ACTUALLY PRESS, not of Templar's Verdict always.  This
  -- read the base TV cost unconditionally until 2026-08-03, which threw away the one thing
  -- the zero-cost fix above buys: a free Hammer of Light or an Empyrean-Power Divine Storm
  -- reports its own cost, and only the LIVE id carries it.  Falls back to the base id where
  -- there is no transform, and to the declared 3 where the client refuses.
  ctx.spenderCost = costOf(holLive or ctx.spenderKey, self.SPENDER_COST_FALLBACK)

  -- ── The hero tree ──────────────────────────────────────────────────────────
  -- Read off the PULSE (State's talent-API read; TraitSubTree 48 = Templar, 50 = Herald of
  -- the Sun), and NEVER inferred from the tracked set.  That inference is field-fix B: on
  -- Destruction, deriving the tree from a tracked ability corrupted both answers at once on
  -- the first live session.
  -- ⚠ NO INFERENCE FALLBACK HERE, and that is deliberate rather than an omission.  On
  -- Destruction the fallback exists because the tree GATES rotation lines.  It does not
  -- here: the Hammer of Light SPENDER CHOICE resolves off a visible transform, which is a
  -- Templar fact that announces itself, and no line branches on the tree at all.  A guessed
  -- tree would therefore buy nothing and could only mislead the log.
  -- ⚠ `ctx.templar` is published and currently has NO reader.  That is honest rather than
  -- useless — it is the name for the build, the decision log wants it, and the first line
  -- that genuinely needs a tree branch must read this instead of re-inferring.
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
-- RankWinner — THE FLAT PRIORITY LIST (specs/retribution/rotation.md L1–L11).
--    Evaluated top to bottom; the FIRST line whose ability is usable is the one press.
--    Returns winnerKey, level, note.
--------------------------------------------------------------------------------
-- ⚠ THE ORDER WAS WRONG UNTIL 2026-08-03, IN TWO PLACES.  Both were found by reading the
-- generated APL's CALL STRUCTURE rather than its text order, and both are recorded here
-- because the mistake is easy to repeat:
--   * Hammer of Light sat at the TOP, above Execution Sentence and Avenging Wrath.  It is
--     the first entry of `actions.finishers` — but `finishers` is only ever entered from
--     `actions.generators`, and `actions.cooldowns` (which owns execution_sentence and
--     avenging_wrath) is called BEFORE generators.  "First in its sub-list" is not "first".
--     It is now a SPENDER CHOICE resolved in Context, not a line at all.
--   * Hammer of Wrath sat ABOVE Blade of Justice, which is simc's `talent.walk_into_light`
--     placement — while rotation.md's own Deviation 5 said we were taking the LOWER,
--     default-build placement.  The document was right and the code disagreed with it.
--
-- `excluded` (contract: Coach.lua's header) matters here for the same reason it does on
-- Destruction: the SPENDER sits on two lines (L3 the anti-overcap dump, L7 the main dump)
-- and Blade of Justice on two (L6 procced, L8 plain).  Each pair keys on one base spellID —
-- including the Hammer of Light case, which rides its base frame — so one exclusion drops
-- every occurrence.
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

  -- L1 — Execution Sentence on cooldown.  ⚠ simc pairs it with Wake of Ashes
  -- (`cooldown.wake_of_ashes.remains<gcd`) and that handshake is dropped: a cooldown-remains
  -- read of ANOTHER ability is secret in combat.
  -- ⚠ ABOVE AVENGING WRATH, following simc (`actions.cooldowns` lists execution_sentence at
  -- :33 and avenging_wrath at :34) rather than the KB, which puts wings first.  The KB file
  -- is confidence: medium and reads like an editorial "cooldowns block"; simc is Tier-1,
  -- machine-generated against this build, and gates ES explicitly to fire just before Wake
  -- of Ashes.  Deliberate choice, recorded in rotation.md -> Deviations.
  if ctx.executionUsable then
    k, lv, nt = pick(key(S.EXECUTION_SENTENCE), "ROTATION"); if k then return k, lv, nt end
  end

  -- L2 — Avenging Wrath on cooldown: the whole burst window, as a plain press.  Nothing is
  -- staged for it and nothing is held, so it never reads as a hold.  On a Radiant Glory
  -- build the button does not exist and this line simply finds nothing — a free degradation
  -- that needs no talent read.
  if ctx.wingsUsable then
    k, lv, nt = pick(key(S.AVENGING_WRATH), "ROTATION"); if k then return k, lv, nt end
  end

  -- L3 — SPEND AT CAP, unless Wake of Ashes is ready.  simc:
  -- `call_action_list,name=finishers,if=holy_power=5&cooldown.wake_of_ashes.remains`.
  -- ⚠ THE SECOND CLAUSE IS NOT A DETAIL.  At cap with WoA READY you press WoA anyway (L4),
  -- because WoA ARMS HAMMER OF LIGHT and the armed spender is worth more than the overcap.
  -- `cooldown.wake_of_ashes.remains` means "WoA is on cooldown", which is `not woaUsable` —
  -- one of the few cooldown-remains terms in this APL that survives as a boolean.
  -- ⚠ THE AFFORDABILITY TERM IS NOT REDUNDANT even though cap >= cost today.  simc applies
  -- an implicit resource check to every action, and the cost is read LIVE — so a talent that
  -- ever raised a spender above the cap would otherwise make this line cue a press that
  -- fails.  Every line in this file carries its ability's real gate; this one is no exception.
  -- WHICH spender (Hammer of Light / Divine Storm / Templar's Verdict) is Context's call.
  if projected >= (ctx.hpMax or 5) and projected >= ctx.spenderCost and not ctx.woaUsable then
    k, lv, nt = pick(ctx.spenderKey, "ROTATION", ctx.holArmed and "Hammer of Light" or "at cap")
    if k then return k, lv, nt end
  end

  -- L4 — Wake of Ashes on cooldown.  Arms Hammer of Light for 20s, which is the reason L3
  -- steps aside for it.
  if ctx.woaUsable then
    k, lv, nt = pick(key(S.WAKE_OF_ASHES), "ROTATION"); if k then return k, lv, nt end
  end

  -- L5 — Divine Toll on cooldown.
  if ctx.tollUsable then
    k, lv, nt = pick(key(S.DIVINE_TOLL), "ROTATION"); if k then return k, lv, nt end
  end

  -- L6 — Blade of Justice on an Art of War / Righteous Cause proc (a free instant).  Both
  -- are tracked buffs, so this is ordinary readable presence.
  if ctx.bojUsable and (ctx.artOfWar or ctx.righteousCause) then
    local note = ctx.artOfWar and "Art of War" or "Righteous Cause"
    k, lv, nt = pick(key(S.BLADE_OF_JUSTICE), "ROTATION", note); if k then return k, lv, nt end
  end

  -- L7 — SPEND.  simc's unconditional `call_action_list,name=finishers` in the middle of the
  -- generator list — the second and last of its two finisher entry points.
  if projected >= ctx.spenderCost then
    local note = ctx.holArmed and "Hammer of Light"
      or (ctx.dsCastable and "Divine Storm") or nil
    k, lv, nt = pick(ctx.spenderKey, "ROTATION", note); if k then return k, lv, nt end
  end

  -- L8 — Blade of Justice on cooldown, no proc needed.  ⚠ ABOVE Hammer of Wrath: simc's
  -- generator tail is `hammer_of_wrath,if=talent.walk_into_light` / `blade_of_justice` /
  -- `hammer_of_wrath` / `judgment`, and we cannot read the talent, so we take the LOWER of
  -- the two Hammer of Wrath placements — the one correct for the build that does not have
  -- Walk into Light.  (This file had it backwards until 2026-08-03, contradicting its own
  -- rotation.md Deviation 5.)
  if ctx.bojUsable then
    k, lv, nt = pick(key(S.BLADE_OF_JUSTICE), "ROTATION"); if k then return k, lv, nt end
  end

  -- L9 — Hammer of Wrath, WHILE WINGS ARE UP.  ⚠ Its real gate is
  -- `target.health.pct<20 | buff.avenging_wrath.up | talent.walk_into_light`, and we can read
  -- exactly one of those three (the buff — Avenging Wrath OR Crusade).  So outside wings, in
  -- genuine execute range, we simply MISS the press — a missed cue, never a wrong one
  -- (rotation.md Deviation 4).  `targetExecute` is structurally false today and is read
  -- anyway, so the day State grows a target channel this line is already correct.
  -- ⚠ DOUBLY DEGRADED: Hammer of Wrath is not in the tracked set at all, so this can only
  -- ever fire if the virtual-row walk picks it up.  `ctx.howKey` resolves whichever of the
  -- three candidate ids the pulse actually carries.  @verify-ingame
  if ctx.howUsable and (ctx.wingsUp or ctx.targetExecute) then
    local note = ctx.wingsUp and "wings" or "execute"
    k, lv, nt = pick(ctx.howKey, "ROTATION", note); if k then return k, lv, nt end
  end

  -- L10 — Judgment on cooldown.
  if ctx.judgmentUsable then
    k, lv, nt = pick(key(S.JUDGMENT), "ROTATION"); if k then return k, lv, nt end
  end

  -- L11 — the FILLER: the Crusader Strike frame, whatever override it is showing (Templar
  -- Strike / Templar Slash / Templar Sweep on Templar).  We press the FRAME and let the game
  -- decide which strike comes out, because the alternation is Blizzard's and not ours.
  -- 2 charges on a 6s recharge, which is why usable() reads the count first.
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
  --    ⚠ Note this deliberately does NOT respect L3's Wake-of-Ashes exception.  L3 declines
  --    to DUMP while WoA is ready; that is a priority choice.  Sitting at a genuinely full
  --    bar is still a readable mistake, and saying so is the whole job of LATE.
  if rec.base == ctx.spenderKey and ctx.hp
      and ctx.hp >= (ctx.hpMax or self.HP_CAP) then
    return "LATE"
  end

  return level
end
