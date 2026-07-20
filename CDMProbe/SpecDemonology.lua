-- SpecDemonology.lua — the per-spec data table (v1 target: Demonology Warlock).
--
-- ONE table, ONE edit site.  Every Hud* render module reads identity/role/yield
-- from here and holds no spell constants of its own, so adding a second spec
-- (M7) means adding a sibling file, not touching the renderers.
--
-- Fields per spellID:
--   group   — the §3 colour group (hue carries GROUP, never per-ability identity)
--   role    — "builder" | "spender" | "burst" | "utility" | "proc"
--             drives the generator-vs-consumer BATCH TINT (guidance-model §0.5.8.4)
--   ghost   — deterministic Soul Shard yield of an in-flight cast (M3c #7)
--   baseCD  — napkin-timer base cooldown in seconds (M4 #11/#12).  Only filled in
--             where the docs actually assert it; nil elsewhere on purpose — M4
--             reads GetSpellBaseCooldown at runtime and this is the sanity check,
--             not a guess.
--   label   — human name, for /cdmp hud status only (never rendered on the icon:
--             the 4-letter labels were dropped by the 2026-07-19 aesthetic revision)
--
-- Unknown spellIDs fall back to the neutral accent — never crash, never guess.
local ADDON, ns = ...

-- Group hues.  These are the exact triples tuned in Resource.lua:12-27; do not
-- re-pick them.  spec.md §3: summon = fel green, core shadow = violet, fel
-- explosion = lime, proc/resource = cyan, defensive = blue, CC = slate,
-- mobility = gold.
ns.SpecGroups = {
  summon  = { 0.216, 0.784, 0.435 }, -- fel green     — demon summons / burst
  core    = { 0.627, 0.396, 1.000 }, -- shadow violet — core shadow damage
  aoe     = { 0.741, 0.953, 0.227 }, -- fel lime      — Implosion
  proc    = { 0.176, 0.831, 0.933 }, -- arcane cyan   — procs / resource accent
  def     = { 0.290, 0.620, 1.000 }, -- blue          — defensives
  cc      = { 0.541, 0.580, 0.671 }, -- slate         — control
  mob     = { 0.961, 0.773, 0.259 }, -- gold          — mobility
  neutral = { 0.360, 0.340, 0.420 }, -- unknown / outside our opinionated set
}

-- Named IDs the render modules reference by name rather than by literal.
ns.SpecIDs = {
  TYRANT        = 265187,
  DREADSTALKERS = 104316,
  HAND_OF_GULDAN = 105174,
  DEMONBOLT     = 264178,
  SHADOW_BOLT   = 686,
  IMPLOSION     = 196277,
  -- Buff viewers (M3b proc presence via item:IsShown()):
  DEMONIC_CORE   = 264173,   -- BuffBar
  DIABOLIC_RITUAL = 428514,  -- BuffIcon — the Demonic Art container
  WILD_IMP       = 296553,   -- BuffIcon — M5 #17 stack text
  DOMINION       = 1276166,  -- BuffBar
}

local S = ns.SpecIDs

ns.Spec = {
  -- ── Essential: the burst summons (§3 "summon" / fel green) ────────────────
  [S.TYRANT]        = { group = "summon", role = "burst",   baseCD = 60,  label = "Summon Demonic Tyrant" },
  [S.DREADSTALKERS] = { group = "summon", role = "burst",   baseCD = 20,  label = "Call Dreadstalkers" },
  [1276467]         = { group = "summon", role = "burst",   baseCD = 120, label = "Grimoire: Fel Ravager" },
  [136726]          = { group = "summon", role = "burst",   baseCD = 120, label = "Grimoire: Imp Lord" },

  -- ── Essential: core shadow damage (§3 "core" / shadow violet) ─────────────
  -- HoG is the spender the whole shard economy points at; Demonbolt/Shadow Bolt
  -- are builders and carry a ghost yield (guidance-model §0.5.8.2(b)).
  [S.HAND_OF_GULDAN] = { group = "core", role = "spender", label = "Hand of Gul'dan" },
  [S.DEMONBOLT]      = { group = "core", role = "builder", ghost = 2, label = "Demonbolt" },
  [S.SHADOW_BOLT]    = { group = "core", role = "builder", ghost = 1, label = "Shadow Bolt" },

  -- Demonic Art transforms.  Two IDs are in circulation for each in the maxroll
  -- captures (433891/434506 Infernal Bolt, 434635/434636 Ruination) and we have
  -- not disambiguated them against game data — both are mapped to the same entry
  -- so whichever the client hands us resolves correctly.  Harmless if one is dead.
  [433891] = { group = "core", role = "builder", ghost = 3, label = "Infernal Bolt" },
  [434506] = { group = "core", role = "builder", ghost = 3, label = "Infernal Bolt" },
  [434635] = { group = "core", role = "spender", label = "Ruination" },
  [434636] = { group = "core", role = "spender", label = "Ruination" },

  -- ── Essential: the fel explosion (§3 "aoe" / lime) ────────────────────────
  [S.IMPLOSION] = { group = "aoe", role = "spender", baseCD = 15, label = "Implosion" },

  -- ── Utility: defensives / CC / mobility ───────────────────────────────────
  [104773]  = { group = "def", role = "utility", label = "Unending Resolve" },
  [108416]  = { group = "def", role = "utility", label = "Dark Pact" },
  [30283]   = { group = "cc",  role = "utility", label = "Shadowfury" },
  [119914]  = { group = "cc",  role = "utility", label = "Axe Toss" },
  [6789]    = { group = "cc",  role = "utility", label = "Mortal Coil" },
  [1271802] = { group = "cc",  role = "utility", label = "Blight of Tongues" },
  [48020]   = { group = "mob", role = "utility", label = "Demonic Circle: Teleport" },

  -- ── Buff viewers (no chrome in M3a; M3b reads their IsShown presence) ─────
  [S.DEMONIC_CORE]    = { group = "proc", role = "proc", label = "Demonic Core" },
  [S.DIABOLIC_RITUAL] = { group = "proc", role = "proc", label = "Diabolic Ritual" },
  [S.WILD_IMP]        = { group = "summon", role = "proc", label = "Wild Imp" },
  [S.DOMINION]        = { group = "core", role = "proc", label = "Dominion of Argus" },
}

-- Lookup helpers ---------------------------------------------------------------

local NEUTRAL = { group = "neutral", role = "utility" }

-- Never nil, never errors: unknown IDs get the neutral accent.
-- A Secret Value must never be used as a table key (indexing with one taints),
-- so it is treated exactly like an unresolved ID — neutral, no guess.
function ns.SpecInfo(spellID)
  if type(spellID) ~= "number" or ns.IsSecret(spellID) then return NEUTRAL, false end
  local e = ns.Spec[spellID]
  if e then return e, true end
  return NEUTRAL, false
end

-- r, g, b for a spellID's group hue.
function ns.SpecColor(spellID)
  local info = ns.SpecInfo(spellID)
  local c = ns.SpecGroups[info.group] or ns.SpecGroups.neutral
  return c[1], c[2], c[3]
end

-- Deterministic shard yield of an in-flight cast (M3c anticipation layer).
function ns.SpecGhost(spellID)
  return (ns.SpecInfo(spellID).ghost) or 0
end
