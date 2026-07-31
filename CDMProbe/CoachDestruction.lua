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
--   * NO builder projection.  Destruction generates in FRAGMENTS into a bar we read in
--     whole shards, so SpecPowerDelta projects spenders only (see that file); the shard
--     gates are rounded conservatively to compensate (rotation.md -> Fragments).
--   * CHARGES are real here.  Conflagrate is the project's first charged tracked ability, so
--     readiness is "probably up OR a charge banked" — see usable().  (Shadowburn is NOT one:
--     DB2 ChargeCategory = 0 @ 12.0.7.  An earlier draft of these files claimed it had 2.)
--
-- LOAD ORDER.  Loads right after SpecDestruction.lua (so ns.Specs[267] exists) and may sit
-- before Coach.lua: every ns.Coach.* reference here is runtime-only, never touched at load.
local ADDON, ns = ...

local spec = ns.Specs[267]   -- the Destruction object registered by SpecDestruction.lua

--------------------------------------------------------------------------------
-- Tunables (seconds / shards).  Fields on the spec object, so a sibling spec's values can
-- never leak in as file-locals.
--------------------------------------------------------------------------------
spec.LATE_LEAD = 4.0    -- a probably-up press left elapsed this long => overdue.  Read by
                        -- the shell's Classify off ns.ActiveSpec.LATE_LEAD.

-- The shard gates of the priority list, named.  rotation.md rounds simc's fractional
-- thresholds to whole shards ON PURPOSE (`<= 4.2` and `<= 4.6` both become `<= 4`), which
-- is the CONSERVATIVE direction: it builds one press later than simc would rather than
-- risk overcapping on a value we cannot see.  Restoring simc's fractions is gated on the
-- fragment read (specs/destruction/observability-map.md -> "the fragment read").
spec.BUILD_CEILING   = 4   -- L2 / L4 / L6: build only while this would not overcap
spec.REFILL_FLOOR    = 3   -- L12: Infernal Bolt as the refill when at/below this
spec.AOE_DUMP_FLOOR  = 4   -- L10: Rain of Fire needs at least this many banked

-- Shard costs.  ALWAYS resolved live through env.shardCostFn (talent-dependent); these are
-- only the fallback for a harness or an unreadable read.  Never hardcode a cost at a call
-- site — that is how a talent that changes a cost silently breaks a gate.
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

--------------------------------------------------------------------------------
-- HERO TREE — asked, not inferred (field-fix B)
--------------------------------------------------------------------------------
-- ⚠ WHAT WAS WRONG.  This used to be a one-line structural inference: "Wither REPLACES
-- Immolate on Hellcaller, so a tracked Wither is the tell."  The field falsified it on the
-- first live session — a real Hellcaller build tracked Malevolence but IMMOLATE, and the
-- inference confidently returned Diabolist.  A single structural signal cannot carry this:
-- what the CDM tracks is a layout fact, and the hero tree is a talent fact.
--
-- So ASK.  `C_ClassTalents.GetActiveHeroTalentSpec()` returns the active SubTreeID
-- (Blizzard_APIDocumentationGenerated/ClassTalentsDocumentation.lua:82), and TraitSubTree @
-- 12.0.7 pins the two Warlock-Destruction values below.  Verified present in this build.
--
-- The ladder, in order of trustworthiness:
--   1. the API                       — authoritative; cached, since it is respec-scoped
--   2. MULTI-signal inference        — strictly better than the one signal that already
--                                      failed: EITHER Hellcaller tell counts, and the
--                                      Diabolist tells are read independently
--   3. Diabolist, and SAY SO         — the KB's v1 profile is the least-surprising default,
--                                      but a defaulted answer is announced, never silent
local HERO_BY_SUBTREE = { [58] = "hellcaller", [59] = "diabolist" }   -- TraitSubTree @ 12.0.7

local heroCached = nil    -- the API's answer only.  Respec-scoped; cleared by spec:Invalidate
local heroSaid   = nil    -- the last resolution announced, so the chat line fires once

-- pcall + IsSecret guarded per project doctrine: an API that is missing, restricted, or
-- throws must degrade to the inference, never take the pipeline down with it.
local function heroFromAPI()
  if heroCached ~= nil then return heroCached end
  if not (C_ClassTalents and C_ClassTalents.GetActiveHeroTalentSpec) then return nil end
  local ok, subTreeID = pcall(C_ClassTalents.GetActiveHeroTalentSpec)
  if not ok or ns.IsSecret(subTreeID) or type(subTreeID) ~= "number" then return nil end
  -- An UNKNOWN subtree is not an answer: fall through to the inference rather than caching
  -- a nil we would then have to distinguish from "not asked yet".
  heroCached = HERO_BY_SUBTREE[subTreeID]
  return heroCached
end

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

local function resolveHero(facts, artArmed, ritualUp)
  local hero = heroFromAPI()
  local how = "talent API"
  if not hero then
    local why
    hero, why = heroFromSignals(facts, artArmed, ritualUp)
    how = why and ("defaulted — " .. why) or "inferred from the tracked set"
  end
  -- ANNOUNCED, once per change.  A defaulted hero tree silently deciding the rotation is
  -- exactly what went wrong in the field; the chat line is what makes it arguable.
  local said = hero .. "|" .. how
  if said ~= heroSaid then
    heroSaid = said
    ns.Printf("Destruction: hero tree = |cffffffff%s|r (%s)", hero, how)
  end
  return hero
end

-- Cache invalidation.  The resolver calls this on any event that could have changed the
-- build (see SpecRegistry): a respec changes the hero tree without changing the SPEC, so
-- PLAYER_SPECIALIZATION_CHANGED alone is not enough — TRAIT_CONFIG_UPDATED is the one that
-- actually fires for a hero swap.
function spec:Invalidate()
  -- ⚠ `heroSaid` is deliberately NOT cleared.  TRAIT_CONFIG_UPDATED fires several times for
  -- one loadout swap (and on login), so clearing the announcement latch here would print the
  -- same unchanged hero tree three or four times in a row.  Keeping it means the chat line
  -- fires on a real CHANGE of the resolved answer, which is what it is for.
  heroCached = nil
end

--------------------------------------------------------------------------------
-- Context — the whole-board facts the cascade reads.
--------------------------------------------------------------------------------
-- `env` is the coach instance (carries env.shardCostFn, the injected live cost reader).
-- Everything is keyed by BASE spellID: the Coach decides in the domain view's vocabulary,
-- and cooldownID is transport the Binder owns.
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

  local ss = (state.power or {}).SoulShards or {}
  local shards   = num(ss.value)
  local incoming = num(ss.incoming) or 0
  local smax     = num(ss.max) or self.SHARD_CAP
  local projected = shards and (shards + incoming) or nil

  local ctx = {
    facts = factsByBase,
    mode = state.mode,
    shards = shards, incoming = incoming, smax = smax,
    projected = projected,
    atCap = projected and projected >= self.SHARD_CAP or false,
    powerReadable = ss.readable ~= false and shards ~= nil,
  }

  -- ctx.powers — the generic power array the shell's ResourceBars emits from, driven off
  -- self.powers x state.power[name].  Destruction declares exactly SoulShards, so this is
  -- the same single discrete meter Demonology renders.
  ctx.powers = {}
  for _, p in ipairs(self.powers or {}) do
    local pw = (state.power or {})[p.name] or {}
    ctx.powers[#ctx.powers + 1] = {
      value     = num(pw.value),
      max       = num(pw.max) or self.SHARD_CAP,
      incoming  = num(pw.incoming) or 0,
      display   = p.display or "discrete",
      powerType = p.token,
    }
  end

  -- Live shard costs, resolved once per pulse.  The shell owns the INJECTED reader
  -- (env.shardCostFn = cfg.shardCost); this brain owns WHICH spells cost and the fallbacks.
  local function costOf(spellID, fallback)
    if env and env.shardCostFn and spellID then
      local c = env.shardCostFn(spellID)
      if type(c) == "number" then return c end
    end
    return fallback
  end
  ctx.cbCost  = costOf(S.CHAOS_BOLT,   self.CB_COST_FALLBACK)
  ctx.rofCost = costOf(S.RAIN_OF_FIRE, self.ROF_COST_FALLBACK)
  ctx.sbCost  = costOf(S.SHADOWBURN,   self.SB_COST_FALLBACK)

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
  -- trusting it is what made the HUD recommend Conflagrate at ZERO charges in the first live
  -- pass.  The mechanism, measured: the CDM raises `Available` every time a CHARGE is
  -- restored, but for a charged ability it never raises `OnCooldown` at all (capture: cid
  -- 18860 Available x7, OnCooldown x0, while eligible for both).  So State's ready-edge
  -- latches true on the first charge and is never cleared, and `cd` reads `ready` forever —
  -- 190 of 194 log lines said `Conf=R`.  The napkin cannot rescue it either: Conflagrate's
  -- `RecoveryTime` is 0 in DB2 (the recharge lives on ChargeCategory 672), so the
  -- base-cooldown countdown is 0 and the just-cast guard never fires.
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
  ctx.hero = resolveHero(factsByBase, ctx.artArmed, ctx.ritualUp)
  ctx.hellcaller = (ctx.hero == "hellcaller")

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
  -- TWO CHANNELS, in trust order:
  --   1. THE ALERT LATCH (field-fix C) — `absent` / `fresh` / `pandemic`, observed off the
  --      CDM's own choke point.  It is the only one that works IN COMBAT, and it is the only
  --      route to "refresh it early" at all, because the pandemic STATE is secret.  Read
  --      across every candidate id, since either Immolate row can raise the alert; the
  --      NEWEST wins, and State has already resolved cooldownIDs to base spellIDs.
  --   2. the aura / buff-item presence read — the pre-existing channel, still correct out of
  --      combat and still the fallback when nothing has latched yet.
  local edges = state.dotEdges or {}
  local edge
  for _, name in ipairs(DOT_KEYS) do
    local id = S[name]
    local e = id and edges[id]
    if e and (not edge or (num(e.at) or 0) >= (num(edge.at) or 0)) then edge = e end
  end

  local dotRow = dotID and abilities[dotID]
  local dotState = "unknown"
  if edge then
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

  -- The REFRESH half of L8.  ALIVE now, and edge-driven: Blizzard raises `PandemicTime` when
  -- the DoT genuinely enters its refresh window, computed per spell from the duration a
  -- recast would carry over — a better number than any lead we could tune, and the only one
  -- available at all, since the window's endpoints are Secret Values in combat.  A later
  -- `fresh`/`absent` edge supersedes it, so a recast stops the cue immediately.
  ctx.dotEdge = edge and edge.state or nil
  ctx.dotRefreshable = (dotState == "missing") or (ctx.dotEdge == "pandemic") or false

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
-- `excluded` (optional) — a BASE spellID removed from consideration at EVERY line that
-- names it, so the shell can recompute the honest SECOND place (the winner's ABILITY
-- pulled, list re-run from the top — NOT "the next line").  Destruction makes this sharper
-- than Demonology because two abilities each sit on multiple lines: Chaos Bolt at L1 (as
-- Ruination), L3 and L11; Incinerate at L6, L12 (as Infernal Bolt) and L13.  Excluding by
-- base spellID suppresses every one of them for free, since all the lines key on the same
-- base id — including the transform lines, which ride their base frame.
function spec:RankWinner(ctx, excluded)
  local S = ids()
  local projected = ctx.projected or ctx.shards or 0   -- value + signed incoming
  local ceiling = self.BUILD_CEILING

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

  -- L2 — Soul Fire while it fits without overcapping (simc: soul_shard<=4).
  if ctx.soulFireUsable and projected <= ceiling then
    k, lv, nt = pick(key(S.SOUL_FIRE), "ROTATION"); if k then return k, lv, nt end
  end

  -- L3 — spend an armed Demonic Art with Chaos Bolt.  See ART_FROM_RITUAL: today this only
  -- fires on a visible Ruination transform, which L1 already claimed, so in practice the
  -- line is reached only when the transform is seen but Ruination itself was excluded (the
  -- second-place recompute).  Affordability still gates it: a plain Chaos Bolt costs shards
  -- even when the Art is up, and we cannot tell a free one from a paid one.
  if ctx.artArmed and projected >= ctx.cbCost then
    k, lv, nt = pick(key(S.CHAOS_BOLT), "ROTATION", "spend the Demonic Art"); if k then return k, lv, nt end
  end

  -- L4 — Conflagrate to build, while it fits and no Backdraft is being wasted.  The gate is
  -- PRESENCE, not "< 2 stacks" (the count is secret), so this holds at 1 stack where simc
  -- would press — the conservative direction.
  if ctx.conflagrateUsable and projected <= ceiling and not ctx.backdraft then
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

  -- L6 — Incinerate empowered by Chaotic Inferno, while it fits (simc: soul_shard<=4.6).
  if ctx.chaoticInferno and projected <= ceiling then
    k, lv, nt = pick(key(S.INCINERATE), "ROTATION", "Chaotic Inferno"); if k then return k, lv, nt end
  end

  -- L7 — Shadowburn on Fiendish Cruelty or in execute range.  The execute half never fires
  -- today (no target channel — ctx.targetExecute is structurally false), so in practice this
  -- is the Fiendish Cruelty line.
  if ctx.shadowburnUsable and (ctx.fiendishCruelty or ctx.targetExecute)
      and projected >= ctx.sbCost then
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
  if ctx.mode == "aoe" and projected >= self.AOE_DUMP_FLOOR and projected >= ctx.rofCost then
    k, lv, nt = pick(key(S.RAIN_OF_FIRE), "ROTATION"); if k then return k, lv, nt end
  end

  -- L11 — Chaos Bolt: the main shard dump and the payoff spender.
  if projected >= ctx.cbCost then
    k, lv, nt = pick(key(S.CHAOS_BOLT), "ROTATION"); if k then return k, lv, nt end
  end

  -- L12 — Infernal Bolt as the shard refill when low.  Rides the Incinerate frame, so it is
  -- BLIND if Incinerate is not tracked — the worse twin of Demonology's Shadow Bolt hole,
  -- because this is the floor button.  @verify-ingame.
  if projected <= self.REFILL_FLOOR and ctx.ibFrame then
    k, lv, nt = pick(ctx.ibFrame, "ROTATION", "Infernal Bolt — shard refill"); if k then return k, lv, nt end
  end

  -- L13 — Incinerate: the floor.  If Incinerate is untracked there is no floor and the list
  -- can return nil (no press) at low shards — honest, and visible in the decision log as
  -- `w:-`, which is exactly the signal that the tracked set needs the curated layout.
  k, lv, nt = pick(key(S.INCINERATE), "ROTATION"); if k then return k, lv, nt end
  return nil
end

--------------------------------------------------------------------------------
-- Escalate — ROTATION -> LATE ONLY from READABLE overdue-ness.  A secret-gated quantity
--    can never drive an escalation.
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
  --    HoG-at-cap rule, on Destruction's payoff spender).  Gated on ACTUAL shards, not the
  --    projection: an in-flight spender has already committed to draining the bar, so
  --    projecting it would call you late for something you are mid-way through fixing.
  --    No burst carve-out, because Destruction never pools for a window on purpose.
  if rec.base == S.CHAOS_BOLT and ctx.shards and ctx.shards >= self.SHARD_CAP then
    return "LATE"
  end

  return level
end
