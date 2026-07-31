-- cdm-cases.lua — THE CDM EDGE INVENTORY.
--
-- A declarative corpus of "CDM input -> expected State row" cases, driven by
-- `tests/spec/cdm_cases_spec.lua`.  PURE DATA: no busted globals, no dofile of mock_ns,
-- nothing that reads the clock.  `tests/fixtures/` is never auto-collected (busted's
-- pattern is `_spec.lua`, and the gate invokes `busted CDMProbe/tests/spec`).
--
-- ══════════════════════════════════════════════════════════════════════════════
-- AUTHORING RULE — read this before adding a case
-- ══════════════════════════════════════════════════════════════════════════════
-- AUTHOR FROM THE KB, NOT FROM State.lua.  Walk `knowledge/addon-dev/cooldown-manager.md`
-- (§1 the two families · §2 the five identity rungs · §3 the value cascade · §5 the events
-- and the alert choke point · §7 the three-tier readable surface · §8 the nine audit
-- rules), write the expected answer, and check what State actually does ONLY AFTERWARDS.
-- A suite transcribed from the source is a change-detector wearing a contract's clothes:
-- green on every refactor, red on every fix.  Six defects exist because that order was
-- followed; a reader of State.lua would have written none of them.
--
-- Where a case is justified only by our own code, `pins` SAYS SO IN WORDS
-- ("characterisation:") and `ref` still names the external thing it is measured against.
-- `ref` may never point at State.lua — a meta-test enforces it.
--
-- ══════════════════════════════════════════════════════════════════════════════
-- CASE SCHEMA
-- ══════════════════════════════════════════════════════════════════════════════
--   name    unique, "<axis-word>/<what-it-pins>".  It IS the `it` title.
--   status  "green"          — agrees with the contract today; runs as a normal `it`
--           "pinned-defect"  — asserts the CONTRACT answer, INVERTED: the case is run
--                              under pcall and ERRORS IF IT PASSES.  Requires `fixes`.
--           "unreachable"    — the input does not exist today; runs as `pending`
--   fixes   required on pinned-defect: the roster-state-plan.md §3.x that resolves it
--   pins    one sentence: what contract this holds
--   ref     the study section / Blizzard source it is measured against.  MANDATORY.
--   spec    spec INDEX (1 = Demonology 266, 2 = Affliction/passive, 3 = Destruction 267).
--           REQUIRED on any case with an override field: ns.DisplayIdentity consults
--           ns.SpecInfo (Viewers.lua:151-165), so the expected identity depends on it.
--
--   rows[]  the CDM database.  Per row:
--           cid              the cooldownID
--           category         "Essential"|"Utility"|"TrackedBuff"|"TrackedBar"|"Hidden*"
--           categories       …or a LIST, for the dual-category case
--           info             the struct GetCooldownViewerCooldownInfo returns.  `false`
--                            means the call returns nothing.  A field set to `SECRET`
--                            becomes a secret sentinel.
--           infoThrows       the call raises
--           infoSecretTable  the returned table is a secret table
--           infoPoison       {"field", …} — the table indexes, but those fields raise
--           frame            the live item frame, or `false` for "not drawn".  Fields:
--                            isActive / isShown (true|false|"throws"|"secret"),
--                            hideWhenInactive (bool|"throws"), cooldownIDSecret,
--                            noCooldownID, getCooldownID = false, getCooldownIDThrows
--
--   world   the live client, at CLIENT-API level (not at verdict level — the point is to
--           keep Util.lua's guard ladder, the combat short-circuit and the GCD trap
--           inside the code under test):
--           cd[id] = { duration, startTime }   ⚠ include [61304] (the GCD) EXPLICITLY in
--                    every cd case: its absence is a distinct branch (Util.lua:235's 1.5s
--                    backstop), and leaving it out silently tests that instead.
--           charges[id] = { currentCharges, maxCharges } · auras[] · auraByID[id] ·
--           auraThrows[id] · glow[id] · known[id] · baseCD[id] · keybind[id] ·
--           napkin[id] (the HudNapkin remaining estimate) · override[base] = id ·
--           secret[] (values to mark) · throws[] (dotted API names) · now · combat ·
--           cdmUnavailable
--
--   script[]  ORDERED.  Ordering is not decoration: the same-frame refresh tie is DEFINED
--           by the absence of an `advance` between two alerts, and napkin-vs-edge
--           precedence by which happened last.  Steps:
--             { alert = "PandemicTime", cid = n }   { advance = seconds }
--             { combat = bool }                     { build = true, drain = bool }
--             { cast = spellID, phase = "start"|"succeeded" }
--             { override = { base = n, to = n } }   (fires the REAL event handler)
--             { release = true } / { acquire = true }
--           Omitted ⇒ one Build.  The LAST build is the pulse asserted.
--
--   expect  a map of VIEWS off one pulse — partial and deep by default:
--             raw       pulse.cooldowns (cid-keyed)   abilities  pulse.abilities
--             dropped   buffs   dotEdges   virtual    pulse (escape hatch)
--             edges     St.dotEdge — the RAW cid-keyed latch, before the fold
--             asked     which ids the CLIENT FAKE was called with:
--                         gcdCount / cooldownCount / chargesCount (numbers)
--                         cooldown / charges / glow / auraByID / known / info
--                         — membership maps that answer FALSE for an unasked id, so
--                           `{ [132411] = false }` states "you must NEVER have asked".
--           A key may be DOTTED ("1276452.cd.state").  ABSENT asserts the key is absent
--           (Lua cannot tell an absent key from a nil value, and "we must not fabricate a
--           value" is most of this project's contract).
--   exact   { <view> = true } — whole-shape equality for that view instead of partial.
--
--   noAcquire               skip St.Acquire() (only for the case that tests the gate)
--   expectsEmptyEnumeration opt out of the "the database enumerated non-empty" guard
--
-- ══════════════════════════════════════════════════════════════════════════════
-- ASSERT AGAINST St.Build, NOT THE READ HELPERS
-- ══════════════════════════════════════════════════════════════════════════════
-- `readCd` / `readCharge` / `readBuffItem` / `readAura` / `readGlow` are file locals with
-- no seam, and that is CORRECT: all three original Phase-2 defects are at CALL SITES, not
-- in the helpers (:1381 passes the wrong argument to correct code, :1415 gates on the
-- wrong thing, Util.lua:230 is called from the wrong place).  A helper-level case would
-- pass while Build called it wrong — which IS the defect.  ⚠ Do not add St.* seams; if a
-- case needs one, the case is at the wrong level.
--
-- ══════════════════════════════════════════════════════════════════════════════
-- EXPLICITLY NOT COVERED (stated here so the gap stays visible)
-- ══════════════════════════════════════════════════════════════════════════════
--   * `item.wasSetFromCharges` / `wasSetFromCooldown` / `wasSetFromAura` — @verify-ingame
--     (cooldown-manager.md §7 Tier 2 / §9); nothing reads them yet.
--   * `item.auraDataUnit` — same, and the only thing that says which side a bound aura is
--     on.  On status.md's backlog.
--   * `C_CooldownViewer.GetValidAlertTypes` — the roster coverage probe, Phase 4.  It
--     currently lives only in AlertTape.lua, the file scheduled for deletion.
--   * `item:GetLinkedSpell()` — the ELECTED rung-2 link.  Phase 3, blocked on §9's first
--     open question (whether a fresh struct read carries the election at all).
--
-- ══════════════════════════════════════════════════════════════════════════════
local ABSENT = setmetatable({}, { __tostring = function() return "<ABSENT>" end })
local SECRET = setmetatable({}, { __tostring = function() return "<SECRET>" end })

-- Real ids, so a failure reads as the ability it actually is.
local CHAOS_BOLT    = 116858
local CONFLAGRATE   = 17962
local INCINERATE    = 29722
local SHADOW_BOLT   = 686
local SOUL_FIRE     = 6353
local IMMOLATE_CAST = 348         -- cid 164597, Essential  (cooldown-manager.md §2.7)
local IMMOLATE_AURA = 157736      -- cid 133441, TrackedBuff
local WITHER        = 445474      -- the pool's Hellcaller candidate (§2.7)
local IMP_LORD      = 1276452     -- Demonology; cid 182891 carries tooltip 1288945
local SINGE_MAGIC   = 132411      -- the pet dispel that takes over the Grimoire button
local TYRANT        = 265187
local DEMONIC_CORE  = 264173      -- cid 777: selfAura = true, hasAura = FALSE (§7)
local GCD           = 61304

local READY_GCD = { duration = 0, startTime = 0 }   -- the GCD is not running

--------------------------------------------------------------------------------
-- A · FAMILY — tab 1 answers "can I press this", tab 2 answers "is this running"
--------------------------------------------------------------------------------
local A = {
  {
    name = "family/an-essential-row-is-the-pressable-representative",
    status = "green",
    spec = 3,
    pins = "A tab-1 row is a press: it reaches `abilities` under its base spellID and "
        .. "carries the cooldownID the Binder anchors to.",
    ref = "cooldown-manager.md §1.1 — tab 1 answers \"can I press this\"",
    rows = {
      { cid = 903, category = "Essential", frame = {},
        info = { spellID = CHAOS_BOLT, isKnown = true } },
    },
    expect = {
      abilities = { [CHAOS_BOLT] = { spellID = CHAOS_BOLT, category = "Essential",
                                     display = { cooldownID = 903 } } },
      dropped   = { [CHAOS_BOLT] = ABSENT },
    },
  },

  {
    name = "family/essential-outranks-utility-for-the-same-ability",
    status = "green",
    spec = 3,
    pins = "Category WITHIN a family is user-editable placement, so the fold needs a "
        .. "deterministic representative; Essential is it, Utility the fallback.",
    ref = "cooldown-manager.md §1 — \"Essential<->Utility are interchangeable\"",
    rows = {
      { cid = 903, category = "Utility",   frame = {},
        info = { spellID = CHAOS_BOLT, isKnown = true } },
      { cid = 904, category = "Essential", frame = {},
        info = { spellID = CHAOS_BOLT, isKnown = true } },
    },
    expect = {
      abilities = { [CHAOS_BOLT] = { ["display.cooldownID"] = 904, category = "Essential" } },
    },
  },

  {
    name = "family/a-trackedbuff-row-is-never-a-press-and-never-a-drop",
    status = "green",
    spec = 3,
    pins = "A tab-2 row has no pressable member by construction; excluding it is not a "
        .. "filter drop, and reporting it as one would drown the real signal.",
    ref = "cooldown-manager.md §1.1 — tab 2 answers \"is this running\"",
    rows = {
      { cid = 133441, category = "TrackedBuff", frame = {},
        info = { spellID = IMMOLATE_AURA, isKnown = true } },
    },
    expect = {
      raw       = { [133441] = { category = "TrackedBuff", spellID = IMMOLATE_AURA } },
      abilities = { [IMMOLATE_AURA] = ABSENT },
      dropped   = { [IMMOLATE_AURA] = ABSENT },
    },
  },

  {
    name = "family/a-tab2-aura-that-is-up-folds-into-buffs",
    status = "green",
    spec = 3,
    pins = "\"Is this running\" is the tab-2 question, and a live aura in the full player "
        .. "scan answers it under the row's own base spellID.",
    ref = "cooldown-manager.md §1.1 + §3.2 — first match wins, aura or totem",
    rows = {
      { cid = 133441, category = "TrackedBuff", frame = {},
        info = { spellID = IMMOLATE_AURA, isKnown = true, selfAura = true } },
    },
    world = { auras = { { spellId = IMMOLATE_AURA, name = "Immolate" } } },
    expect = {
      raw   = { [133441] = { aura = { readable = true, active = true } } },
      buffs = { [IMMOLATE_AURA] = true },
    },
  },

  {
    name = "family/tab2-IsActive-is-a-real-signal",
    status = "green",
    spec = 3,
    pins = "On tab 2 `IsActive()` tracks aura liveness, so it is the per-buff "
        .. "combat-readable signal the struct never carries.",
    ref = "cooldown-manager.md §1.1 / §7 Tier 2 — CooldownViewerBuffItemMixin:ShouldBeActive [:1186]",
    rows = {
      { cid = 133441, category = "TrackedBuff", frame = { isActive = true },
        info = { spellID = IMMOLATE_AURA, isKnown = true, selfAura = true } },
    },
    expect = {
      raw   = { [133441] = { buff = { isActive = true, isActiveReadable = true } } },
      buffs = { [IMMOLATE_AURA] = true },
    },
  },

  {
    name = "family/tab1-IsActive-is-constant-true-and-must-not-reach-buffs",
    status = "pinned-defect",
    fixes = "phase2 §3.1",
    spec = 3,
    pins = "`CooldownViewerItemMixin:ShouldBeActive()` is `return self.cooldownID ~= nil`, "
        .. "and only the BUFF item mixin overrides it — so on any Essential/Utility row "
        .. "`item:IsActive()` is constant true, with no error and no nil to tell it from a "
        .. "real signal.  State gates the read on `hasAura or selfAura` (struct flags) "
        .. "instead of on FAMILY, so a tab-1 row carrying selfAura reads permanently "
        .. "buffed — and both brains read `buffs` directly.",
    ref = "cooldown-manager.md §8 rule 4 + §1.1; CooldownViewer.lua:362-364, :1186",
    rows = {
      { cid = 903, category = "Essential", frame = { isActive = true },
        info = { spellID = TYRANT, isKnown = true, selfAura = true } },
    },
    expect = {
      buffs = { [TYRANT] = ABSENT },
      raw   = { [903] = { buff = ABSENT } },
    },
  },

  {
    name = "family/a-tab2-row-has-no-cooldown-rung-to-read",
    status = "pinned-defect",
    fixes = "phase2 §3.8",
    spec = 3,
    pins = "Tab 2's value cascade is totem -> aura -> edit mode -> zeros: there is no "
        .. "spell-cooldown rung at all, so asking the client for one produces a field "
        .. "nothing can consume, at the full guarded-call cost, 10 times a second.",
    ref = "cooldown-manager.md §3.2 — \"structurally cannot display a spell cooldown\"",
    rows = {
      { cid = 133441, category = "TrackedBuff", frame = {},
        info = { spellID = IMMOLATE_AURA, isKnown = true } },
    },
    world = { cd = { [GCD] = READY_GCD } },
    expect = { asked = { cooldown = { [IMMOLATE_AURA] = false } } },
  },
}

--------------------------------------------------------------------------------
-- B · IDENTITY — five rungs, one pool
--------------------------------------------------------------------------------
local B = {
  {
    name = "identity/rung5-the-base-spellID-when-nothing-overrides",
    status = "green",
    spec = 3,
    pins = "The bottom rung: with no override of any kind the row's identity is what it "
        .. "was configured as.",
    ref = "cooldown-manager.md §2 rung 5 — cooldownInfo.spellID",
    rows = {
      { cid = 903, category = "Essential", frame = {},
        info = { spellID = CHAOS_BOLT, isKnown = true } },
    },
    expect = {
      raw       = { [903] = { spellID = CHAOS_BOLT, liveSpellID = CHAOS_BOLT,
                              overrideSpellID = ABSENT, overrideTooltipSpellID = ABSENT } },
      abilities = { [CHAOS_BOLT] = { identity = CHAOS_BOLT } },
    },
  },

  {
    name = "identity/rung4-overrideSpellID-when-it-is-the-only-override",
    status = "green",
    spec = 3,
    pins = "Rung 4 answers \"has something replaced this button wholesale\"; with no "
        .. "tooltip candidate above it, it is the live identity.",
    ref = "cooldown-manager.md §2 rung 4 — cooldownInfo.overrideSpellID",
    rows = {
      { cid = 66181, category = "Essential", frame = {},
        info = { spellID = SHADOW_BOLT, isKnown = true, overrideSpellID = CHAOS_BOLT } },
    },
    expect = {
      raw = { [66181] = { spellID = SHADOW_BOLT, liveSpellID = CHAOS_BOLT,
                          overrideSpellID = CHAOS_BOLT } },
    },
  },

  {
    name = "identity/rung3-outranks-rung4-in-the-live-ladder",
    status = "green",
    spec = 3,
    pins = "`GetSpellID()` tries overrideTooltipSpellID BEFORE overrideSpellID.  State's "
        .. "`liveSpellID` gets this right — and this case is the green half of the pair "
        .. "whose other half (the display ladder) does not.",
    ref = "cooldown-manager.md §2 — the rung order of GetSpellID(), ItemData.lua:174-196",
    rows = {
      { cid = 66181, category = "Essential", frame = {},
        info = { spellID = SHADOW_BOLT, isKnown = true,
                 overrideSpellID = CHAOS_BOLT, overrideTooltipSpellID = INCINERATE } },
    },
    expect = { raw = { [66181] = { liveSpellID = INCINERATE } } },
  },

  {
    name = "identity/rung3-vs-rung4-the-display-ladder-is-inverted",
    status = "pinned-defect",
    fixes = "phase2 §3.5",
    spec = 3,
    pins = "On a row carrying BOTH override fields the two ladders disagree: liveSpellID "
        .. "takes the tooltip (correct), ns.DisplayIdentity takes overrideSpellID first "
        .. "(the reverse of Blizzard's) — and it is the DISPLAY one that decides the key "
        .. "the row is filed and read under.",
    ref = "cooldown-manager.md §2 — rung 3 precedes rung 4; ItemData.lua:174-196",
    rows = {
      { cid = 66181, category = "Essential", frame = {},
        info = { spellID = SHADOW_BOLT, isKnown = true,
                 overrideSpellID = CHAOS_BOLT, overrideTooltipSpellID = INCINERATE } },
    },
    expect = {
      abilities = { [INCINERATE] = { spellID = SHADOW_BOLT, identity = INCINERATE },
                    [CHAOS_BOLT] = ABSENT },
    },
  },

  {
    name = "identity/an-observed-override-event-stands-in-for-the-frame-only-rungs",
    status = "green",
    spec = 1,
    pins = "Rungs 1-2 live on the item frame, not in the struct, so the observed "
        .. "COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED event is the only channel a fresh "
        .. "struct read has for a live takeover — and the study says to track overrides "
        .. "from the event rather than assume a fresh read reflects them.",
    ref = "cooldown-manager.md §2.5 [gap] + §8 rule 9",
    rows = {
      { cid = 182891, category = "Essential", frame = {},
        info = { spellID = IMP_LORD, isKnown = true } },
    },
    world = { now = 1000, cd = { [IMP_LORD] = { duration = 120, startTime = 900 },
                                 [GCD] = READY_GCD } },
    script = { { override = { base = IMP_LORD, to = SINGE_MAGIC } }, { build = true } },
    expect = {
      raw       = { [182891] = { liveSpellID = SINGE_MAGIC, spellID = IMP_LORD } },
      -- Readiness keys on the DISPLAY identity, never on a foreign live override: the
      -- Grimoire button showing the imp's dispel must not report the dispel's cooldown.
      abilities = { [IMP_LORD] = { cd = { state = "on-cooldown", remaining = 20,
                                          source = "live" } } },
      asked     = { cooldown = { [IMP_LORD] = true, [SINGE_MAGIC] = false },
                    -- ...but the GLOW does read `live`: Blizzard lands the proc highlight
                    -- on the EMPOWERED spell, so there the override IS the right id.
                    glow = { [SINGE_MAGIC] = true } },
    },
  },

  {
    name = "identity/a-secret-base-spellID-refuses-the-whole-row",
    status = "green",
    spec = 3,
    pins = "Structural ids can read secret in restricted combat, and `type(secret) == "
        .. "\"number\"` is TRUE — so an unguarded read returns a poisoned value that then "
        .. "keys a table.  Nothing is fabricated: no base, no identity, no fold.",
    ref = "cooldown-manager.md §7 Tier 1/Tier 2 — ids can read secret in restricted combat",
    rows = {
      { cid = 903, category = "Essential", frame = {},
        info = { spellID = SECRET, isKnown = true } },
    },
    expect = {
      raw       = { [903] = { spellID = ABSENT, liveSpellID = ABSENT } },
      abilities = { [CHAOS_BOLT] = ABSENT },
    },
  },

  {
    name = "identity/a-secret-rung3-falls-through-to-rung4",
    status = "green",
    spec = 3,
    pins = "The ladder is a candidate list with fallback, not a single test: an "
        .. "unreadable rung is skipped, not a refusal of the whole identity.",
    ref = "cooldown-manager.md §2 + §7 Tier 1",
    rows = {
      { cid = 66181, category = "Essential", frame = {},
        info = { spellID = SHADOW_BOLT, isKnown = true,
                 overrideSpellID = CHAOS_BOLT, overrideTooltipSpellID = SECRET } },
    },
    expect = {
      raw = { [66181] = { liveSpellID = CHAOS_BOLT, overrideTooltipSpellID = ABSENT,
                          overrideSpellID = CHAOS_BOLT } },
    },
  },

  {
    name = "identity/the-static-pool-is-carried-whole-and-readable-only",
    status = "green",
    spec = 3,
    pins = "`linkedSpellIDs` is the static candidate POOL from DB2 — always a table, "
        .. "frequently empty, hard-capped at 4.  It never itself becomes the identity, "
        .. "and an unreadable member is dropped rather than carried.",
    ref = "cooldown-manager.md §2.1 — linkedSpellIDs (plural) vs linkedSpellID (singular)",
    rows = {
      { cid = 164597, category = "Essential", frame = {},
        info = { spellID = IMMOLATE_CAST, isKnown = true,
                 linkedSpellIDs = { IMMOLATE_AURA, SECRET, WITHER } } },
    },
    expect = {
      raw = { [164597] = { linkedSpellIDs = { IMMOLATE_AURA, WITHER },
                           liveSpellID = IMMOLATE_CAST } },
    },
    exact = { raw = false },
  },

  {
    name = "identity/an-override-this-spec-has-no-opinion-about-is-refused",
    status = "green",
    spec = 3,
    pins = "characterisation: adopting an override as the DISPLAY identity is the "
        .. "project's own conservatism, not Blizzard's — Blizzard would show it.  An id "
        .. "the spec table does not declare is not an identity we will key rows under.",
    ref = "cooldown-manager.md §2 (the ladder this deliberately narrows) + §8 rule 2",
    rows = {
      { cid = 66181, category = "Essential", frame = {},
        info = { spellID = SHADOW_BOLT, isKnown = true, overrideSpellID = 999999 } },
    },
    expect = {
      raw       = { [66181] = { liveSpellID = 999999 } },
      abilities = { [SHADOW_BOLT] = { identity = SHADOW_BOLT }, [999999] = ABSENT },
    },
  },

  {
    name = "identity/an-expect-false-override-never-becomes-the-key",
    status = "green",
    spec = 1,
    pins = "characterisation: the pet dispels (Singe Magic / Devour Magic) only ever "
        .. "appear as a takeover of someone else's button, so the spec table declares "
        .. "`expect = false` and they are refused as an identity.  Blizzard's own ladder "
        .. "makes no such distinction.",
    ref = "cooldown-manager.md §2 rung 4 (the rung this narrows) + §8 rule 2",
    rows = {
      { cid = 182891, category = "Essential", frame = {},
        info = { spellID = IMP_LORD, isKnown = true, overrideSpellID = SINGE_MAGIC } },
    },
    expect = {
      abilities = { [IMP_LORD] = { identity = IMP_LORD }, [SINGE_MAGIC] = ABSENT },
    },
  },

  {
    name = "identity/rung1-the-live-aura-instance",
    status = "unreachable",
    spec = 3,
    pins = "rung 1 (`GetAuraSpellID()` — the aura APPLICATION this frame is bound to) "
        .. "lives on the item frame and State never asks for it, so no input can reach it "
        .. "today.  It is ephemeral by design (dies with the aura) and binds via "
        .. "SpellIDMatchesAnyAssociatedSpellIDs, so it can match the base spell's own "
        .. "aura, which is never in the pool",
    ref = "cooldown-manager.md §2 rung 1 / §2.4 / §2.5 — ItemData.lua:200-229, :243-254",
    rows = {},
  },

  {
    name = "identity/rung2-the-elected-linkedSpellID",
    status = "unreachable",
    spec = 3,
    pins = "the POOL is consumed (State.lua's aura-id list), the ELECTION is not: "
        .. "`GetCooldownViewerCooldownInfo` returns `linkedSpellIDs` (plural, static) and "
        .. "NOT the elected singular `linkedSpellID`, which lives on the provider's shared "
        .. "cached record.  Whether a fresh read carries it at all is §9's first open "
        .. "question, and it blocks Phase 3's Hellcaller/Wither keybind ladder",
    ref = "cooldown-manager.md §2.1 / §2.2 / §2.5 [gap] — ItemData.lua:12-43, :126-150",
    rows = {},
  },

  {
    name = "identity/rung2-is-sticky-across-an-aura-removal",
    status = "unreachable",
    spec = 3,
    pins = "the asymmetry that makes rung 2 worth having: OnUnitAuraRemovedEvent ALWAYS "
        .. "clears rung 1, but clears rung 2 only if it was the same spell — so a link "
        .. "elected through the cooldown-event path survives auras coming and going "
        .. "indefinitely.  Unreachable for the same reason as the election itself",
    ref = "cooldown-manager.md §2.3 — CooldownViewer.lua:194-202",
    rows = {},
  },
}

--------------------------------------------------------------------------------
-- G · DRAWABILITY + THE BUFF ITEM
--------------------------------------------------------------------------------
local G = {
  {
    name = "draw/no-item-frame-is-a-reported-drop-not-a-silence",
    status = "green",
    spec = 3,
    pins = "A cooldownID with no item frame in any live viewer has nothing for the Binder "
        .. "to anchor to.  The row leaves `abilities` — and says why, so a wrong filter "
        .. "shows up in the next capture instead of being silently absent.",
    ref = "cooldown-manager.md §7 Tier 2 — item.cooldownID is the binding key",
    rows = {
      { cid = 903, category = "Essential", frame = {},
        info = { spellID = CHAOS_BOLT, isKnown = true } },
      { cid = 904, category = "Essential", frame = false,
        info = { spellID = INCINERATE, isKnown = true } },
    },
    expect = {
      raw       = { [904] = { displayable = false }, [903] = { displayable = true } },
      abilities = { [INCINERATE] = ABSENT },
      dropped   = { [INCINERATE] = "no-icon" },
    },
  },

  {
    name = "draw/an-empty-frame-map-skips-the-filter-wholesale",
    status = "green",
    spec = 3,
    pins = "An empty frame map means the viewers are not up (login, CDM off, a relayout "
        .. "mid-pulse), not that nothing on the board can be drawn.  Nothing is registered "
        .. "while a viewer is hidden, so this state is normal, not exceptional.",
    ref = "cooldown-manager.md §4 — \"Nothing is registered while a viewer is hidden\"",
    rows = {
      { cid = 903, category = "Essential", frame = false,
        info = { spellID = CHAOS_BOLT, isKnown = true } },
    },
    expect = {
      abilities = { [CHAOS_BOLT] = { displayable = false } },
      dropped   = { [CHAOS_BOLT] = ABSENT },
    },
  },

  {
    name = "draw/an-unreadable-item-cooldownID-falls-back-to-GetCooldownID",
    status = "green",
    spec = 3,
    pins = "`item.cooldownID` can read secret in restricted combat; it is the binding key, "
        .. "so it must never be overwritten with an unreadable value — the method is the "
        .. "fallback, and the row stays drawable.  (The harness models \"did not read as a "
        .. "usable number\" with a non-number sentinel, since its secret registry is keyed "
        .. "by value and marking the cid itself would also hide it from `enumerate`.)",
    ref = "cooldown-manager.md §7 Tier 2 — item.cooldownID, \"resolve out of combat\"",
    rows = {
      { cid = 903, category = "Essential", frame = { cooldownIDSecret = true },
        info = { spellID = CHAOS_BOLT, isKnown = true } },
    },
    expect = {
      raw       = { [903] = { displayable = true } },
      abilities = { [CHAOS_BOLT] = { displayable = true } },
    },
  },

  {
    name = "draw/a-throwing-IsActive-degrades-to-unreadable-not-to-false",
    status = "green",
    spec = 3,
    pins = "Absence of a read is not evidence of absence of the buff: a refused "
        .. "`IsActive()` reports `isActiveReadable = false` with no value at all, rather "
        .. "than a fabricated `false` that would read as \"the buff is down\".",
    ref = "cooldown-manager.md §7 Tier 2 — item:IsActive(), tab 2",
    rows = {
      { cid = 133441, category = "TrackedBuff", frame = { isActive = "throws" },
        info = { spellID = IMMOLATE_AURA, isKnown = true, selfAura = true } },
    },
    expect = {
      raw   = { [133441] = { buff = { isActiveReadable = false, isActive = ABSENT } } },
      buffs = { [IMMOLATE_AURA] = ABSENT },
    },
  },

  {
    name = "draw/a-secret-IsActive-is-refused-the-same-way-a-throw-is",
    status = "green",
    spec = 3,
    pins = "A secret answer and a refused call are the same verdict here — we did not "
        .. "learn whether the buff is up — and neither may become a boolean on the pulse.",
    ref = "cooldown-manager.md §7 Tier 2 + security-taint-and-restricted-data.md",
    rows = {
      { cid = 133441, category = "TrackedBuff", frame = { isActive = "secret" },
        info = { spellID = IMMOLATE_AURA, isKnown = true, selfAura = true } },
    },
    expect = {
      raw   = { [133441] = { buff = { isActiveReadable = false, isActive = ABSENT } } },
      buffs = { [IMMOLATE_AURA] = ABSENT },
    },
  },

  {
    name = "draw/IsShown-rides-with-its-capability-flag",
    status = "green",
    spec = 3,
    pins = "`ShouldBeShown` returns true immediately when the viewer is not set to "
        .. "hide-when-inactive, so `IsShown()` is then a CONSTANT and anything driven off "
        .. "it latches on permanently.  It is carried only alongside `hideWhenInactive`, "
        .. "which is what says whether it is a signal at all.",
    ref = "cooldown-manager.md §8 rule 7 + §7 Tier 2 — CooldownViewer.lua:311-335",
    rows = {
      { cid = 133441, category = "TrackedBuff",
        frame = { isShown = true, hideWhenInactive = false, isActive = false },
        info = { spellID = IMMOLATE_AURA, isKnown = true, selfAura = true } },
    },
    expect = {
      raw = { [133441] = { buff = { shown = true, hideWhenInactive = false } } },
    },
  },

  {
    name = "draw/a-throwing-hideWhenInactive-index-is-absorbed",
    status = "green",
    spec = 3,
    pins = "The field is read through a pcall'd INDEX, not a call — a table that passes "
        .. "every prior guard can still raise on access under the 12.0 restrictions.  The "
        .. "flag simply goes absent and the pulse is otherwise intact.",
    ref = "cooldown-manager.md §7 Tier 2 + security-taint-and-restricted-data.md",
    rows = {
      { cid = 133441, category = "TrackedBuff",
        frame = { isActive = true, hideWhenInactive = "throws" },
        info = { spellID = IMMOLATE_AURA, isKnown = true, selfAura = true } },
    },
    expect = {
      raw = { [133441] = { buff = { isActive = true, hideWhenInactive = ABSENT } } },
    },
  },

  {
    name = "draw/a-charge-shape-inferred-from-a-flag-is-not-a-measurement",
    status = "pinned-defect",
    fixes = "phase2 §3.7",
    spec = 3,
    pins = "In combat `C_Spell.GetSpellCharges` is secret, so ns.ReadCharges "
        .. "short-circuits and the `not hasCharges` branch returns the SAME shape a live "
        .. "read with max <= 1 returns — `{readable = true, cur = nil, max = 0}`.  One is "
        .. "a measurement, the other a struct-flag inference, and this is the one field "
        .. "whose whole job is to say which.  Trust and meaning are independent axes.",
    ref = "cooldown-manager.md §8 rule 5 + §7 Tier 3 (GetSpellCharges secret in combat)",
    rows = {
      { cid = 903, category = "Essential", frame = {},
        info = { spellID = CHAOS_BOLT, isKnown = true, charges = false } },
    },
    world = { combat = true },
    expect = { raw = { [903] = { charge = { readable = false } } } },
  },
}

--------------------------------------------------------------------------------
-- C · COMBAT + Util.lua's VALUE CASCADE
--------------------------------------------------------------------------------
-- The seam is COMBAT, not instancing, and it was measured: `C_Spell.GetSpellCooldown` is
-- `SecretWhenCooldownsRestricted` (SpellDocumentation.lua:249) and reads 13/13 out of
-- combat, 0/13 in.  Phases 7a (the OOC baseline) and 7b (the observed alert edge) are what
-- keep readiness honest across that seam, and they had NO direct tests before this axis.
--------------------------------------------------------------------------------
local C = {
  {
    name = "combat/an-OOC-read-is-the-precise-truth-and-says-so",
    status = "green",
    spec = 3,
    pins = "Out of combat the client answers, so `remaining` is a measurement: "
        .. "startTime + duration - now, annotated source = live.",
    ref = "cooldown-manager.md §7 Tier 3 — GetSpellCooldown fully readable OUT of combat",
    rows = {
      { cid = 903, category = "Essential", frame = {},
        info = { spellID = CHAOS_BOLT, isKnown = true } },
    },
    world = { now = 1000, cd = { [CHAOS_BOLT] = { duration = 120, startTime = 900 },
                                 [GCD] = READY_GCD } },
    expect = {
      abilities = { [CHAOS_BOLT] = { cd = { state = "on-cooldown", remaining = 20,
                                            readable = true, source = "live" } } },
    },
  },

  {
    name = "combat/in-combat-the-read-is-not-even-attempted",
    status = "green",
    spec = 3,
    pins = "The combat short-circuit is at the door, not at the guards: burning a pcall "
        .. "per row per tick mid-fight is not free, and a caller that got nil for the "
        .. "wrong reason would look like the feature is broken rather than out of scope.",
    ref = "cooldown-manager.md §7 Tier 3 + security-taint-and-restricted-data.md "
       .. "(GetSpellCooldown is SecretWhenCooldownsRestricted)",
    rows = {
      { cid = 903, category = "Essential", frame = {},
        info = { spellID = CHAOS_BOLT, isKnown = true } },
    },
    world = { combat = true, now = 1000,
              cd = { [CHAOS_BOLT] = { duration = 120, startTime = 900 }, [GCD] = READY_GCD } },
    expect = {
      abilities = { [CHAOS_BOLT] = { cd = { state = "unknown", readable = false,
                                            source = "none", remaining = ABSENT } } },
      asked     = { cooldownCount = 0, gcdCount = 0 },
      pulse     = { combat = true },
    },
  },

  {
    name = "combat/a-ready-OOC-baseline-survives-the-combat-seam",
    status = "green",
    spec = 3,
    pins = "The never-cast-summon case: the client said READY out of combat and nothing "
        .. "has been cast since, so it is still ready.  Without the projection the row "
        .. "collapses to source:none the instant the pull starts.",
    ref = "cooldown-manager.md §7 Tier 3 — readable OUT of combat, secret IN",
    rows = {
      { cid = 903, category = "Essential", frame = {},
        info = { spellID = TYRANT, isKnown = true } },
    },
    world = { now = 1000, cd = { [TYRANT] = { duration = 0, startTime = 0 },
                                 [GCD] = READY_GCD } },
    script = { { build = true }, { combat = true }, { advance = 2 }, { build = true } },
    expect = {
      abilities = { [TYRANT] = { cd = { state = "ready", remaining = 0, source = "live" } } },
      -- Two reads TOTAL across both pulses — the spell and the GCD, both on the OOC one.
      -- The in-combat pulse asked nothing at all and still answered `ready`.
      asked     = { cooldownCount = 2, gcdCount = 1, cooldown = { [TYRANT] = true } },
    },
  },

  {
    name = "combat/a-COOLING-baseline-is-projected-as-an-estimate-not-a-read",
    status = "green",
    spec = 3,
    pins = "Trust and meaning are independent axes: the projection is arithmetic over an "
        .. "old measurement, so it carries the number but reports readable = false / "
        .. "source = napkin rather than laundering itself as a live read.",
    ref = "cooldown-manager.md §8 rule 5 + §7 Tier 3",
    rows = {
      { cid = 903, category = "Essential", frame = {},
        info = { spellID = CHAOS_BOLT, isKnown = true } },
    },
    world = { now = 1000, cd = { [CHAOS_BOLT] = { duration = 120, startTime = 900 },
                                 [GCD] = READY_GCD } },
    script = { { build = true }, { combat = true }, { advance = 5 }, { build = true } },
    expect = {
      abilities = { [CHAOS_BOLT] = { cd = { state = "on-cooldown", remaining = 15,
                                            readable = false, source = "napkin" } } },
    },
  },

  {
    name = "combat/the-GCD-trap-a-ready-spell-reports-the-global-cooldown",
    status = "green",
    spec = 3,
    pins = "`GetSpellCooldown` reports the GLOBAL COOLDOWN for a spell that is genuinely "
        .. "ready — Blizzard's own `GetSpellCooldownDuration(spellIdentifier, ignoreGCD)` "
        .. "carries that flag precisely because the default includes it.  So a naive "
        .. "`duration > 0` reads EVERY ability as on cooldown for 1.5s after any cast.  "
        .. "Resolved against the LIVE GCD, not a magic number: a (startTime, duration) "
        .. "pair matching the GCD's own IS the GCD.",
    ref = "security-taint-and-restricted-data.md — C_Spell.GetSpellCooldownDuration"
       .. "(spellIdentifier, ignoreGCD), SpellDocumentation.lua:267",
    rows = {
      { cid = 903, category = "Essential", frame = {},
        info = { spellID = CHAOS_BOLT, isKnown = true } },
    },
    world = { now = 1000, cd = { [CHAOS_BOLT] = { duration = 1.5, startTime = 1000 },
                                 [GCD] = { duration = 1.5, startTime = 1000 } } },
    expect = {
      abilities = { [CHAOS_BOLT] = { cd = { state = "ready", remaining = 0,
                                            source = "live" } } },
    },
  },

  {
    name = "combat/a-real-1.5s-cooldown-is-not-the-GCD-when-the-pair-differs",
    status = "green",
    spec = 3,
    pins = "The test is the PAIR, not the length: same duration but a different "
        .. "startTime is this spell's own cooldown, and must not be swallowed.",
    ref = "security-taint-and-restricted-data.md — the ignoreGCD flag; "
       .. "cooldown-manager.md §7 Tier 3",
    rows = {
      { cid = 903, category = "Essential", frame = {},
        info = { spellID = CHAOS_BOLT, isKnown = true } },
    },
    world = { now = 1000, cd = { [CHAOS_BOLT] = { duration = 1.5, startTime = 1000 },
                                 [GCD] = { duration = 1.5, startTime = 990 } } },
    expect = {
      abilities = { [CHAOS_BOLT] = { cd = { state = "on-cooldown", remaining = 1.5,
                                            source = "live" } } },
    },
  },

  {
    name = "combat/with-no-GCD-read-at-all-the-1.5s-backstop-applies",
    status = "green",
    spec = 3,
    pins = "The ABSENCE of a GCD read is a distinct branch, not a variant of the pair "
        .. "match — hence the standing rule that a cd case names [61304] explicitly.  "
        .. "1.5s is the unhasted global; a real cooldown that short is not tracked.",
    ref = "security-taint-and-restricted-data.md — the ignoreGCD flag; "
       .. "cooldown-manager.md §7 Tier 3",
    rows = {
      { cid = 903, category = "Essential", frame = {},
        info = { spellID = CHAOS_BOLT, isKnown = true } },
    },
    world = { now = 1000, cd = { [CHAOS_BOLT] = { duration = 1.5, startTime = 1000 } } },
    expect = {
      abilities = { [CHAOS_BOLT] = { cd = { state = "ready", source = "live" } } },
      asked     = { gcdCount = 1 },   -- asked, and got nothing
    },
  },

  {
    name = "combat/a-banked-charge-short-circuits-the-recharge-timer",
    status = "green",
    spec = 3,
    pins = "For a CHARGED ability GetSpellCooldown reports the RECHARGE of the NEXT "
        .. "charge, so an ability with one banked would seed as on cooldown.  A banked "
        .. "charge means pressable, whatever the recharge says — and the short-circuit is "
        .. "before the GCD read, so that read never happens either.",
    ref = "cooldown-manager.md §3.1 order 1 — the charges source, guarded on "
       .. "`cooldownStartTime > 0 and currentCharges > 0` [CooldownViewer.lua:864]",
    rows = {
      { cid = 903, category = "Essential", frame = {},
        info = { spellID = CONFLAGRATE, isKnown = true, charges = true } },
    },
    world = { now = 1000, cd = { [CONFLAGRATE] = { duration = 10, startTime = 995 },
                                 [GCD] = READY_GCD },
              charges = { [CONFLAGRATE] = { currentCharges = 1, maxCharges = 2 } } },
    expect = {
      abilities = { [CONFLAGRATE] = {
        cd     = { state = "ready", remaining = 0, source = "live" },
        charge = { readable = true, cur = 1, max = 2, source = "live", charged = true },
      } },
      asked = { gcdCount = 0 },
    },
  },

  {
    name = "combat/an-observed-alert-edge-is-ground-truth-where-the-API-refuses",
    status = "green",
    spec = 3,
    pins = "`TriggerAlertEvent` is a CHOKE POINT, not a secret-guarded API read, and it is "
        .. "invoked unconditionally — the user's alert configuration is consulted inside "
        .. "the body.  So an Available edge is an OBSERVATION of readiness in restricted "
        .. "combat, which is the one thing the cooldown read cannot give.",
    ref = "cooldown-manager.md §5.1 — CooldownViewer.lua:483-494, all six confirmed "
       .. "firing in restricted combat",
    rows = {
      { cid = 903, category = "Essential", frame = {},
        info = { spellID = TYRANT, isKnown = true } },
    },
    world = { combat = true },
    script = { { alert = "Available", cid = 903 }, { build = true } },
    expect = {
      abilities = { [TYRANT] = { cd = { state = "ready", remaining = 0, readable = true,
                                        source = "live" } } },
    },
  },

  {
    name = "combat/a-live-napkin-countdown-outranks-a-stale-Available-edge",
    status = "green",
    spec = 3,
    pins = "characterisation: the just-cast race is ours to resolve, not Blizzard's.  An "
        .. "Available edge fired before the press is still latched afterwards, so a live "
        .. "anticipation countdown — a cast filed THIS recently — has to win, or the HUD "
        .. "re-cues the spell you just pressed.",
    ref = "cooldown-manager.md §5.1 (the edge is an observation, with no ordering "
       .. "guarantee against our own cast) + §8 rule 9",
    rows = {
      { cid = 903, category = "Essential", frame = {},
        info = { spellID = CHAOS_BOLT, isKnown = true } },
    },
    world = { combat = true, napkin = { [CHAOS_BOLT] = 5 } },
    script = { { alert = "Available", cid = 903 }, { build = true } },
    expect = {
      abilities = { [CHAOS_BOLT] = { cd = { state = "on-cooldown", remaining = 5,
                                            readable = false, source = "napkin" } } },
    },
  },

  {
    name = "combat/an-expired-napkin-estimate-is-probably-up-never-a-laundered-ready",
    status = "green",
    spec = 3,
    pins = "characterisation, and the project's central honesty rule: an estimate that "
        .. "has run out says \"on cooldown, remaining 0, unconfirmed\" — never `ready`, "
        .. "which is reserved for something observed.",
    ref = "cooldown-manager.md §8 rule 5 — trust and meaning are independent axes",
    rows = {
      { cid = 903, category = "Essential", frame = {},
        info = { spellID = CHAOS_BOLT, isKnown = true } },
    },
    world = { combat = true, napkin = { [CHAOS_BOLT] = 0 } },
    expect = {
      abilities = { [CHAOS_BOLT] = { cd = { state = "on-cooldown", remaining = 0,
                                            readable = false, source = "napkin" } } },
    },
  },

  {
    name = "combat/the-GCD-is-re-read-once-per-enumerated-entry",
    status = "pinned-defect",
    fixes = "phase2 §3.3",
    spec = 3,
    pins = "The GCD is one global fact per instant, but `ns.ReadCooldown` resolves it "
        .. "inside itself, so it is re-read for EVERY entry — ~64 identical guarded reads "
        .. "per tick at 10 Hz on Demonology.  Read it once per pulse and pass it down: "
        .. "pure win, no behaviour change — and this case is the entire fix as one number.",
    ref = "security-taint-and-restricted-data.md — the GCD is a single global fact; "
       .. "cooldown-manager.md §4 (the CDM itself polls, it does not re-resolve)",
    rows = {
      { cid = 901, category = "Essential", frame = {},
        info = { spellID = CHAOS_BOLT, isKnown = true } },
      { cid = 902, category = "Essential", frame = {},
        info = { spellID = CONFLAGRATE, isKnown = true } },
      { cid = 903, category = "Essential", frame = {},
        info = { spellID = TYRANT, isKnown = true } },
    },
    world = { now = 1000, cd = {
      [CHAOS_BOLT]  = { duration = 120, startTime = 900 },
      [CONFLAGRATE] = { duration = 120, startTime = 900 },
      [TYRANT]      = { duration = 120, startTime = 900 },
      [GCD] = READY_GCD } },
    expect = { asked = { gcdCount = 1 } },
  },
}

--------------------------------------------------------------------------------
-- D · PER-FIELD READABILITY — value · SECRET · absent · THROWS, at every guarded site
--------------------------------------------------------------------------------
local D = {
  {
    name = "read/an-absent-info-struct-leaves-the-row-without-an-identity",
    status = "green",
    spec = 3,
    pins = "`GetCooldownViewerCooldownInfo` is MayReturnNothing = true.  The cooldownID "
        .. "is still real (it came from the category set), so the row exists — it simply "
        .. "carries nothing, rather than being invented or dropped.",
    ref = "cooldown-manager.md §7 Tier 1 — the struct is MayReturnNothing",
    rows = { { cid = 903, category = "Essential", frame = {}, info = false } },
    expect = {
      raw       = { [903] = { cooldownID = 903, category = "Essential",
                              spellID = ABSENT, isKnown = ABSENT } },
      abilities = { [CHAOS_BOLT] = ABSENT },
    },
  },

  {
    name = "read/a-throwing-struct-read-is-absorbed-like-an-absent-one",
    status = "green",
    spec = 3,
    pins = "A refused call and a returned nothing are the same verdict — we did not learn "
        .. "the row's configuration — and neither may take the pulse down.",
    ref = "cooldown-manager.md §7 Tier 1 + security-taint-and-restricted-data.md",
    rows = { { cid = 903, category = "Essential", frame = {}, infoThrows = true,
               info = { spellID = CHAOS_BOLT, isKnown = true } } },
    expect = { raw = { [903] = { spellID = ABSENT, isKnown = ABSENT } } },
  },

  {
    name = "read/a-SECRET-TABLE-struct-is-refused-whole-never-indexed",
    status = "green",
    spec = 3,
    pins = "A secret TABLE is a distinct verdict from a secret field: it cannot be indexed "
        .. "at all, so the guard has to be asked before any field is touched.",
    ref = "security-taint-and-restricted-data.md + cooldown-manager.md §7 Tier 1",
    rows = { { cid = 903, category = "Essential", frame = {}, infoSecretTable = true,
               info = { spellID = CHAOS_BOLT, isKnown = true } } },
    expect = { raw = { [903] = { spellID = ABSENT, isKnown = ABSENT } } },
  },

  {
    name = "read/isKnown-false-is-the-one-value-that-removes-a-row",
    status = "green",
    spec = 3,
    pins = "characterisation: `isKnown` is a struct field with no consumer in Blizzard's "
        .. "own Lua, so what we do with it is our invention.  We trust it in exactly one "
        .. "direction — an explicit FALSE removes the row, because a phantom ability reads "
        .. "ready forever and wins the priority list.",
    ref = "cooldown-manager.md §7 Tier 1 (the struct's fields) + §8 rule 8",
    rows = { { cid = 903, category = "Essential", frame = {},
               info = { spellID = SOUL_FIRE, isKnown = false } } },
    expect = {
      abilities = { [SOUL_FIRE] = ABSENT },
      dropped   = { [SOUL_FIRE] = "unlearned" },
    },
  },

  {
    name = "read/a-SECRET-isKnown-becomes-an-affirmative-true",
    status = "pinned-defect",
    fixes = "phase2 §3.4",
    spec = 3,
    pins = "A SECRET VALUE IS TRUTHY IN LUA, so `info.isKnown and true or false` turns a "
        .. "refusal into `true` — the row then reads \"the client says you have this "
        .. "talented\" on the strength of a value we could not read.  That is a refusal "
        .. "laundered into an assertion, and it fails in the OVER-SHOW direction: a "
        .. "phantom ability re-enters the rotation, which is the shape field-fix A "
        .. "existed to close.",
    ref = "cooldown-manager.md §7 Tier 1 (struct ids can read secret) + "
       .. "security-taint-and-restricted-data.md",
    rows = { { cid = 903, category = "Essential", frame = {},
               info = { spellID = SOUL_FIRE, isKnown = SECRET } } },
    expect = { raw = { [903] = { isKnown = ABSENT } } },
  },

  {
    name = "read/an-absent-isKnown-on-a-present-struct-becomes-false",
    status = "pinned-defect",
    fixes = "phase2 §3.4",
    spec = 3,
    pins = "The same and/or trap in the other direction, and the more dangerous one: a "
        .. "struct that answers but omits `isKnown` yields FALSE, which is a DROP.  So "
        .. "\"we don't know\" is only reachable when the WHOLE struct is missing — the "
        .. "three-valued fence is really an all-or-nothing struct axis, which is worth "
        .. "knowing before a design is built on the three values.  Fails in the "
        .. "UNDER-SHOW direction: a real button silently disappears.",
    ref = "cooldown-manager.md §7 Tier 1 — the documented struct return",
    rows = { { cid = 903, category = "Essential", frame = {},
               info = { spellID = CHAOS_BOLT } } },
    expect = { raw = { [903] = { isKnown = ABSENT } }, dropped = { [CHAOS_BOLT] = ABSENT } },
  },

  {
    name = "read/a-secret-flags-value-degrades-to-a-marker-never-to-disk",
    status = "green",
    spec = 3,
    pins = "A Secret Value must never reach SavedVariables — serialising one writes "
        .. "garbage at best and taints the writer at worst — so it degrades to the string "
        .. "\"<secret>\", which is itself the finding a reader wants.",
    ref = "security-taint-and-restricted-data.md + cooldown-manager.md §7 Tier 1",
    rows = { { cid = 903, category = "Essential", frame = {},
               info = { spellID = CHAOS_BOLT, isKnown = true, flags = SECRET } } },
    expect = { raw = { [903] = { flags = "<secret>" } } },
  },

  {
    name = "read/a-readable-flags-value-rides-the-pulse-as-itself",
    status = "green",
    spec = 3,
    pins = "The control for the case above: a readable scalar is carried unchanged, so "
        .. "\"<secret>\" is unambiguous when it appears.",
    ref = "cooldown-manager.md §7 Tier 1 — flags is part of the documented struct",
    rows = { { cid = 903, category = "Essential", frame = {},
               info = { spellID = CHAOS_BOLT, isKnown = true, flags = 5 } } },
    expect = { raw = { [903] = { flags = 5 } } },
  },

  {
    name = "read/aura-PRESENCE-not-contents-is-the-signal",
    status = "green",
    spec = 3,
    pins = "The entire AuraData record is secret when restricted, GetPlayerAuraBySpellID "
        .. "included — so the read must never index what it gets back.  A RETURNED table, "
        .. "secret or not, means the buff is up; only a thrown call is unreadable.",
    ref = "cooldown-manager.md §7 Tier 3 — \"The entire AuraData record is secret when "
       .. "restricted … your own auras are as sealed as the target's\"",
    rows = { { cid = 133441, category = "TrackedBuff", frame = {},
               info = { spellID = IMMOLATE_AURA, isKnown = true, hasAura = true } } },
    world = { auraByID = { [IMMOLATE_AURA] = { __secretTable = { spellId = IMMOLATE_AURA } } } },
    expect = {
      raw   = { [133441] = { aura = { readable = true, active = true } } },
      buffs = { [IMMOLATE_AURA] = true },
    },
  },

  {
    name = "read/a-throwing-aura-read-condemns-the-whole-row",
    status = "pinned-defect",
    fixes = "phase2 §3.6",
    spec = 3,
    pins = "`readAura` walks the row's associated ids and returns \"unreadable\" on the "
        .. "FIRST pcall failure — ids 2..n are never asked.  So the row claims the aura "
        .. "space is unreadable on evidence about ONE id, when a later id answers cleanly. "
        .. "It fails in the under-show direction (an aura that is genuinely up reads "
        .. "unknown), which for a DoT line means the refresh press goes quiet.",
    ref = "cooldown-manager.md §2 — rungs 1-3 all draw from the SAME pool, so the ids are "
       .. "alternatives, not a single question asked once",
    rows = { { cid = 164597, category = "Essential", frame = {},
               info = { spellID = IMMOLATE_CAST, isKnown = true, hasAura = true,
                        linkedSpellIDs = { IMMOLATE_AURA } } } },
    world = { auraThrows = { [IMMOLATE_CAST] = true },
              auraByID = { [IMMOLATE_AURA] = { spellId = IMMOLATE_AURA } } },
    expect = { raw = { [164597] = { aura = { readable = true, active = true } } } },
  },

  {
    name = "read/a-partially-secret-aura-space-makes-absence-unknowable",
    status = "green",
    spec = 3,
    pins = "When auras are being hidden this pulse we cannot honestly say a buff is "
        .. "ABSENT — an unconfirmed entry is readable:false, never a false active:false.  "
        .. "Only a fully-readable aura space makes `false` honest.",
    ref = "cooldown-manager.md §7 Tier 3 — C_UnitAuras.Get* fully secret when restricted",
    rows = { { cid = 133441, category = "TrackedBuff", frame = {},
               info = { spellID = IMMOLATE_AURA, isKnown = true, selfAura = true } } },
    world = { auras = { { __secretTable = { spellId = 1, name = "hidden" } } } },
    expect = {
      raw   = { [133441] = { aura = { readable = false, active = ABSENT } } },
      pulse = { activeAuraSecret = 1 },
      buffs = { [IMMOLATE_AURA] = ABSENT },
    },
  },

  {
    name = "read/a-fully-readable-aura-space-makes-a-false-honest",
    status = "green",
    spec = 3,
    pins = "The control for the case above: with every aura readable and none of them "
        .. "ours, `active = false` is a measurement rather than a shrug.",
    ref = "cooldown-manager.md §7 Tier 3 (readable out of combat) + §2.6 (the scan)",
    rows = { { cid = 133441, category = "TrackedBuff", frame = {},
               info = { spellID = IMMOLATE_AURA, isKnown = true, selfAura = true } } },
    world = { auras = { { spellId = 999999, name = "Well Fed" } } },
    expect = {
      raw   = { [133441] = { aura = { readable = true, active = false } } },
      pulse = { activeAuraSecret = 0 },
    },
  },

  {
    name = "read/a-row-with-neither-aura-flag-is-never-asked",
    status = "green",
    spec = 3,
    pins = "characterisation, and §8 rule 8 says so out loud: `hasAura` / `selfAura` have "
        .. "ZERO consumers in Blizzard's Lua — they are DB2 hints the C side reads — so "
        .. "gating an aura read on them is the addon author's own invention.  It is "
        .. "pinned here as behaviour we rely on, not as a claim about the client, and "
        .. "§3.1's family gate is the direction this eventually moves in.",
    ref = "cooldown-manager.md §8 rule 8 + §7 Tier 1 — \"zero consumers in Blizzard's Lua\"",
    rows = { { cid = 903, category = "Essential", frame = {},
               info = { spellID = CHAOS_BOLT, isKnown = true,
                        hasAura = false, selfAura = false } } },
    world = { auraByID = { [CHAOS_BOLT] = { spellId = CHAOS_BOLT } } },
    expect = {
      raw   = { [903] = { aura = { readable = true, active = false } } },
      asked = { auraByID = { [CHAOS_BOLT] = false } },
    },
  },

  {
    name = "read/the-falsified-selfAura-pair-is-still-read",
    status = "green",
    spec = 1,
    pins = "Demonic Core measures selfAura = true with hasAura = FALSE (cooldownID 777), "
        .. "which refuted the rule \"hasAura = false implies a real cooldown\".  The read "
        .. "fires on EITHER flag, or every proc aura is hard-coded inactive — which is "
        .. "exactly what v0.29.0 shipped.",
    ref = "cooldown-manager.md §7 Tier 1 — the [client] Demonic Core measurement",
    rows = { { cid = 777, category = "TrackedBuff", frame = {},
               info = { spellID = DEMONIC_CORE, isKnown = true,
                        selfAura = true, hasAura = false } } },
    world = { auras = { { spellId = DEMONIC_CORE, name = "Demonic Core" } } },
    expect = {
      raw   = { [777] = { aura = { readable = true, active = true } } },
      buffs = { [DEMONIC_CORE] = true },
    },
  },

  {
    name = "read/a-throwing-glow-read-is-unreadable-not-unglowed",
    status = "green",
    spec = 3,
    pins = "The proc glow is the only channel that survives combat, so a refusal has to "
        .. "read as \"we don't know\" — a fabricated false would silently turn the one "
        .. "working proc signal into a permanent negative.",
    ref = "cooldown-manager.md §6 + §7 Tier 3 — IsSpellOverlayed measured readable in combat",
    rows = { { cid = 903, category = "Essential", frame = {},
               info = { spellID = 264178, isKnown = true } } },
    world = { throws = { "C_SpellActivationOverlay.IsSpellOverlayed" } },
    expect = { raw = { [903] = { glow = { readable = false, active = ABSENT } } } },
  },

  {
    name = "read/a-readable-glow-is-carried-as-a-value",
    status = "green",
    spec = 3,
    pins = "The glow lands on the EMPOWERED spell — the one actually pressed — which is "
        .. "more actionable than knowing the enabling buff exists, and the enabling aura's "
        .. "id appears nowhere in the payload.",
    ref = "cooldown-manager.md §6 — the chain leaves the CDM entirely; "
       .. "RefreshOverlayGlow polls IsSpellOverlayed [CooldownViewer.lua:1118-1134]",
    rows = { { cid = 903, category = "Essential", frame = {},
               info = { spellID = 264178, isKnown = true } } },
    world = { glow = { [264178] = true } },
    expect = { raw = { [903] = { glow = { readable = true, active = true } } } },
  },

  {
    name = "read/a-SECRET-glow-answer-is-refused",
    status = "green",
    spec = 3,
    pins = "A secret boolean is still a secret: it must never be coerced into a real one, "
        .. "because comparing or keying on it taints.",
    ref = "security-taint-and-restricted-data.md + cooldown-manager.md §6",
    rows = { { cid = 903, category = "Essential", frame = {},
               info = { spellID = 264178, isKnown = true } } },
    world = { glow = { [264178] = SECRET } },
    expect = { raw = { [903] = { glow = { readable = false, active = ABSENT } } } },
  },

  {
    name = "read/a-refused-availability-probe-enumerates-nothing-at-all",
    status = "green",
    spec = 3,
    pins = "`IsCooldownViewerAvailable` is the gate on the whole database.  A refusal "
        .. "there must yield an empty enumeration rather than a partial one — and every "
        .. "downstream filter has to survive that, because it is also the login state.",
    ref = "cooldown-manager.md §7 Tier 1 — IsCooldownViewerAvailable; §4 (nothing is "
       .. "registered while a viewer is hidden)",
    rows = { { cid = 903, category = "Essential", frame = {},
               info = { spellID = CHAOS_BOLT, isKnown = true } } },
    world = { throws = { "C_CooldownViewer.IsCooldownViewerAvailable" } },
    expectsEmptyEnumeration = true,
    expect = {
      raw       = { [903] = ABSENT },
      abilities = { [CHAOS_BOLT] = ABSENT },
      asked     = { info = { [903] = false } },
    },
  },

  {
    name = "read/the-cooldown-viewer-reporting-itself-unavailable-is-not-an-error",
    status = "green",
    spec = 3,
    pins = "The same shape without a throw: the client simply says the feature is off.  "
        .. "An empty database is a legal state, never a reason to fabricate rows.",
    ref = "cooldown-manager.md §7 Tier 1 — IsCooldownViewerAvailable",
    rows = { { cid = 903, category = "Essential", frame = {},
               info = { spellID = CHAOS_BOLT, isKnown = true } } },
    world = { cdmUnavailable = true },
    expectsEmptyEnumeration = true,
    expect = { raw = { [903] = ABSENT }, abilities = { [CHAOS_BOLT] = ABSENT } },
  },

  {
    name = "read/a-cooldown-table-that-throws-on-INDEX-yields-nil",
    status = "green",
    spec = 3,
    pins = "The guards are three DIFFERENT failures in order: the call itself, then a "
        .. "secret table (cannot be indexed at all), then secret fields on a readable "
        .. "table.  A table clearing the first two can still raise on access, so the "
        .. "index is itself pcall'd — and this case is what makes that guard falsifiable.",
    ref = "security-taint-and-restricted-data.md — restricted-data access under 12.0; "
       .. "cooldown-manager.md §7 Tier 2 (the values inherit GetSpellCooldown's secrecy)",
    rows = { { cid = 903, category = "Essential", frame = {},
               info = { spellID = CHAOS_BOLT, isKnown = true } } },
    world = { now = 1000, cd = {
      [CHAOS_BOLT] = { __poison = { fields = { duration = 120, startTime = 900 },
                                    raises = { "startTime" } } },
      [GCD] = READY_GCD } },
    expect = {
      abilities = { [CHAOS_BOLT] = { cd = { state = "unknown", source = "none" } } },
    },
  },

  {
    name = "read/a-SECRET-duration-on-a-readable-table-is-still-refused",
    status = "green",
    spec = 3,
    pins = "`cooldownStartTime` / `cooldownDuration` are copied straight from "
        .. "GetSpellCooldown, so they inherit its secrecy field by field — a readable "
        .. "table is not a readable row.",
    ref = "cooldown-manager.md §7 Tier 2 — item.cooldownStartTime / cooldownDuration",
    rows = { { cid = 903, category = "Essential", frame = {},
               info = { spellID = CHAOS_BOLT, isKnown = true } } },
    world = { now = 1000, cd = { [CHAOS_BOLT] = { duration = SECRET, startTime = 900 },
                                 [GCD] = READY_GCD } },
    expect = {
      abilities = { [CHAOS_BOLT] = { cd = { state = "unknown", source = "none" } } },
    },
  },

  {
    name = "read/a-SECRET-TABLE-charges-read-yields-no-count",
    status = "green",
    spec = 3,
    pins = "The charges table gets the same three-guard ladder as the cooldown table, for "
        .. "the same reason — and a refused count must not collapse into \"no charges\", "
        .. "which is the shape a never-seeded napkin already has.",
    ref = "cooldown-manager.md §7 Tier 3 — GetSpellCharges readable OUT of combat, "
       .. "secret IN",
    rows = { { cid = 903, category = "Essential", frame = {},
               info = { spellID = CONFLAGRATE, isKnown = true, charges = true } } },
    world = { charges = { [CONFLAGRATE] =
      { __secretTable = { currentCharges = 2, maxCharges = 2 } } } },
    expect = { raw = { [903] = { charge = { readable = false, charged = ABSENT,
                                            cur = ABSENT } } } },
  },

  {
    name = "read/isKnown-is-bare-indexed-on-a-struct-that-can-raise",
    status = "pinned-defect",
    fixes = "phase2 §3.9",
    spec = 3,
    pins = "State pcalls the CALL and checks IsSecretTable, then stops — `St.Build` "
        .. "bare-indexes info.spellID / overrideSpellID / overrideTooltipSpellID / "
        .. "hasAura / selfAura / charges / isKnown / linkedSpellIDs outside any pcall.  "
        .. "Meanwhile `rawCooldown` pcalls the equivalent field access on a table that "
        .. "passed the SAME two checks, commenting that one can still throw on access.  "
        .. "Either that claim is true and this loop is a live crash path, or the other "
        .. "guard is superstition — both cannot hold, and nothing pins which.",
    ref = "security-taint-and-restricted-data.md — restricted-data field access under "
       .. "12.0; cooldown-manager.md §7 Tier 1",
    rows = { { cid = 903, category = "Essential", frame = {}, infoPoison = { "isKnown" },
               info = { spellID = CHAOS_BOLT, isKnown = true } } },
    expect = { raw = { [903] = { spellID = CHAOS_BOLT, isKnown = ABSENT } } },
  },

  {
    name = "read/hasAura-is-bare-indexed-on-a-struct-that-can-raise",
    status = "pinned-defect",
    fixes = "phase2 §3.9",
    spec = 3,
    pins = "The same contradiction at a second field, so the finding cannot be dismissed "
        .. "as one unlucky line.  If H.poison makes St.Build throw here too, the crash "
        .. "path is structural rather than incidental.",
    ref = "security-taint-and-restricted-data.md — restricted-data field access under "
       .. "12.0; cooldown-manager.md §7 Tier 1",
    rows = { { cid = 903, category = "Essential", frame = {}, infoPoison = { "hasAura" },
               info = { spellID = CHAOS_BOLT, isKnown = true, hasAura = true } } },
    expect = { raw = { [903] = { spellID = CHAOS_BOLT, hasAura = ABSENT } } },
  },
}

--------------------------------------------------------------------------------
return {
  ABSENT = ABSENT,
  SECRET = SECRET,
  groups = {
    { name = "A · family — tab 1 presses, tab 2 runs",        cases = A },
    { name = "B · identity — five rungs, one pool",           cases = B },
    { name = "C · combat + the value cascade",                cases = C },
    { name = "D · per-field readability — value/secret/absent/throws", cases = D },
    { name = "G · drawability + the buff item",               cases = G },
  },
}
