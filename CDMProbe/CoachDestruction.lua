-- CoachDestruction.lua — the DESTRUCTION decision brain (spec 267).
--
-- WHAT THIS IS.  The three methods the generic Coach shell delegates to, hung on the spec
-- object SpecDestruction.lua registered, plus this spec's tunables:
--   spec:Context(state, env)          fold the pulse into whole-board facts
--   spec:RankWinner(ctx, excluded)    the flat priority list — first usable line wins
--   spec:Escalate(winnerKey, level, ctx)   ROTATION -> LATE, from READABLE overdue-ness only
-- The shell (Coach.lua) owns Classify / Emit / ResourceBars and never learns a spell id.
--
-- THE LIST IT IMPLEMENTS is specs/destruction/rotation.md (the spec of record, itself
-- distilled from the Tier-1 simc midnight APL via knowledge/classes/warlock/destruction/
-- rotation.md).  Line numbers L1–L13 below are that document's, so the two can be diffed
-- by eye.  Where a line's real gate is not readable, the degradation is stated at the line
-- rather than faked — the project's standing rule is that absence of a read never becomes
-- a positive claim.
--
-- HOW DESTRUCTION DIFFERS FROM DEMONOLOGY, structurally:
--   * NO burst SETUP block.  Demonology's whole L2 is a Tyrant-window staging walk (pool to
--     5, stage the demons, then Tyrant).  Destruction holds NOTHING for Summon Infernal —
--     there is no partner summon and nothing is staged — so Infernal is a plain on-cooldown
--     line and there is no `tct`, no `stage`, no go-gate, and no window suppression in
--     Escalate.  Building a Tyrant-style common-fate treatment here would be wrong.
--   * THE RESOURCE RAIL IS EXACT, AND THAT IS THIS SPEC'S DEFINING FACT (Phase 6.2).  Every
--     gate here is denominated in FRAGMENTS (0–50, the game's internal Soul Shard unit), read
--     off State's `unmodified` power channel.  Until Phase 6.2 the pipeline saw whole shards
--     only, so a true 1.9 arrived as `1`, `shards >= 2` was false, and the HUD said "build"
--     one Incinerate tick before a Chaos Bolt was affordable — a MISSING CAPABILITY, not a
--     rounding preference.  With the exact rail, SpecPowerDelta projects BUILDERS as well as
--     spenders, and simc's fractional gates (`<=4.2`, `<=4.6`) are expressible verbatim.
--   * CHARGES are real here.  Conflagrate is the project's first charged tracked ability, so
--     readiness is "probably up OR a charge banked" — see usable().  (Shadowburn is NOT one:
--     DB2 ChargeCategory = 0 @ 12.0.7.  An earlier draft of these files claimed it had 2.)
--
-- LOAD ORDER.  Loads right after SpecDestruction.lua (so ns.Specs[267] exists) and may sit
-- before Coach.lua: every ns.Coach.* reference here is runtime-only, never touched at load.
local ADDON, ns = ...

local spec = ns.Specs[267]   -- the Destruction object registered by SpecDestruction.lua

--------------------------------------------------------------------------------
-- Tunables (seconds / FRAGMENTS).  Fields on the spec object, so a sibling spec's values can
-- never leak in as file-locals.
--------------------------------------------------------------------------------
spec.LATE_LEAD = 4.0    -- a probably-up press left elapsed this long => overdue.  Read by
                        -- the shell's Classify off ns.ActiveSpec.LATE_LEAD.

-- How long a `PandemicTime` latch is believed before it decays to no claim.  NOT a tuning
-- preference — an upper bound derived from the game: Immolate/Wither runs 18s and the
-- refresh window is ~30% of that (~5.4s), so nothing can honestly still be "in pandemic"
-- past this.  6.0 leaves a second of slack for a late poll.  See ctx.dotRefreshable for
-- the capture that forced it (a latch still firing at 13.4s).
spec.DOT_PANDEMIC_TTL = 6.0

-- The resource gates of the priority list, named — ALL IN FRAGMENTS (10 per whole shard).
--
-- ⚠ THE FRACTIONS ARE RESTORED (Phase 6.2), and the rounding note that used to live here is
-- gone with them.  rotation.md used to round simc's `<= 4.2` and `<= 4.6` both to `<= 4`,
-- the conservative direction, because State could not read a fraction at all; it can now, so
-- the two gates are simc's own numbers expressed as the integers they always were.  They are
-- HARDCODED FROM SIMC WITH A CITATION rather than computed off the yields: `4.6 + 0.4`
-- (Incinerate with Diabolic Embers) is exactly 5.0, which makes them LOOK like derived
-- overcap guards, but `4.2 + 0.5` (Conflagrate) is 4.7, not 5.0 — the relationship is
-- suggestive and not exact, so deriving them would be inventing a rule simc does not state.
--
-- Line numbers are simc's `profiles/MID1/warlock_destruction.simc` @ ab7b0b8 (2026-08-01,
-- branch midnight, DBC build 12.0.7.68887).
spec.BUILD_CEILING_FRAGS  = 40   -- L2 Soul Fire      (simc: soul_shard<=4)
spec.CONF_CEILING_FRAGS   = 42   -- L4 Conflagrate    (simc:33 — soul_shard<=4.2, no Backdraft)
spec.INC_CEILING_FRAGS    = 46   -- L6 Incinerate     (simc:36 — soul_shard<=4.6, Chaotic Inferno)
spec.REFILL_FLOOR_FRAGS   = 30   -- L12: Infernal Bolt as the refill when at/below this
spec.AOE_DUMP_FLOOR_FRAGS = 40   -- L10: Rain of Fire needs at least this much banked
-- ⚠ L10 STAYS ON A WHOLE-SHARD FLOOR ON PURPOSE.  simc's Rain of Fire gate is
-- `soul_shard >= (3.5 - 0.1*active_dot.immolate)` — but that line is **Diabolist-AoE only**
-- (`active_enemies>=4`), it has a **Hellcaller sibling at 4.0** off `active_dot.wither`
-- (simc:63) and an **unconditional fallback with no shard condition at all** (simc:68), and
-- the `-0.1 x active_dot` term is unexplained anywhere in simc — it is an income-anticipation
-- term whose buffer SHRINKS as income RISES, which is backwards for a pooling reserve, and at
-- 8 Immolates it falls below the real 3-shard cost.  We also have no `active_dot` count to
-- feed it.  So the brain keeps a plain floor and the finding is recorded in
-- specs/destruction/rotation.md rather than half-implemented here.

-- Shard costs, IN WHOLE SHARDS — the unit ns.ShardCost speaks (the client pre-applies the
-- display divisor: Chaos Bolt is 20 fragments in DB2 and the API returns 2, measured
-- 2026-08-01).  ALWAYS resolved live through env.shardCostFn (talent-dependent); these are
-- only the fallback for a harness or an unreadable read.  Never hardcode a cost at a call
-- site — that is how a talent that changes a cost silently breaks a gate.
-- ⚠ Context multiplies these UP to fragments at ONE site and republishes them as
-- `ctx.*CostFrags`; the fallbacks go through the same conversion, so a shard number never
-- reaches a gate.
spec.CB_COST_FALLBACK  = 2   -- Chaos Bolt
spec.ROF_COST_FALLBACK = 3   -- Rain of Fire
spec.SB_COST_FALLBACK  = 1   -- Shadowburn

-- ⚠ `DOT_REFRESH_LEAD` was DELETED here (field-fix C).  It was a placeholder lead applied to
-- `abilities[base].uptime` — a field the pulse was expected to grow one day.  We now know
-- that day never comes: the DoT's remaining duration lives in `item.pandemicEndTime`, which
-- reads SECRET in combat, and `IsInPandemicTime` does not return a secret boolean, it
-- THROWS (measured 2026-07-30, knowledge/addon-dev/api-events-and-discovery.md §2.8).  There
-- is no number to compare a lead against.  What there IS is the `PandemicTime` ALERT, which
-- fires normally in combat — and Blizzard computes the window exactly (from how much
-- duration a recast would really carry over, not the community's 30% rule of thumb).  So the
-- refresh half of L8 is an EDGE LATCH, and a tunable lead would be a worse answer than the
-- one the client hands us.  See ctx.dotRefreshable below.

-- ⚠ THE ONE GENUINELY UNSETTLED READ.  rotation.md L3 is "if Art is armed: cast CB", and
-- specs/destruction/observability-map.md #4 proposes sourcing it from the Diabolic Ritual
-- aura (428514) "and/or the CB override edge".  Those are not equivalent:
--   * The OVERRIDE is unambiguous — a transformed Chaos Bolt frame IS the armed Art (and
--     is already L1's read, since the transform is Ruination).
--   * 428514 is the RITUAL CONTAINER, not the Art.  The KB's simc distillation gates the
--     line on `demonic_art` (a separate buff) or "ritual short"; docs/status.md separately
--     records that only the 428514 container is tracked and that a real Art tracker wants
--     the per-stage ritual auras.  If the container is up for most of the cycle — which is
--     what a ritual RAMP does — treating it as "Art armed" would jam Chaos Bolt above
--     Conflagrate and Summon Infernal permanently.
-- So the default is FALSE: only a visible transform arms the Art.  Flip this to true if
-- `/cdmp hud layout` + the decision log show 428514 present only while the Art is genuinely
-- armed.  A one-line, one-place reversal, deliberately not a guess baked into the cascade.
spec.ART_FROM_RITUAL = false

local function ids()
  return ns.SpecIDs or {}
end

-- Honest pulse-number reader: a non-number reads nil, never a guess.
local function num(v) return type(v) == "number" and v or nil end

-- Truncate TOWARD ZERO — used only to render an exact-unit projection back into the DISPLAY
-- units the pip bar speaks.  Never used in a gate (Phase 6.2: gates compare exact integers),
-- so this is the only place a division reaches, and toward-zero is the honest direction for
-- both signs: a partial shard gained is not yet a shard, spent is not yet spent.
local function truncToward(x)
  if x >= 0 then return math.floor(x) end
  return -math.floor(-x)
end

--------------------------------------------------------------------------------
-- HERO TREE — read by State, inferred here only as a fallback
--------------------------------------------------------------------------------
-- ⚠ WHAT WAS WRONG the first time.  This used to be a one-line structural inference:
-- "Wither REPLACES Immolate on Hellcaller, so a tracked Wither is the tell."  The field
-- falsified it on the first live session — a real Hellcaller build tracked Malevolence but
-- IMMOLATE, and the inference confidently returned Diabolist.  A single structural signal
-- cannot carry this: what the CDM tracks is a layout fact, the hero tree is a talent fact.
--
-- So we ASK the talent API — but the ASKING is State's job, not the brain's.  `pulse.hero`
-- carries the answer (State.lua's heroCache), which puts the hero tree ON THE PULSE: a
-- captured pulse can now reproduce a Hellcaller decision, instead of the brain reaching
-- into the live client from inside a 10 Hz Context.
--
-- The ladder, in order of trustworthiness:
--   1. `state.hero`             — State's talent-API read; authoritative when present
--   2. MULTI-signal inference   — the fallback for a refused/absent API read.  Strictly
--                                 better than the one signal that already failed: EITHER
--                                 Hellcaller tell counts, and the Diabolist tells are read
--                                 independently.  Battle-tested, so it stays.
--   3. Diabolist, and SAY SO    — the KB's v1 profile is the least-surprising default, but
--                                 a defaulted answer is announced, never silent.  The
--                                 announcement itself lives in HudDriver (the one-shot
--                                 notice pattern); this returns the reason for it.

-- The fallback.  Deliberately NOT cached: it reads the tracked set, which is empty on the
-- first pulses after a login/relayout — caching it there would freeze the wrong answer for
-- the session, which is the failure mode we are fixing.
local function heroFromSignals(facts, artArmed, ritualUp)
  local S = ids()
  local hellcaller = (facts[S.MALEVOLENCE] ~= nil) or (facts[S.WITHER] ~= nil)
  local diabolist  = artArmed or ritualUp
  if hellcaller and not diabolist then return "hellcaller", nil end
  if diabolist and not hellcaller then return "diabolist", nil end
  if hellcaller and diabolist then
    return "diabolist", "both trees' signals are present"
  end
  return "diabolist", "no hero-tree signal in the tracked set"
end

-- Returns (hero, how).  `how` is a human phrase describing the PROVENANCE, published on
-- ctx so the driver can announce a resolution the player would want to argue with.
local function resolveHero(stateHero, facts, artArmed, ritualUp)
  if stateHero ~= nil then return stateHero, "talent API" end
  local hero, why = heroFromSignals(facts, artArmed, ritualUp)
  return hero, why and ("defaulted — " .. why) or "inferred from the tracked set"
end

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
  -- State (an unreadable aura is absence there, never a false true).  Presence only — every
  -- Destruction proc that matters (Backdraft, Chaotic Inferno, Fiendish Cruelty) has a
  -- secret stack count, so there is nothing else to read.
  local function buffActive(spellID)
    return (state.buffs and state.buffs[spellID] == true) or false
  end

  -- The in-flight projection, derived HERE from the pulse's cast history (roster-state-plan
  -- Phase 6 — State emits raw `power` now and no longer folds `incoming` onto the bar).
  -- One map per Context, shared by the shard scalars below and the generic ctx.powers loop.
  local sums = ns.Coach.InflightPower(state, ns.SpecPowerDelta)

  -- ── THE SHARD RAIL, IN FRAGMENTS (Phase 6.2) ───────────────────────────────
  -- The whole point of this phase, and Destruction is the spec that needed it: every gate
  -- below is denominated in FRAGMENTS (0–50) read off State's `unmodified` channel, so
  -- "1.8 shards, +0.2 in flight, that is enough for a Chaos Bolt" is finally expressible.
  --
  -- ⚠ `ctx.shards` IS DELETED, NOT REPURPOSED.  Had it kept its name and changed unit, a
  -- surviving `shards >= 2` would compile and be silently wrong by 10x — the one failure
  -- mode this migration can produce.  A stale reader now gets nil and fails loudly.
  --
  -- The fallback when the exact read REFUSES is the display value scaled by the modifier:
  -- coarse (a true 1.9 still arrives as 10) but never wrong in units.
  local ss = (state.power or {}).SoulShards or {}
  local mod = num(ss.modifier) or self.FRAGS_PER_SHARD
  local frags = num(ss.unmodified)
  if frags == nil then
    local v = num(ss.value)
    frags = v and (v * mod) or nil
  end
  local fragsIncoming = sums.SoulShards or 0
  local fragsMax = num(ss.unmodifiedMax)
    or (num(ss.max) and num(ss.max) * mod)
    or self.FRAG_CAP
  local fragsProjected = frags and (frags + fragsIncoming) or nil

  local ctx = {
    facts = factsByBase,
    mode = state.mode,
    frags = frags, fragsIncoming = fragsIncoming, fragsMax = fragsMax,
    fragsProjected = fragsProjected,
    fragModifier = mod,
    atCap = fragsProjected and fragsProjected >= fragsMax or false,
    powerReadable = ss.readable ~= false and frags ~= nil,
  }

  -- ctx.powers — the generic power array the shell's ResourceBars emits from, driven off
  -- self.powers x state.power[name].  Destruction declares exactly SoulShards, so this is
  -- the same single discrete meter Demonology renders.
  --
  -- ⚠ THE ONE PLACE THAT STAYS IN DISPLAY UNITS: Renderer.lua pools one pip per unit of
  -- `max`, so a `max` of 50 would try to draw fifty pips.  The exact integers ride alongside.
  ctx.powers = {}
  for _, p in ipairs(self.powers or {}) do
    local pw = (state.power or {})[p.name] or {}
    -- The divisor between the units `sums` speaks (the spec's own, via SpecPowerDelta) and
    -- the DISPLAY units this bar renders in.  Live client read first; `p.modifier` is the
    -- spec's declared fallback for when it refuses (a power with no divisor omits it => 1).
    local pmod = num(pw.modifier) or num(p.modifier) or 1
    local exact = (p.incoming and sums[p.name]) or 0
    ctx.powers[#ctx.powers + 1] = {
      value     = num(pw.value),
      max       = num(pw.max) or self.BAR_MAX,
      -- `p.incoming` is the spec-declared "this bar shows a projection" flag.  Its READER
      -- moved here from State's deleted projectIncoming (Phase 6); the field on
      -- spec.powers is unchanged.  ⚠ `sums` is in EXACT units now, so the display half is
      -- scaled DOWN, truncated toward zero — a partial shard is not a shard.
      incoming  = truncToward(exact / pmod),
      display   = p.display or "discrete",
      powerType = p.token,
      -- The exact rail (Phase 6.2): integers in the game's internal units, absent when the
      -- client refused the read.  Dividing is the consumer's job — see Coach:ResourceBars.
      -- `valueExact`/`maxExact` are MEASUREMENTS — absent, never zero, when the client
      -- refused the exact read.  `incomingExact` is OUR arithmetic and is always known.
      valueExact    = num(pw.unmodified),
      maxExact      = num(pw.unmodifiedMax),
      incomingExact = exact,
      modifier      = pmod,
    }
  end

  -- Live shard costs, resolved once per pulse.  The shell owns the INJECTED reader
  -- (env.shardCostFn = cfg.shardCost); this brain owns WHICH spells cost and the fallbacks.
  --
  -- ⚠ THE UNIT BOUNDARY IS HERE AND NOWHERE ELSE.  Costs arrive in WHOLE SHARDS (the client
  -- pre-applies the divisor: Chaos Bolt's DB2 cost of 20 comes back as 2); the gates compare
  -- in FRAGMENTS.  So every cost is multiplied UP at this single site and republished under
  -- a `*Frags` name, and nothing below this line ever sees a shard again.  The fallbacks go
  -- through the same conversion, so there is exactly one crossing.
  local function costOf(spellID, fallback)
    if env and env.shardCostFn and spellID then
      local c = env.shardCostFn(spellID)
      if type(c) == "number" then return c end
    end
    return fallback
  end
  local function costFrags(spellID, fallback)
    return math.floor(costOf(spellID, fallback) * mod + 0.5)
  end
  ctx.cbCostFrags  = costFrags(S.CHAOS_BOLT,   self.CB_COST_FALLBACK)
  ctx.rofCostFrags = costFrags(S.RAIN_OF_FIRE, self.ROF_COST_FALLBACK)
  ctx.sbCostFrags  = costFrags(S.SHADOWBURN,   self.SB_COST_FALLBACK)

  -- ── Readiness, CHARGE-AWARE ────────────────────────────────────────────────
  -- An ability with a charge banked is usable even while its recharge timer runs, so a
  -- charged ability's readiness is NOT its cooldown state.  `ns.ReadCharges` is combat-gated
  -- (C_Spell.GetSpellCharges reads secret in restricted combat), so the EXACT count is an
  -- out-of-combat luxury.
  --
  -- FIELD-FIX C2 changes what happens in combat.  State now carries a napkin estimate —
  -- seeded exact OOC, decremented on each landed cast, incremented on the `ChargeGained`
  -- alert (which fires in combat, and covers cooldown-reset procs since it triggers on any
  -- upward move of Blizzard's cached count).  So we read `cur` whatever its source, and let
  -- the napkin's own honesty rule do the work: it is biased to UNDERCOUNT, so the worst it
  -- can do is hold a charge we actually have — never claim one we do not.  `readable` is
  -- still the trust annotation for anyone who wants only measurements; here a present number
  -- is enough, and an absent one (`{readable = false}`, no seed yet) is still not a press.
  local function chargeBanked(base)
    local row = base and abilities[base]
    local ch = row and row.charge
    if not ch then return false end
    local cur = num(ch.cur)
    return (cur ~= nil and cur >= 1) or false
  end
  -- ⚠ FOR A CHARGED ABILITY THE COUNT IS AUTHORITATIVE — the cooldown state is NOT, and
  -- trusting it is what made the HUD recommend Conflagrate at ZERO charges.  The mechanism,
  -- measured: the CDM raises `Available` every time a CHARGE is restored but never raises
  -- `OnCooldown` at all for a charged ability, so State's ready-edge latches true on the
  -- first charge and is never cleared — `cd` then reads `ready` forever.  The napkin cannot
  -- rescue it either: Conflagrate's `RecoveryTime` is 0 in DB2 (the recharge lives on its
  -- ChargeCategory), so the base-cooldown countdown is 0 and the just-cast guard never fires.
  --
  -- Hence: if we have a count for a charge pool, it DECIDES. Only when there is no count at
  -- all do we fall back to the cooldown read.  This also keeps the napkin's honesty rule
  -- doing its job — an undercount holds a charge we have (safe), and can no longer be
  -- overridden by a stale `ready`.
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
  ctx.soulFireUsable    = usable(S.SOUL_FIRE)
  ctx.conflagrateUsable = usable(S.CONFLAGRATE)
  ctx.shadowburnUsable  = usable(S.SHADOWBURN)
  ctx.infernalCastable  = usable(S.SUMMON_INFERNAL)
  ctx.malevolenceUsable = usable(S.MALEVOLENCE)
  ctx.cataclysmUsable   = usable(S.CATACLYSM)

  -- ── The Demonic Art transforms (Diabolist) ─────────────────────────────────
  -- Which ABILITY frame carries an armed Art, and which Art it is.  `artFrame`/`ibFrame`
  -- are BASE spellIDs (the domain-view identity), never cooldownIDs.  The shell relaxed
  -- Classify's `transformed` to the generic live ~= base, so the Demonic-Art filter
  -- (`spends == "art"`) is re-applied here, and the two Arts are told apart by **`art`**
  -- rather than by a fabricated shard yield (SpecDestruction explains why).
  -- ⚠ This read `abbr` until 2026-07-30.  That pinned every alias ID of one Art to a single
  -- log code, so the decision log could not say WHICH numeric override surfaced — the exact
  -- question it was recording for.  `art` is the semantic field; `abbr` is now per-ID and is
  -- for display only.  Never branch rotation logic on `abbr` again.
  for base, rec in pairs(factsByBase) do
    if rec.transformed and rec.info and rec.info.spends == "art" then
      if rec.info.art == "infernal" then
        ctx.ibFrame = base           -- Infernal Bolt rides the Incinerate frame
      elseif rec.info.art == "ruination" then
        ctx.ruinationFrame = base    -- Ruination rides the Chaos Bolt frame
      end
    end
  end
  -- "An Art that Chaos Bolt should spend."  A visible Ruination is that Art (and L1 takes
  -- it first); the ritual container only counts when ART_FROM_RITUAL says so — see the
  -- tunable's note.  A visible Infernal Bolt is explicitly NOT it: that Art belongs to
  -- Incinerate (L12), so pressing Chaos Bolt would waste it.
  ctx.ritualUp = buffActive(S.DIABOLIC_RITUAL)
  ctx.artArmed = (ctx.ruinationFrame ~= nil)
    or (self.ART_FROM_RITUAL and ctx.ritualUp and ctx.ibFrame == nil)
    or false

  -- ── Proc presence (never a count) ──────────────────────────────────────────
  -- Backdraft gates L4.  simc wants "not stacked to 2"; the stack count is secret (the same
  -- wall as Demonology's Demonic Core), so we read PRESENCE, which is STRICTER — it holds
  -- Conflagrate at 1 stack where simc would press.  Deliberate: the alternative is
  -- overwriting a 2-stack buff on a guess.
  ctx.backdraft       = buffActive(S.BACKDRAFT)
  ctx.chaoticInferno  = buffActive(S.CHAOTIC_INFERNO)
  ctx.fiendishCruelty = buffActive(S.FIENDISH_CRUELTY)

  -- ── The hero tree, and the maintenance DoT it selects ──────────────────────
  -- These are now resolved INDEPENDENTLY, which is the field-fix.  The old code derived the
  -- tree FROM the DoT ("a tracked Wither means Hellcaller"), so one wrong reading of the
  -- tracked set corrupted both answers at once — and it did, in the field.
  ctx.hero, ctx.heroHow = resolveHero(state.hero, factsByBase, ctx.artArmed, ctx.ritualUp)
  -- ⚠ `ctx.hellcaller` currently has NO consumer in RankWinner, and that is not an
  -- oversight: L5b Malevolence fires because Malevolence is in `facts` at all, and L8's DoT
  -- id resolves from whichever candidate the pulse carries.  Both are TRACKED-SET facts, so
  -- the cascade needs no tree branch — which is exactly the independence the field-fix
  -- bought (the old code derived the tree FROM the DoT, so one wrong read corrupted both).
  -- Published anyway: it is the honest name for the build, the decision log wants it, and
  -- the first line that genuinely needs a tree branch should read this and not re-infer.
  ctx.hellcaller = (ctx.hero == "hellcaller")
  -- Published on the spec object for the DRIVER to announce.  Context runs at 10 Hz and is
  -- PURE by contract, so it must not print; HudDriver owns the one-shot-notice pattern and
  -- latches on this string changing.  A defaulted hero tree silently deciding the rotation
  -- is exactly what went wrong in the field — the chat line is what makes it arguable.
  self.heroResolution = ctx.hero .. "|" .. ctx.heroHow

  -- ⚠ WHICH ID IS THE DoT?  Not a constant — whichever of the candidates the pulse actually
  -- carries.  Immolate occupies TWO cooldownIDs with DIFFERENT spellIDs (the DoT aura 157736
  -- on the Buff-bar viewer, and the CAST id 348 on Essential), and only the CAST row is
  -- pressable, so it is the only one that reaches `abilities` at all.  This file used to key
  -- L8 on 157736 alone, which means the line could NEVER fire on a live build.  Resolve
  -- through the candidate list, most-specific first.
  -- Keyed by NAME, not by value: `{ S.WITHER, S.IMMOLATE, ... }` would be a table with a
  -- HOLE the moment any one id were nil, and ipairs stops at the first hole — so a single
  -- missing constant would silently drop every candidate after it.
  local DOT_KEYS = { "WITHER", "IMMOLATE", "IMMOLATE_CAST" }
  local dotID
  for _, name in ipairs(DOT_KEYS) do
    local id = S[name]
    if id and factsByBase[id] then dotID = id; break end
  end
  ctx.dotID = dotID

  -- Three-way, on purpose: "up" / "missing" / "unknown".  Absence of a read must NEVER
  -- become "the DoT is missing" — that would spam the refresh press every GCD on a spec
  -- whose DoT is its spine.  So L8 fires only on positive evidence of absence.
  --
  -- THREE CHANNELS, in trust order (reordered 2026-07-31, roster-state-plan §3.10):
  --   1. THE PER-FRAME AURA VERDICT — `state.auraFrames[id]`, State's read of the item
  --      frame's `auraDataUnit` / `PandemicIcon`.  Blizzard recomputes both EVERY FRAME off
  --      secrets we cannot read, so unlike an edge they SELF-CLEAR.  `unit ~= nil` is the
  --      aura being up, `unit == nil` on a capable+readable row is positive evidence it is
  --      DOWN — the "apply it" answer nothing else can reach.  Highest trust, and only
  --      consulted when `capable`: the fields are widget internals with no deprecation
  --      path, so a silently-absent one must not read as "no DoT".
  --   2. THE ALERT LATCH (field-fix C) — `absent` / `fresh` / `pandemic`, observed off the
  --      CDM's own choke point.  DEMOTED to a fast path: it is a one-shot NOTIFICATION, not
  --      a state, and a re-application of a live aura raises nothing at all, so it goes
  --      silent for as long as the DoT is maintained (measured: 41 Immolate casts produced
  --      one OnAuraApplied, one PandemicTime and zero OnAuraRemoved).  Still the quickest
  --      signal when it does fire, and still the whole answer on a row that is not capable.
  --      Read across every candidate id, since either Immolate row can raise the alert; the
  --      NEWEST wins, and State has already resolved cooldownIDs to base spellIDs.
  --   3. the aura / buff-item presence read — the OOC fallback.  ⚠ `dotRow.buff` no longer
  --      exists for a tab-1 row (§3.1): `IsActive()` there is `self.cooldownID ~= nil`, a
  --      constant `true`, which is what jammed this whole read to "up" on both hero trees.
  --      The `b` branch below survives only for a DoT tracked on a tab-2 row.
  --   4. otherwise "unknown" — an unreadable DoT stays silent, never becomes "apply it now".
  local frames = state.auraFrames or {}
  local frame
  for _, name in ipairs(DOT_KEYS) do
    local id = S[name]
    local f = id and frames[id]
    -- First CAPABLE candidate with an opinion wins; a capable-but-refused read is still an
    -- answer ("we asked and could not tell"), so it stops the walk rather than falling
    -- through to a different id's stale reading.
    if type(f) == "table" and f.capable then frame = f; break end
  end

  local edges = state.dotEdges or {}
  local edge
  for _, name in ipairs(DOT_KEYS) do
    local id = S[name]
    local e = id and edges[id]
    if e and (not edge or (num(e.at) or 0) >= (num(edge.at) or 0)) then edge = e end
  end

  local dotRow = dotID and abilities[dotID]
  local dotState = "unknown"
  if frame and frame.unitReadable then
    dotState = (frame.unit ~= nil) and "up" or "missing"
  elseif edge then
    if edge.state == "absent" then dotState = "missing"
    else dotState = "up" end                       -- "fresh" and "pandemic" both mean up
  elseif buffActive(dotID) then
    dotState = "up"
  elseif dotRow then
    local a, b = dotRow.aura, dotRow.buff
    if (a and a.active == true) or (b and b.isActive == true) then
      dotState = "up"
    elseif (a and a.readable == true and a.active == false)
        or (b and b.isActiveReadable == true and b.isActive == false) then
      dotState = "missing"
    end
  end
  ctx.dotState = dotState
  -- WHICH CHANNEL DECIDED — carried so the decision log can render it.  A trace that shows
  -- `Imm=up` without saying whether a self-clearing frame read or a 40-second-old latch
  -- produced it cannot explain the decision, which is exactly the hole the field capture
  -- fell into.
  ctx.dotFrom = (frame and frame.unitReadable and "frame")
    or (edge and "edge")
    or ((dotState ~= "unknown") and "aura")
    or nil

  -- The REFRESH half of L8, on the same three-channel trust order.
  --
  -- ⚠ CHANNEL 1 IS `PandemicIcon`, AND IT DOES NOT NEED A TTL.  `IsInPandemicTime` compares
  -- two Secret Values, so calling it throws — but Blizzard evaluates it from the item's
  -- OnUpdate every frame anyway and Show/HidePandemicStateFrame set and nil the icon frame
  -- (CooldownViewer.lua:98, :562-585).  So it is a POLL of a live predicate: it arms on
  -- entering the window and clears itself on the refresh, which is the whole thing the
  -- latch below cannot do.  No age, no decay, no TTL — it is either true now or it is not.
  --
  -- Channel 2, the alert edge, stays underneath it for a row that is not `capable`.
  --
  -- Edge-driven: Blizzard raises `PandemicTime` when the DoT
  -- genuinely enters its refresh window, computed per spell from the duration a recast
  -- would carry over — a better number than any lead we could tune, and the only one
  -- available at all, since the window's endpoints are Secret Values in combat.
  --
  -- ⚠ BUT THE LATCH EXPIRES, and that is a fix, not a nicety (field capture 2026-07-30).
  -- The latch is only ever superseded by a later `fresh`/`absent` edge — so if that clear
  -- never arrives, a one-shot "you are in the refresh window" pins the cue on FOREVER.  It
  -- does happen: on Hellcaller the capture shows `Imm=pandemic` still driving a Wither cue
  -- **13.4 seconds** after it fired, with the DoT visibly near full duration.  Immolate is an
  -- 18s DoT (Blizzard spell data), so its refresh window is ~5.4s — a 13.4s-old pandemic
  -- claim is not merely suspect, it is arithmetically impossible.
  --
  -- So an aged-out pandemic edge decays to NO CLAIM, which is the project's standing rule
  -- applied to this channel: absence of evidence is never evidence of absence, and an
  -- expired estimate says "unknown", never "act now".  The failure direction is safe in
  -- both halves — we stop nagging about a DoT that is probably fine, and if it really does
  -- fall off, `OnAuraRemoved` fires `absent` and L8 re-fires as "apply it", untouched.
  --
  -- ⚠ NOTE FOR THE NEXT READER: `dotEdges` never carries a `Wth` key at all — on Hellcaller
  -- the alert arrives on IMMOLATE's two cooldownIDs, because the CDM row is still Immolate's
  -- even though the spell is replaced.  The edge scan above walks all three candidate ids for
  -- exactly that reason.  Whether a Wither RECAST raises `OnAuraApplied` on those rows is the
  -- open question behind the missed clear — `/cdmp alerts on` is the instrument for it.
  -- ⚠ THE TTL SURVIVES HERE AND ONLY HERE.  It is a fence around the LATCH's inability to
  -- clear itself; the frame poll needs no such thing, so it is deliberately not applied to
  -- `frame.pandemic`.
  ctx.dotEdge = edge and edge.state or nil
  if ctx.dotEdge == "pandemic" then
    local age = (num(state.at) or 0) - (num(edge.at) or 0)
    if age > self.DOT_PANDEMIC_TTL then ctx.dotEdge = nil end
  end

  local framePandemic
  if frame and frame.capable then framePandemic = frame.pandemic and true or false end
  ctx.dotPandemic = framePandemic          -- the frame's own answer, nil when it has none
  ctx.dotRefreshable = (dotState == "missing")
    or (framePandemic == true)
    -- The latch only gets a say where the frame has none: a `capable` row that says
    -- `pandemic = false` is a live reading of the window, and must not be overridden by a
    -- one-shot notification that fired at some point and never retracted.
    or (framePandemic == nil and ctx.dotEdge == "pandemic")
    or false

  -- ── The execute gate (L7's second half) ────────────────────────────────────
  -- Target health at or below 20%.  This is NOT a Secret Value — it is ordinary unit data
  -- that is simply absent from the pulse, because State has no target channel at all.  The
  -- read below is written against the shape a target channel would take, so it is nil-safe
  -- today (=> false, the execute half never fires) and correct the day one is added.
  -- Adding that channel is a design decision with a real cost (a new observed thing, every
  -- pulse), not a capability limit — see specs/destruction/observability-map.md #13.
  local tgt = state.target
  local hp = tgt and num(tgt.healthPct)
  ctx.targetExecute = (hp ~= nil and hp <= 20) or false

  return ctx
end

--------------------------------------------------------------------------------
-- RankWinner — THE FLAT PRIORITY LIST (specs/destruction/rotation.md L1–L13).
--    Evaluated top to bottom; the FIRST line whose ability is usable is the one press.
--    Returns winnerKey, level, note.
--------------------------------------------------------------------------------
-- `excluded` (contract: Coach.lua's header) matters more here than on Demonology, because
-- two abilities each sit on several lines: Chaos Bolt at L1 (as Ruination), L3 and L11;
-- Incinerate at L6, L12 (as Infernal Bolt) and L13.  All of them key on the same base
-- spellID — including the transform lines, which ride their base frame — so one exclusion
-- drops every occurrence.
function spec:RankWinner(ctx, excluded)
  local S = ids()
  -- FRAGMENTS throughout (Phase 6.2): `projected` is the exact 0-50 rail plus the signed
  -- in-flight delta, and every gate constant below is a fragment count (20 = 2 shards).
  local projected = ctx.fragsProjected or ctx.frags or 0   -- value + signed incoming

  -- The Coach decides in BASE spellIDs, so key() is IDENTITY — it only gates on the ability
  -- being TRACKED (present in ctx.facts).  An untracked line yields nil and evaluation
  -- continues; that is exactly how Destruction degrades if Incinerate is not in the live
  -- CDM set (the floor simply is not there, and L11's Chaos Bolt becomes the practical
  -- bottom).  The Binder resolves the winning spellID to its display cooldownID.
  local function key(base) return (base and ctx.facts[base]) and base or nil end

  -- pick — the line's candidate, or nil to keep evaluating.
  local function pick(k, level, note)
    if k and k ~= excluded then return k, level, note end
    return nil
  end
  local k, lv, nt

  -- L1 — Ruination: the free granted press that REPLACES Chaos Bolt on the button.  Moved
  -- to the top from simc's #8 (rotation.md Deviation 1): sitting on a free replacement cast
  -- blocks nothing and gains nothing.  @verify-ingame that it is genuinely free here; if it
  -- costs shards it belongs back down beside L8.
  if ctx.ruinationFrame then
    k, lv, nt = pick(ctx.ruinationFrame, "ROTATION", "Ruination — free empowered Chaos Bolt")
    if k then return k, lv, nt end
  end

  -- L2 — Soul Fire while it fits without overcapping (simc: soul_shard<=4 => 40 fragments).
  if ctx.soulFireUsable and projected <= self.BUILD_CEILING_FRAGS then
    k, lv, nt = pick(key(S.SOUL_FIRE), "ROTATION"); if k then return k, lv, nt end
  end

  -- L3 — spend an armed Demonic Art with Chaos Bolt.  See ART_FROM_RITUAL: today this only
  -- fires on a visible Ruination transform, which L1 already claimed, so in practice the
  -- line is reached only when the transform is seen but Ruination itself was excluded (the
  -- second-place recompute).  Affordability still gates it: a plain Chaos Bolt costs shards
  -- even when the Art is up, and we cannot tell a free one from a paid one.
  if ctx.artArmed and projected >= ctx.cbCostFrags then
    k, lv, nt = pick(key(S.CHAOS_BOLT), "ROTATION", "spend the Demonic Art"); if k then return k, lv, nt end
  end

  -- L4 — Conflagrate to build, while it fits and no Backdraft is being wasted.  The gate is
  -- PRESENCE, not "< 2 stacks" (the count is secret), so this holds at 1 stack where simc
  -- would press — the conservative direction.  ⚠ THE CEILING IS SIMC'S OWN 4.2 AGAIN
  -- (42 fragments, warlock_destruction.simc:33), restored by the exact read; it was rounded
  -- down to a flat 4 for as long as the pipeline could only see whole shards.
  if ctx.conflagrateUsable and projected <= self.CONF_CEILING_FRAGS and not ctx.backdraft then
    k, lv, nt = pick(key(S.CONFLAGRATE), "ROTATION"); if k then return k, lv, nt end
  end

  -- L5 — Summon Infernal: the whole burst window, as a plain on-cooldown press.  Nothing is
  -- staged for it and nothing is held, so it never reads as a hold.  The one real rule we
  -- cannot express — "pool and delay it if adds are about to spawn" — is fight knowledge,
  -- not state (specs/destruction/notes.md).
  if ctx.infernalCastable then
    k, lv, nt = pick(key(S.SUMMON_INFERNAL), "ROTATION"); if k then return k, lv, nt end
  end
  -- L5b (Hellcaller) — Malevolence is a SECOND, INDEPENDENT on-cooldown line, not a partner
  -- to sync with: at ~60s against the Infernal's 120s/90s the two deliberately do not align.
  if ctx.malevolenceUsable then
    k, lv, nt = pick(key(S.MALEVOLENCE), "ROTATION"); if k then return k, lv, nt end
  end

  -- L6 — Incinerate empowered by Chaotic Inferno, while it fits.  ⚠ Simc's 4.6 verbatim
  -- (46 fragments, warlock_destruction.simc:36) — the second gate the exact read restored.
  if ctx.chaoticInferno and projected <= self.INC_CEILING_FRAGS then
    k, lv, nt = pick(key(S.INCINERATE), "ROTATION", "Chaotic Inferno"); if k then return k, lv, nt end
  end

  -- L7 — Shadowburn on Fiendish Cruelty or in execute range.  The execute half never fires
  -- today (no target channel — ctx.targetExecute is structurally false), so in practice this
  -- is the Fiendish Cruelty line.
  if ctx.shadowburnUsable and (ctx.fiendishCruelty or ctx.targetExecute)
      and projected >= ctx.sbCostFrags then
    local note = ctx.fiendishCruelty and "Fiendish Cruelty" or "execute"
    k, lv, nt = pick(key(S.SHADOWBURN), "ROTATION", note); if k then return k, lv, nt end
  end

  -- L8 — the maintenance DoT (Immolate, or Wither on Hellcaller): the spec's SPINE.  Fires
  -- only on positive evidence — the DoT reads genuinely absent, or (once State carries a
  -- duration) it is inside the pandemic window.  An unreadable DoT keeps this line silent
  -- rather than spamming a refresh; see ctx.dotState.
  if ctx.dotRefreshable then
    local note = (ctx.dotState == "missing") and "not up" or "pandemic refresh"
    k, lv, nt = pick(key(ctx.dotID), "ROTATION", note); if k then return k, lv, nt end
  end

  -- L9 — Cataclysm on cooldown (talent; untalented it is simply never tracked).
  if ctx.cataclysmUsable then
    k, lv, nt = pick(key(S.CATACLYSM), "ROTATION"); if k then return k, lv, nt end
  end

  -- L10 — Rain of Fire, gated on the MANUAL AoE toggle.  Its real gate is a target count
  -- (~8+ on Diabolist, 5+ on Hellcaller) and we have no target roster, so `mode` stands in:
  -- a player DECLARATION, never wrong, only stale.  It sits below the Art/anti-cap Chaos
  -- Bolts on Diabolist and above the L11 dump for both trees — which is also where the
  -- Hellcaller delta wants it, so no tree branch is needed, only the shard floor.
  if ctx.mode == "aoe" and projected >= self.AOE_DUMP_FLOOR_FRAGS
      and projected >= ctx.rofCostFrags then
    k, lv, nt = pick(key(S.RAIN_OF_FIRE), "ROTATION"); if k then return k, lv, nt end
  end

  -- L11 — Chaos Bolt: the main shard dump and the payoff spender.
  if projected >= ctx.cbCostFrags then
    k, lv, nt = pick(key(S.CHAOS_BOLT), "ROTATION"); if k then return k, lv, nt end
  end

  -- L12 — Infernal Bolt as the shard refill when low.  Rides the Incinerate frame, so it is
  -- BLIND if Incinerate is not tracked — the worse twin of Demonology's Shadow Bolt hole,
  -- because this is the floor button.  @verify-ingame.
  if projected <= self.REFILL_FLOOR_FRAGS and ctx.ibFrame then
    k, lv, nt = pick(ctx.ibFrame, "ROTATION", "Infernal Bolt — shard refill"); if k then return k, lv, nt end
  end

  -- L13 — Incinerate: the floor.  If Incinerate is untracked there is no floor and the list
  -- can return nil (no press) at low shards — honest, and visible in the decision log as
  -- `w:-`, which is exactly the signal that the tracked set needs the curated layout.
  k, lv, nt = pick(key(S.INCINERATE), "ROTATION"); if k then return k, lv, nt end
  return nil
end

--------------------------------------------------------------------------------
-- Escalate — Destruction's readable overdue-ness.
--------------------------------------------------------------------------------
-- Two readable ways to be late on Destruction, and no window suppression: unlike
-- Demonology (where a ready summon inside the Tyrant window is a STAGED press, not a
-- forgotten one), Destruction holds nothing, so a ready burst button sitting idle is always
-- genuinely late.
function spec:Escalate(winnerKey, level, ctx)
  if not winnerKey or level ~= "ROTATION" then return level end
  local S = ids()
  local rec = ctx.facts[winnerKey]
  if not rec then return level end

  -- 1. A burst cooldown left sitting past the lead.  `overdue` is computed by the shell off
  --    cd.changedAt, i.e. from how long it has READ ready — not from a napkin guess.
  if (rec.base == S.SUMMON_INFERNAL or rec.base == S.MALEVOLENCE) and rec.overdue then
    return "LATE"
  end

  -- 2. Chaos Bolt parked at a FULL bar — the readable overcap dump (Demonology's
  --    HoG-at-cap rule, on Destruction's payoff spender).  Gated on ACTUAL fragments, not the
  --    projection: an in-flight spender has already committed to draining the bar, so
  --    projecting it would call you late for something you are mid-way through fixing.
  --    No burst carve-out, because Destruction never pools for a window on purpose.
  -- ⚠ A FULL BAR IS `>= fragsMax`, i.e. 50 — NOT 5.  This is one of the two LATE-at-full-bar
  -- rules the Phase-6.2 migration singled out: it reads like a whole-shard comparison and is
  -- not one.
  if rec.base == S.CHAOS_BOLT and ctx.frags
      and ctx.frags >= (ctx.fragsMax or self.FRAG_CAP) then
    return "LATE"
  end

  return level
end
