-- state_domainview_spec.lua — State's DOMAIN VIEW: the pressable filter (field-fix A), the
-- aura-lifecycle latch (C) and the charge napkin (C2).
--
-- WHY THIS FILE EXISTS.  The first live session proved `state.abilities` was NOT what its
-- own contract says it is.  State anchors on the CDM database with `allowUnlearned = true`,
-- so the fold promoted rows for spells the character has not talented and rows the Layout
-- can never draw; both read `ready` forever, so they won the priority list every GCD.  One
-- session logged **216 dropped Soul Fire cues** from an untalented Soul Fire outranking the
-- whole rotation.  The fix removes rows — which is exactly the kind of change that can
-- silently delete a REAL button, so the tests below pin both directions: the phantom is
-- gone, AND the survivor is still there, AND the drop was reported.
--
-- It loads the REAL State.lua and stubs only what genuinely needs a live client (the
-- C_CooldownViewer database and frame discovery) — the `viewers_spec` doctrine: a stub
-- proves the caller works GIVEN the collaborator, never that the collaborator exists.
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local H = dofile(dir .. "../mock_ns.lua")

-- Real Destruction ids, so a drop reads as the ability it actually is.
local SOUL_FIRE   = 6353
local INCINERATE  = 29722
local CHAOS_BOLT  = 116858
local CONFLAGRATE = 17962
local IMMOLATE_AURA = 157736   -- cid 133441, the BuffBar row
local IMMOLATE_CAST = 348      -- cid 164597, the Essential row

--------------------------------------------------------------------------------
-- A raw CDM row, shaped exactly as St.Build emits one into `cooldowns`.
--------------------------------------------------------------------------------
local function row(cid, base, opts)
  opts = opts or {}
  return {
    cooldownID = cid,
    category   = opts.category or "Essential",
    spellID    = base,
    liveSpellID = opts.live or base,
    isKnown    = opts.isKnown,           -- nil = unreadable, and NOT a drop
    displayable = opts.displayable ~= false,
    cd = opts.cd or { state = "unknown", readable = false, source = "none" },
    charge = opts.charge,
    aura = opts.aura,
    glow = { active = false, readable = true },
  }
end

--------------------------------------------------------------------------------
describe("State domain view — the pressable filter (field-fix A)", function()
  local ns, St
  before_each(function()
    ns = H.fresh()
    H.load("State.lua")
    St = ns.State
  end)

  ------------------------------------------------------------------------------
  describe("St.DomainView (pure)", function()
    it("keeps a known, displayable row", function()
      local abilities, dropped = St.DomainView({ [901] = row(901, CHAOS_BOLT) }, nil, true, nil)
      assert.is_not_nil(abilities[CHAOS_BOLT])
      assert.equals(901, abilities[CHAOS_BOLT].display.cooldownID)
      assert.is_nil(dropped[CHAOS_BOLT])
    end)

    it("an UNLEARNED row never reaches abilities, and says so", function()
      local abilities, dropped = St.DomainView(
        { [902] = row(902, SOUL_FIRE, { isKnown = false }) }, nil, true, nil)
      assert.is_nil(abilities[SOUL_FIRE])
      assert.equals("unlearned", dropped[SOUL_FIRE])
    end)

    it("an UNDISPLAYABLE row never reaches abilities, and says so", function()
      -- Incinerate: known, talented, pressed constantly — and absent from the live CDM set,
      -- so there is no frame to anchor a cue to.  `isKnown` alone cannot catch this.
      local abilities, dropped = St.DomainView(
        { [903] = row(903, INCINERATE, { isKnown = true, displayable = false }) }, nil, true, nil)
      assert.is_nil(abilities[INCINERATE])
      assert.equals("no-icon", dropped[INCINERATE])
    end)

    it("an UNREADABLE isKnown is not a drop — absence of a read is not evidence", function()
      local abilities, dropped = St.DomainView(
        { [904] = row(904, CHAOS_BOLT, { isKnown = nil }) }, nil, true, nil)
      assert.is_not_nil(abilities[CHAOS_BOLT])
      assert.is_nil(dropped[CHAOS_BOLT])
    end)

    it("SKIPS the displayable filter entirely when no frame map exists", function()
      -- The v0.32.25 outage shape: an empty frame map must never mean "nothing is drawable".
      local abilities, dropped = St.DomainView(
        { [905] = row(905, INCINERATE, { isKnown = true, displayable = false }) },
        nil, false --[[ no frame map ]], nil)
      assert.is_not_nil(abilities[INCINERATE])
      assert.is_nil(dropped[INCINERATE])
    end)

    it("still drops an unlearned row when the frame map is absent (isKnown is independent)", function()
      local abilities, dropped = St.DomainView(
        { [906] = row(906, SOUL_FIRE, { isKnown = false }) }, nil, false, nil)
      assert.is_nil(abilities[SOUL_FIRE])
      assert.equals("unlearned", dropped[SOUL_FIRE])
    end)

    it("keeps the ability when only ONE of its rows is filtered", function()
      local abilities, dropped = St.DomainView({
        [907] = row(907, CHAOS_BOLT, { isKnown = true, displayable = false }),
        [908] = row(908, CHAOS_BOLT, { isKnown = true, category = "Utility" }),
      }, nil, true, nil)
      assert.is_not_nil(abilities[CHAOS_BOLT])
      assert.equals(908, abilities[CHAOS_BOLT].display.cooldownID)
      assert.is_nil(dropped[CHAOS_BOLT])
    end)

    it("does NOT report a tracked-only row as dropped (it was never a press)", function()
      -- A BuffBar/TrackedBuff row has no pressable member by construction — the pre-existing
      -- exclusion, not a filter drop.  Reporting it would drown the real signal.
      local abilities, dropped = St.DomainView(
        { [909] = row(909, IMMOLATE_AURA, { category = "TrackedBuff", displayable = false }) },
        nil, true, nil)
      assert.is_nil(abilities[IMMOLATE_AURA])
      assert.is_nil(dropped[IMMOLATE_AURA])
    end)

    it("folds by the OOC-cached base when a combat row's spellID is unreadable", function()
      local r = row(910, nil)
      r.spellID = nil
      local abilities = St.DomainView({ [910] = r }, { [910] = CONFLAGRATE }, true, nil)
      assert.is_not_nil(abilities[CONFLAGRATE])
    end)
  end)

  ------------------------------------------------------------------------------
  -- The live path: a REAL St.Build against a faked CDM database + viewers.
  ------------------------------------------------------------------------------
  describe("St.Build end to end", function()
    local CID = { sf = 901, inc = 902, cb = 903 }

    before_each(function()
      _G.Enum.CooldownViewerCategory = { Essential = 0, Utility = 1 }
      _G.C_CooldownViewer = {
        GetCooldownViewerCategorySet = function(value)
          if value == 0 then return { CID.sf, CID.inc, CID.cb } end
          return {}
        end,
        GetCooldownViewerCooldownInfo = function(cid)
          if cid == CID.sf  then return { spellID = SOUL_FIRE,  isKnown = false } end
          if cid == CID.inc then return { spellID = INCINERATE, isKnown = true } end
          if cid == CID.cb  then return { spellID = CHAOS_BOLT, isKnown = true } end
        end,
      }
      -- Frame discovery: Chaos Bolt has an icon, Incinerate does not.
      ns.VIEWERS = { { frame = "EssentialCooldownViewer" } }
      local items = { { cooldownID = CID.sf }, { cooldownID = CID.cb } }
      ns.GetViewer     = function(name) return name == "EssentialCooldownViewer" and { n = 1 } or nil end
      ns.GetItemFrames = function() return items end
      ns.OnLogin()   -- builds the category/power name caches
    end)

    after_each(function()
      _G.C_CooldownViewer = nil
      _G.Enum.CooldownViewerCategory = nil
    end)

    it("the RAW cooldowns view still holds every row — it is the diagnostic view", function()
      local pulse = St.Build(false)
      assert.is_not_nil(pulse.cooldowns[CID.sf])
      assert.is_not_nil(pulse.cooldowns[CID.inc])
      assert.is_not_nil(pulse.cooldowns[CID.cb])
      assert.is_false(pulse.cooldowns[CID.inc].displayable)
      assert.is_true(pulse.cooldowns[CID.cb].displayable)
    end)

    it("abilities carries ONLY the row that is both known and drawable", function()
      local pulse = St.Build(false)
      assert.is_nil(pulse.abilities[SOUL_FIRE])    -- unlearned
      assert.is_nil(pulse.abilities[INCINERATE])   -- no CDM icon
      assert.is_not_nil(pulse.abilities[CHAOS_BOLT])
    end)

    it("reports both drops on the pulse, with their reasons", function()
      local pulse = St.Build(false)
      assert.equals("unlearned", pulse.dropped[SOUL_FIRE])
      assert.equals("no-icon", pulse.dropped[INCINERATE])
      assert.is_nil(pulse.dropped[CHAOS_BOLT])
    end)

    it("NO viewers at all ⇒ Build does not filter on displayability", function()
      -- The guard with the largest blast radius, asserted where it is actually DECIDED (a
      -- pure-function test of the flag proves nothing about how Build computes it).  Viewers
      -- absent — login, CDM off, a relayout mid-pulse — must never empty `abilities`, which
      -- is precisely the shape of the v0.32.25 total outage.
      ns.GetItemFrames = function() return {} end
      local pulse = St.Build(false)
      assert.is_not_nil(pulse.abilities[INCINERATE])
      assert.is_not_nil(pulse.abilities[CHAOS_BOLT])
      assert.is_nil(pulse.dropped[INCINERATE])
      assert.is_nil(pulse.abilities[SOUL_FIRE])       -- isKnown is independent of the map
    end)
  end)

  ------------------------------------------------------------------------------
  -- The point of the whole phase: the ROTATION falls through instead of vanishing.
  ------------------------------------------------------------------------------
  describe("the Coach falls through to the next line", function()
    local Coach
    local NOW = 1000
    local function cdReady() return { state = "ready", readable = true, source = "live",
                                      changedAt = NOW - 2 } end

    before_each(function()
      H.setSpecIndex(3)          -- Destruction
      ns.ResolveActiveSpec()
      H.load("Coach.lua")
      Coach = ns.Coach.New()
    end)

    -- A pulse whose `abilities` came through the REAL fold, so the filter is in the path.
    local function pulseFrom(cooldowns)
      local abilities, dropped = St.DomainView(cooldowns, nil, true, nil)
      return {
        at = NOW, combat = true, combatStartedAt = NOW - 60, mode = "st",
        power = { SoulShards = { value = 3, incoming = 0, max = 5, readable = true } },
        buffs = {}, history = {}, abilities = abilities, dropped = dropped,
      }
    end

    local function press(g)
      for spellID, cue in pairs(g.cues) do
        if cue.emphasis == "ROTATION" or cue.emphasis == "LATE" then return spellID end
      end
    end

    it("an UNLEARNED Soul Fire does not win — Conflagrate does", function()
      -- The live bug in miniature: untalented Soul Fire reads `ready` forever, so before the
      -- filter it took L2 every single GCD and the cue was then dropped by the Binder.
      local g = Coach:Compute(pulseFrom({
        [901] = row(901, SOUL_FIRE, { isKnown = false, cd = cdReady() }),
        [902] = row(902, CONFLAGRATE, { isKnown = true, cd = cdReady() }),
        [903] = row(903, CHAOS_BOLT, { isKnown = true }),
      }))
      assert.equals(CONFLAGRATE, press(g))
    end)

    it("a TALENTED Soul Fire still wins L2 — the filter removes phantoms, not presses", function()
      local g = Coach:Compute(pulseFrom({
        [901] = row(901, SOUL_FIRE, { isKnown = true, cd = cdReady() }),
        [902] = row(902, CONFLAGRATE, { isKnown = true, cd = cdReady() }),
        [903] = row(903, CHAOS_BOLT, { isKnown = true }),
      }))
      assert.equals(SOUL_FIRE, press(g))
    end)

    it("an UNDISPLAYABLE Soul Fire does not win either", function()
      local g = Coach:Compute(pulseFrom({
        [901] = row(901, SOUL_FIRE, { isKnown = true, displayable = false, cd = cdReady() }),
        [902] = row(902, CONFLAGRATE, { isKnown = true, cd = cdReady() }),
        [903] = row(903, CHAOS_BOLT, { isKnown = true }),
      }))
      assert.equals(CONFLAGRATE, press(g))
    end)
  end)
end)

--------------------------------------------------------------------------------
describe("State aura-lifecycle latch (field-fix C)", function()
  local ns, St, A
  local IMM_AURA_CID, IMM_CAST_CID = 133441, 164597

  before_each(function()
    ns = H.fresh()
    H.load("State.lua")
    St = ns.State
    St.Acquire()                 -- the latch is gated on a live consumer, like readyEdge
    A = _G.Enum.CooldownViewerAlertEventType
  end)
  after_each(function() St.Release() end)

  local function alert(cid, event) St.OnAlert({ cooldownID = cid }, event) end

  it("PandemicTime latches the refresh window", function()
    alert(IMM_CAST_CID, A.PandemicTime)
    assert.equals("pandemic", St.dotEdge[IMM_CAST_CID].state)
  end)

  it("OnAuraRemoved clears it to absent", function()
    alert(IMM_CAST_CID, A.PandemicTime)
    alert(IMM_CAST_CID, A.OnAuraRemoved)
    assert.equals("absent", St.dotEdge[IMM_CAST_CID].state)
  end)

  it("OnAuraApplied clears it to fresh", function()
    alert(IMM_CAST_CID, A.PandemicTime)
    alert(IMM_CAST_CID, A.OnAuraApplied)
    assert.equals("fresh", St.dotEdge[IMM_CAST_CID].state)
  end)

  -- ⚠ FROM THE FIELD (2026-07-30).  A DoT REFRESH raises OnAuraRemoved AND OnAuraApplied
  -- with the IDENTICAL timestamp — the live capture has both on cid 133441 and 164597 at
  -- 131184.611.  Last-write-wins would let Blizzard's dispatch ORDER decide whether the HUD
  -- thinks the DoT is up or gone.  A re-application supersedes the removal it replaces.
  describe("a same-frame refresh (removed + applied at one timestamp)", function()
    it("resolves to fresh when applied arrives LAST", function()
      alert(IMM_CAST_CID, A.OnAuraRemoved)
      alert(IMM_CAST_CID, A.OnAuraApplied)
      assert.equals("fresh", St.dotEdge[IMM_CAST_CID].state)
    end)

    it("resolves to fresh when applied arrives FIRST, too", function()
      alert(IMM_CAST_CID, A.OnAuraApplied)
      alert(IMM_CAST_CID, A.OnAuraRemoved)   -- must NOT clobber the re-application
      assert.equals("fresh", St.dotEdge[IMM_CAST_CID].state)
    end)

    it("a removal in a LATER frame still clears it — the DoT really did fall off", function()
      alert(IMM_CAST_CID, A.OnAuraApplied)
      H.advance(0.1)
      alert(IMM_CAST_CID, A.OnAuraRemoved)
      assert.equals("absent", St.dotEdge[IMM_CAST_CID].state)
    end)
  end)

  it("ignores the alert while no consumer holds ingestion", function()
    St.Release()
    alert(IMM_CAST_CID, A.PandemicTime)
    assert.is_nil(St.dotEdge[IMM_CAST_CID])
    St.Acquire()
  end)

  -- ⚠ THE TWO-COOLDOWNID CASE.  Immolate occupies cid 133441 (spellID 157736, the DoT aura,
  -- on the Buff-bar viewer) AND cid 164597 (spellID 348, the cast, on Essential), and BOTH
  -- raised PandemicTime in the live capture.  Either must resolve to ONE answer per base.
  describe("resolved to base spellIDs by the fold", function()
    local function rows()
      return {
        [IMM_AURA_CID] = row(IMM_AURA_CID, IMMOLATE_AURA, { category = "TrackedBuff" }),
        [IMM_CAST_CID] = row(IMM_CAST_CID, IMMOLATE_CAST, { category = "Essential" }),
      }
    end

    it("either cooldownID's latch surfaces under its own base spellID", function()
      alert(IMM_AURA_CID, A.PandemicTime)
      local _, _, edges = St.DomainView(rows(), nil, true, St.dotEdge)
      assert.equals("pandemic", edges[IMMOLATE_AURA].state)

      H.advance(1)
      alert(IMM_CAST_CID, A.PandemicTime)
      local _, _, edges2 = St.DomainView(rows(), nil, true, St.dotEdge)
      assert.equals("pandemic", edges2[IMMOLATE_CAST].state)
    end)

    it("rides the pressable row so the brain never sees a cooldownID", function()
      alert(IMM_CAST_CID, A.PandemicTime)
      local abilities = St.DomainView(rows(), nil, true, St.dotEdge)
      assert.equals("pandemic", abilities[IMMOLATE_CAST].dot.state)
    end)

    it("the NEWEST edge wins when both of an ability's rows have latched", function()
      -- Two rows of ONE base id: the fold must not let a stale latch beat a fresh one.
      local twoRows = {
        [770] = row(770, CONFLAGRATE, { category = "TrackedBuff" }),
        [771] = row(771, CONFLAGRATE, { category = "Essential" }),
      }
      alert(770, A.PandemicTime)
      H.advance(5)
      alert(771, A.OnAuraRemoved)
      local _, _, edges = St.DomainView(twoRows, nil, true, St.dotEdge)
      assert.equals("absent", edges[CONFLAGRATE].state)
    end)

    it("no alert seen ⇒ no latch, and the brain stays silent", function()
      local abilities, _, edges = St.DomainView(rows(), nil, true, St.dotEdge)
      assert.is_nil(edges[IMMOLATE_CAST])
      assert.is_nil(abilities[IMMOLATE_CAST].dot)
    end)
  end)
end)

--------------------------------------------------------------------------------
describe("State charge napkin (field-fix C2)", function()
  local ns, St, A
  local CONF_CID = 671

  before_each(function()
    ns = H.fresh()
    H.load("State.lua")
    St = ns.State
    St.Charges.Reset()
    St.Acquire()
    A = _G.Enum.CooldownViewerAlertEventType
  end)
  after_each(function() St.Release() end)

  it("reads nothing before it has been seeded", function()
    assert.is_nil(St.Charges.Read(CONF_CID))
  end)

  it("seeds exactly from an OOC read", function()
    St.Charges.Seed(CONF_CID, 2, 2)
    local cur, max = St.Charges.Read(CONF_CID)
    assert.equals(2, cur); assert.equals(2, max)
  end)

  it("decrements on a cast that landed", function()
    St.Charges.Seed(CONF_CID, 2, 2)
    St.Charges.Bind(17962, CONF_CID)
    St.Charges.Spend(17962)
    assert.equals(1, (St.Charges.Read(CONF_CID)))
  end)

  it("increments on the ChargeGained alert", function()
    St.Charges.Seed(CONF_CID, 0, 2)
    St.OnAlert({ cooldownID = CONF_CID }, A.ChargeGained)
    assert.equals(1, (St.Charges.Read(CONF_CID)))
  end)

  it("clamps at max — a gain past the cap cannot invent a charge", function()
    St.Charges.Seed(CONF_CID, 2, 2)
    St.OnAlert({ cooldownID = CONF_CID }, A.ChargeGained)
    assert.equals(2, (St.Charges.Read(CONF_CID)))
  end)

  it("clamps at zero — the undercount direction, never a negative", function()
    St.Charges.Seed(CONF_CID, 0, 2)
    St.Charges.Bind(17962, CONF_CID)
    St.Charges.Spend(17962)
    St.Charges.Spend(17962)
    assert.equals(0, (St.Charges.Read(CONF_CID)))
  end)

  it("ignores a spend for an ability it has no seed for", function()
    St.Charges.Bind(17962, CONF_CID)
    St.Charges.Spend(17962)
    assert.is_nil(St.Charges.Read(CONF_CID))
  end)

  it("an exact OOC re-read overrides a drifted estimate", function()
    St.Charges.Seed(CONF_CID, 2, 2)
    St.Charges.Bind(17962, CONF_CID)
    St.Charges.Spend(17962); St.Charges.Spend(17962)
    assert.equals(0, (St.Charges.Read(CONF_CID)))
    St.Charges.Seed(CONF_CID, 2, 2)          -- combat ended, the client answers again
    assert.equals(2, (St.Charges.Read(CONF_CID)))
  end)

  it("the full loop: seed, press, press, recharge, recharge", function()
    St.Charges.Bind(17962, CONF_CID)
    St.Charges.Seed(CONF_CID, 2, 2)
    St.Charges.Spend(17962);                                   assert.equals(1, (St.Charges.Read(CONF_CID)))
    St.Charges.Spend(17962);                                   assert.equals(0, (St.Charges.Read(CONF_CID)))
    St.OnAlert({ cooldownID = CONF_CID }, A.ChargeGained);     assert.equals(1, (St.Charges.Read(CONF_CID)))
    St.OnAlert({ cooldownID = CONF_CID }, A.ChargeGained);     assert.equals(2, (St.Charges.Read(CONF_CID)))
  end)

  it("a UNIT_SPELLCAST_SUCCEEDED event debits through the real handler", function()
    -- Not the seam: the shipped event handler, so the wiring itself is under test.
    St.Charges.Bind(17962, CONF_CID)
    St.Charges.Seed(CONF_CID, 2, 2)
    local eframe = H.lastFrame()
    eframe:Fire("OnEvent", "UNIT_SPELLCAST_SUCCEEDED", "player", "cast-1", 17962)
    assert.equals(1, (St.Charges.Read(CONF_CID)))
  end)
end)
