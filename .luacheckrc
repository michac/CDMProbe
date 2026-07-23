-- .luacheckrc — static-analysis config for CDMProbe (M4.5 T1).
--
-- The rung above the release flow's luaparser SYNTAX gate: luacheck catches
-- undefined globals, dead locals, shadowing and typos that parse fine but are
-- bugs.  Run locally / in the release flow with:
--
--     luacheck CDMProbe/
--
-- (needs `luarocks install --local luacheck` + ~/.luarocks/bin on PATH).
--
-- DOCTRINE (m4.5-plan.md T1): curate the config, do NOT inline-suppress.  A real
-- catch (undefined global, dead local, shadow) gets FIXED; a WoW API name the
-- addon legitimately calls goes in the `read_globals` std below.  The signal is
-- only as good as this list is honest — every name here is one the addon actually
-- uses, grepped from the source, not a blanket allow.

std = "lua51+wow"

-- The WoW client runs Lua 5.1, so start from that and layer the Blizzard API on
-- top as a named std.  Keeping it a std (not a bare read_globals) means the
-- per-path `tests/` override can compose it with `+busted` cleanly.
stds.wow = {
  read_globals = {
    -- Core client API the addon calls (grepped from CDMProbe/*.lua) ------------
    "CreateFrame", "hooksecurefunc", "GetTime", "InCombatLockdown",
    "UIParent", "CopyTable", "wipe", "issecretvalue", "issecrettable",
    "canaccessvalue", "GetSpellBaseCooldown", "CreateColor",
    -- M4.6 §4.6 — the centre-screen "BURST COMING" call-out.
    "RaidNotice_AddMessage", "RaidWarningFrame", "ChatTypeInfo",
    "DEFAULT_CHAT_FRAME", "GetMacroSpell", "GetMacroInfo",
    "GetBindingKey", "GetBindingText", "SecureButton_GetModifiedAttribute",
    "GetCVar", "GetCVarBool", "InterfaceOptions_AddCategory",
    "STANDARD_TEXT_FONT", "SOUNDKIT", "PlaySound", "date",
    "IsInInstance", "IsPlayerSpell", "IsSpellKnown", "GetBuildInfo",
    -- Power / unit reads -------------------------------------------------------
    "UnitPower", "UnitPowerMax", "UnitExists", "UnitGUID", "UnitClass",
    "GetSpecialization", "GetSpecializationInfo",
    -- Action-bar scan (HudBinds) ----------------------------------------------
    "HasAction", "GetActionInfo", "GetActionText",
    -- C_ namespaces the addon uses (functions accessed via these tables) -------
    "C_AddOns", "C_CooldownViewer", "C_NamePlate", "C_Secrets",
    "C_Spell", "C_Timer", "C_UnitAuras",
    -- Enums --------------------------------------------------------------------
    "Enum",
  },
  -- The addon's few TRUE global writes.  Everything else is `local ... = ...`
  -- (each module binds `ns` as a local via `local ADDON, ns = ...`), so there is
  -- no shared-namespace global to declare here — only these three.
  globals = {
    "SLASH_CDMPROBE1", "SLASH_CDMPROBE2",
    "SlashCmdList",
    "CDMProbeDB",             -- SavedVariable
    "CDMProbeShards",         -- Resource.lua's owned shard-bar frame (global by name)
  },
}

-- Intentional-noise knobs, justified so a future reader doesn't loosen them
-- further:
--   * unused_args — the WoW event-handler idiom is `function(_, event, a1..aN)`;
--     the leading `self`/`event` and unused tail args are deliberate.
--   * max_line_length — several files carry long doc-comment banners by design.
unused_args = false
max_line_length = false

-- The addon-file vararg header is `local ADDON, ns = ...` in every module, where
-- `...` is WoW's `(addonName, addonTable)`.  Most files use only `ns`, so `ADDON`
-- reads as an unused local — but it is the idiomatic, self-documenting way to name
-- that first vararg, and Core.lua *does* use it.  Ignore the unused-`ADDON` case
-- specifically (config-level curation, not a scattered inline suppress); a genuine
-- unused local under any OTHER name still warns.
ignore = { "211/ADDON" }

-- The busted specs run under their own std (assert/describe/it/before_each/…);
-- compose it with the WoW std so they can still call CreateFrame et al.
files["CDMProbe/tests/"] = {
  std = "lua51+wow+busted",
}
