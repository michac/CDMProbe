-- HudCore.lua — the HUD's registry, binding, lifecycle and slash commands.
--
-- M2's decision (notes.md §5): we never move the CDM and we ship no layout
-- string.  We bind to whatever layout is CURRENTLY ACTIVE, per item, keyed by
-- GetCooldownID().  Reorder-safety and missing-spell-skip come free from that —
-- we only ever iterate live frames.
--
-- Binding is driven by EVENTS ONLY (perf cleanup (a), notes.md §9 — the M1
-- prototype's 2 s backstop ticker is GONE):
--   * viewer:RefreshLayout   — relayout: tracked-set change, orientation/size
--                              change, aura full-update, show.  This is also
--                              where newly-pooled item frames appear, so the
--                              callback RE-BINDS and RE-ATTACHES chrome, which
--                              is precisely the job the ticker was papering over.
--   * COOLDOWN_VIEWER_DATA_LOADED — tracked-set rebuild without a relayout.
--   * PLAYER_ENTERING_WORLD       — login / zone-in, viewers freshly built.
-- `/cdmp hud status` prints the per-source fire counts so the in-game pass can
-- confirm the event path alone keeps chrome attached.  If something detaches,
-- the fix is another EVENT, not the ticker back (milestones "known risks").
local ADDON, ns = ...

ns.Hud = {
  on = false,
  hooked = false,
  items = {},        -- key -> { item, spellID, viewer, index }
  lastIdentity = {}, -- key -> { spellID, baseSpellID } last READABLE identity (B2)
  missing = {},      -- expected-but-unbound spellIDs (B7); see checkExpected
  counts = {},       -- viewer frame name -> bound item count
  fires = { layout = 0, dataLoaded = 0, enterWorld = 0, binds = 0 },
  keyStats = { hits = 0, misses = 0 },
}
local M = ns.Hud

-- Icon viewers get chrome; buff viewers are registered so M3b can read proc
-- presence off item:IsShown(), but we draw nothing on them in M3a.
local ICON_VIEWERS = { "EssentialCooldownViewer", "UtilityCooldownViewer" }
local BUFF_VIEWERS = { "BuffBarCooldownViewer", "BuffIconCooldownViewer" }
local ALL_VIEWERS  = { "EssentialCooldownViewer", "UtilityCooldownViewer",
                       "BuffBarCooldownViewer", "BuffIconCooldownViewer" }
-- `hud status` tags: the first four characters collide ("Buff"/"Buff"), which
-- made the two buff viewers indistinguishable in the readout.
local VIEWER_TAG = {
  EssentialCooldownViewer = "ESS ",
  UtilityCooldownViewer   = "UTIL",
  BuffBarCooldownViewer   = "BBAR",
  BuffIconCooldownViewer  = "BICO",
}

local function isIconViewer(name)
  return name == ICON_VIEWERS[1] or name == ICON_VIEWERS[2]
end
M.IsIconViewer = isIconViewer

-- Settings --------------------------------------------------------------------
-- First real user settings land in M3c (the opener variant); M3a only needs the
-- on/off flag.  Defaults are filled defensively here as well as in Core.lua so a
-- db written by an older build picks up new keys.
-- `rows` is DEFAULT-ON in v0.10.0: the dot's reason is not diagnostics, it's
-- half the signal (§0.5.8.7 — a dot with no reason is a design failure).
-- `verbose` is the old debug mode, now a flag on the same row builder.
-- `rail` is DEFAULT-ON (M3c-c1): §0.5.2 makes shard-cap the one cue that
-- survives every accessibility/mute ceiling, so the surface that carries it is
-- not an opt-in.  ensureDB() back-fills it, so no migration is needed.
local HUD_DEFAULTS = { on = false, opener = "off", rows = true, verbose = false,
                       rail = true }

local function ensureDB()
  ns.db.hud = ns.db.hud or {}
  for k, v in pairs(HUD_DEFAULTS) do
    if ns.db.hud[k] == nil then ns.db.hud[k] = v end
  end
  -- M4 — the sequence pane's saved position.  Back-filled as a FRESH table (never
  -- a shared module default) so a drag can rewrite it safely; HudPane also reads
  -- it defensively.  Kept out of HUD_DEFAULTS because that loop shares references.
  if type(ns.db.hud.sequence) ~= "table" then
    ns.db.hud.sequence = { point = "CENTER", x = 0, y = 120 }
  end
  return ns.db.hud
end

--------------------------------------------------------------------------------
-- Registry
--------------------------------------------------------------------------------

-- The binding key.  cooldownID is the stable per-tracked-spell identity across
-- relayouts and reorders (M2 decision); the frame-index fallback only matters
-- for a viewer whose items don't expose one, and is never treated as stable.
-- Secret-guarded like every identity read (B2): `type(secret) == "number"` is
-- TRUE, and this value gets CONCATENATED into the registry key — a secret would
-- taint the string, i.e. poison every key in the registry rather than fail loudly.
function ns.ItemCooldownID(item)
  if type(item.cooldownID) == "number" and not ns.IsSecret(item.cooldownID) then
    return item.cooldownID
  end
  if ns.HasMethod(item, "GetCooldownID") then
    local ok, id = pcall(item.GetCooldownID, item)
    if ok and type(id) == "number" and not ns.IsSecret(id) then return id end
  end
  return nil
end

local function bindViewer(name)
  local viewer = ns.GetViewer(name)
  M.counts[name] = 0
  if not viewer then return end
  local items = ns.GetItemFrames(viewer)
  for i, item in ipairs(items) do
    local ok = pcall(function()
      local cdID = ns.ItemCooldownID(item)
      local spellID = ns.ItemSpellID(item)
      -- The base spell is the STABLE identity: item:GetSpellID() flips to the
      -- override while a Demonic Art transform is armed, which is why keybinds
      -- and the proc registry both key on this instead (v0.7.0).
      local baseID = ns.ItemBaseSpellID(item)
      local key = cdID and (name .. ":cd" .. cdID) or (name .. ":ix" .. i)
      -- LAST-KNOWN-GOOD IDENTITY (B2).  An identity read can now come back nil
      -- for a reason that has nothing to do with the layout: in restricted
      -- combat the buff viewer's GetSpellID() is a Secret Value, and the guards
      -- above (correctly) refuse it.  A rebind landing mid-fight — a tracked-set
      -- change, an Edit Mode nudge, an aura full-update — would otherwise
      -- OVERWRITE a perfectly good spellID with nil and take every signal keyed
      -- to that entry down with it.  So: an unreadable ID means KEEP WHAT YOU
      -- HAD, never "update".  Keyed on the same registry key, which is derived
      -- from cooldownID and is therefore stable across relayouts (M2).
      local last = M.lastIdentity[key]
      if spellID == nil and last then spellID = last.spellID end
      if baseID  == nil and last then baseID  = last.baseSpellID end
      if spellID ~= nil or baseID ~= nil then
        M.lastIdentity[key] = { spellID = spellID, baseSpellID = baseID }
      end
      M.items[key] = { item = item, spellID = spellID, baseSpellID = baseID,
                       viewer = name, index = i, cooldownID = cdID }
      -- Every item gets the state hook, buff viewers included: they are where
      -- the proc aura edges come from.  Deliberately in its OWN pcall: this
      -- shares a pcall with the chrome attach, so a throw here would silently
      -- take the M3a identity layer down with it and look like "the HUD just
      -- stopped working" — with no error, because the pcall eats it.  M3b must
      -- never be able to break M3a.  Failures surface as hooks=0 in `hud status`.
      pcall(ns.HudState.Install, item)
      -- Buff icons: surface the stack count where the spec asks for it (#17).
      if not isIconViewer(name) then
        local rule = baseID and ns.SpecStacks and ns.SpecStacks[baseID]
        if rule then pcall(ns.HudChrome.EmphasizeStacks, item, rule.suffix) end
      end
      if isIconViewer(name) then
        -- The viewer name goes in now: the bracket and the dot both need to know
        -- which side of the icon this column's chrome runs on.
        if ns.HudChrome.Attach(item, spellID, name) then
          M.keyStats.hits = M.keyStats.hits + 1
        else
          M.keyStats.misses = M.keyStats.misses + 1
        end
      end
    end)
    if ok then M.counts[name] = M.counts[name] + 1 end
  end
end

--------------------------------------------------------------------------------
-- B7 — warn when an expected icon isn't there to bind to
--------------------------------------------------------------------------------
-- WHY THIS IS NECESSARY AT ALL is the M2 decision: we bind to whatever layout is
-- CURRENTLY ACTIVE and ship no layout string, so the tracked set is the USER's,
-- not ours.  That makes a missing spell completely invisible — ns.Spec describes
-- an ability, no item ever appears for it, and the HUD simply never mentions it
-- again.  Every signal keyed to that ability goes quiet WITH NO ERROR, which is
-- exactly how Shadow Bolt's absence hid the SB -> Infernal Bolt blind spot for
-- four milestones.  Standing doctrine: capability gaps are REPORTED, never
-- assumed.
--
-- Two filters keep the warning from crying wolf, and both are load-bearing:
--   * IsPlayerSpell — without it this false-fires on every untalented
--     alternative in the table (Grimoire: Imp Lord vs Fel Ravager, Axe Toss vs
--     Command Demon).
--   * `expect = false` — entries that exist only as a live spell OVERRIDE (the
--     Demonic Art transforms, Devour Magic).  They are never separately tracked
--     by the CDM, so "unbound" is their normal state, not a gap.
local function expectedButtons()
  local out = {}
  for id, info in pairs(ns.Spec or {}) do
    if info.kind == "button" and info.expect ~= false and type(id) == "number" then
      local ok, has = pcall(IsPlayerSpell, id)
      if ok and has == true then out[#out + 1] = id end
    end
  end
  table.sort(out)
  return out
end

-- Say what is LOST, not just what is missing: "Shadow Bolt — not tracked;
-- SB -> Infernal Bolt cannot light" is actionable, "missing 686" is not.
local function lossText(id)
  local info = ns.SpecInfo(id)
  if info.lost then return info.lost end
  return "no dot, no keybind and no anticipation for it"
end

-- Recompute the missing set.  Warns ONCE PER RESOLVED SET, never per rebind:
-- rebind() fires on every RefreshLayout, so an unconditional print would spam
-- the chat frame on every Edit Mode nudge — and a warning that spams is a
-- warning that gets ignored, which defeats the whole point.
local function checkExpected()
  local bound = {}
  for _, e in pairs(M.items) do
    if type(e.baseSpellID) == "number" then bound[e.baseSpellID] = true end
    if type(e.spellID) == "number" then bound[e.spellID] = true end
  end
  local missing = {}
  for _, id in ipairs(expectedButtons()) do
    if not bound[id] then missing[#missing + 1] = id end
  end
  M.missing = missing

  local sig = table.concat(missing, ",")
  if sig == M.warnedMissing then return end
  M.warnedMissing = sig
  -- Nothing missing: stay silent (and the empty signature is now cached, so a
  -- spell going missing later still warns exactly once).
  if #missing == 0 then return end
  ns.Printf("|cffffd100HUD:|r %d expected ability/abilities are |cffffd100not in your Cooldown Manager|r:", #missing)
  for _, id in ipairs(missing) do
    ns.Printf("   |cffffffff%s|r (%d) — not tracked; %s",
      ns.SpellName(id) or "?", id, lossText(id))
  end
  ns.Print("   Add them in Edit Mode -> Cooldown Manager, or |cffffffff/cdmp hud status|r to see this again.")
end

-- Rebuild the whole registry and re-attach chrome to every live item frame.
-- Cheap: a handful of frames, a table wipe, a few texture setters.
local function rebind()
  if not M.on then return end
  -- Remember what was bound, so anything that DROPS OUT of the tracked set gets
  -- detached rather than silently keeping its chrome.  Item frames are POOLED and
  -- reused, so a frame released by one layout is a live frame we still hold a
  -- chrome object for — and the global repaint paths (SetRecede, the bracket
  -- collapse) walk every chrome ever created.  Without this, `attached` never
  -- goes false for those and the invariant "only bound items are painted" is only
  -- true because Blizzard happens to hide the frame underneath.
  local was = {}
  for _, e in pairs(M.items) do if e.item then was[e.item] = true end end
  wipe(M.items)
  M.keyStats.hits, M.keyStats.misses = 0, 0
  M.fires.binds = M.fires.binds + 1
  for _, name in ipairs(ALL_VIEWERS) do bindViewer(name) end
  for _, e in pairs(M.items) do was[e.item] = nil end
  for item in pairs(was) do pcall(ns.HudChrome.Detach, item) end
  for _, name in ipairs(ICON_VIEWERS) do
    local v = ns.GetViewer(name)
    if v then ns.HudChrome.FlowScan(v) end
  end
  ns.HudChrome.ShowTerminal(ns.GetViewer(ICON_VIEWERS[1]))
  -- M3c-c1 — the shard rail is a VIEWER-ANCHORED child, so it rides Edit Mode
  -- drags and orientation changes for free and needs no saved position.  That
  -- also means it must be re-shown from here: rebind() IS the RefreshLayout
  -- callback, and a relayout is exactly when the viewer moved.  pcall'd like its
  -- neighbours, because a throw in this tail escapes into Blizzard's code.
  if ensureDB().rail ~= false then
    pcall(ns.HudChrome.ShowRail, ns.GetViewer(ICON_VIEWERS[1]))
  else
    pcall(ns.HudChrome.HideRail)
  end
  -- Item frames are pooled and reused across relayouts, so readiness survives;
  -- presence is re-synced from the level read (where it's meaningful) and the
  -- glows re-resolved onto whatever frames the new layout handed us.
  -- pcall'd because rebind() IS the RefreshLayout hooksecurefunc callback: an
  -- uncaught throw in this tail would surface inside Blizzard's layout path,
  -- not ours.  bindViewer already pcalls per item; this closes the same gap for
  -- the whole-registry work that follows it.
  pcall(ns.HudState.SyncLevels)
  -- M3d — seed readiness + the countdown from the client's own numbers.  THIS
  -- is the login / /reload / zone-in / layout-change path, so this one line is
  -- the whole cold-start fix: without it the board sits at
  -- "NEVER · no edge seen yet" until you've played a full cooldown cycle.
  -- Refuses itself in combat (both here and inside ns.ReadCooldown), so a
  -- rebind landing mid-fight costs nothing.
  pcall(ns.HudState.SeedFromReads)
  pcall(ns.HudState.RefreshGlows)  -- ...which also re-drives the dot score
  pcall(checkExpected)             -- B7 — diff expected against bound, warn once
  -- M3c-c2 — arm the pre-pull opener for the coming pull.  A viewer-anchored
  -- HudQueue, re-shown from here like the rail; refuses itself in combat.
  if ns.HudOpener then pcall(ns.HudOpener.Arm) end
end
M.Rebind = rebind

-- The primary icon viewer — the anchor the terminal, rail and opener queue all
-- hang off.  Exposed so HudOpener (which has no view of ICON_VIEWERS) can find it.
function M.IconViewer()
  return ns.GetViewer(ICON_VIEWERS[1])
end

-- Cheap path for HudBinds: keybind text only, no re-registry.
function M.RefreshKeybinds()
  if not M.on then return end
  M.keyStats.hits, M.keyStats.misses = 0, 0
  for _, entry in pairs(M.items) do
    if isIconViewer(entry.viewer) then
      if ns.HudChrome.Attach(entry.item, entry.spellID, entry.viewer) then
        M.keyStats.hits = M.keyStats.hits + 1
      else
        M.keyStats.misses = M.keyStats.misses + 1
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Event wiring
--------------------------------------------------------------------------------

-- hooksecurefunc can't be undone, so the callbacks are installed once and gated
-- on M.on.  If the viewers didn't exist yet, M.hooked stays false and the next
-- enable retries.
local function installHooks()
  if M.hooked then return end
  local any = false
  for _, name in ipairs(ALL_VIEWERS) do
    local v = ns.GetViewer(name)
    if v and ns.HasMethod(v, "RefreshLayout") then
      hooksecurefunc(v, "RefreshLayout", function()
        if not M.on then return end
        M.fires.layout = M.fires.layout + 1
        rebind()
      end)
      any = true
    end
  end
  M.hooked = any
end

local ev = CreateFrame("Frame")
ev:SetScript("OnEvent", function(_, event)
  if not M.on then return end
  if event == "COOLDOWN_VIEWER_DATA_LOADED" then
    M.fires.dataLoaded = M.fires.dataLoaded + 1
  elseif event == "PLAYER_ENTERING_WORLD" then
    M.fires.enterWorld = M.fires.enterWorld + 1
    installHooks()          -- viewers may only now exist
  end
  rebind()
end)

--------------------------------------------------------------------------------
-- Enable / disable
--------------------------------------------------------------------------------
function ns.SetHud(on)
  local db = ensureDB()
  db.on = on and true or false
  M.on = db.on
  if M.on then
    -- The retired experiments write to item.Icon; don't fight them.
    if ns.db.skinOn and ns.SetSkin then ns.SetSkin(false) end
    if ns.db.resourceOn and ns.SetResource then ns.SetResource(false) end
    ns.HudBinds.Start()
    installHooks()
    ev:RegisterEvent("COOLDOWN_VIEWER_DATA_LOADED")
    ev:RegisterEvent("PLAYER_ENTERING_WORLD")
    rebind()
    ns.HudState.Start()
    ns.HudRow.verbose = db.verbose and true or false
    ns.HudRow.Set(db.rows ~= false)
    ns.Print("HUD |cff88ff88ON|r — native icons, group brackets, keybinds, and the |cff88ff88dot score|r "
      .. "(level + why) beside each icon. |cffffffff/cdmp hud status|r for the readout, "
      .. "|cffffffff/cdmp hud debug|r for verbose rows.")
  else
    M.on = false
    ev:UnregisterAllEvents()
    ns.HudState.Stop()
    ns.HudRow.Hide()
    ns.HudBinds.Stop()
    ns.HudChrome.HideTerminal()
    ns.HudChrome.HideRail()
    if ns.HudOpener then ns.HudOpener.Hide() end
    if ns.HudBurst then ns.HudBurst.Hide() end
    if ns.HudPane then ns.HudPane.Hide() end
    for _, entry in pairs(M.items) do
      pcall(ns.HudChrome.Detach, entry.item)
    end
    for _, name in ipairs(ICON_VIEWERS) do
      local v = ns.GetViewer(name)
      if v then ns.HudChrome.HideScan(v) end
    end
    -- Our frames are hidden; ask Blizzard to repaint so the CDM is pixel-clean.
    for _, name in ipairs(ALL_VIEWERS) do
      local v = ns.GetViewer(name)
      if v and ns.HasMethod(v, "RefreshData") then pcall(v.RefreshData, v) end
    end
    wipe(M.items)
    wipe(M.lastIdentity)
    wipe(M.missing)
    M.warnedMissing = nil       -- a fresh enable re-states the capability gap
    ns.Print("HUD |cffff8080OFF|r — Blizzard's Cooldown Manager restored untouched.")
  end
end

--------------------------------------------------------------------------------
-- Status readout
--------------------------------------------------------------------------------
local function printStatus()
  local db = ensureDB()
  ns.Heading("HUD status — M3c-c1 (shard rail + mode spine) on M3c-b + M3d")
  ns.Printf("  state: %s   rows: %s (verbose %s)   rail: %s",
    M.on and "|cff88ff88ON|r" or "|cffff8080OFF|r",
    ns.HudRow.on and "|cff88ff88on|r" or "|cffff8080off|r",
    ns.HudRow.verbose and "|cff88ff88on|r" or "off",
    db.rail ~= false and "|cff88ff88on|r" or "|cffff8080off|r")
  ns.Printf("  opener (M3c-c2): %s",
    ns.HudOpener and ns.HudOpener.StatusText() or "|cff808080module missing|r")
  ns.Printf("  burst (M4): %s",
    ns.HudBurst and ns.HudBurst.StatusText() or "|cff808080module missing|r")
  ns.Printf("  sequence pane (M4): %s",
    ns.HudPane and ns.HudPane.StatusText() or "|cff808080module missing|r")
  ns.Printf("  bind fires: RefreshLayout=%d  DATA_LOADED=%d  ENTERING_WORLD=%d  -> rebinds=%d  (|cffffd100no ticker running|r)",
    M.fires.layout, M.fires.dataLoaded, M.fires.enterWorld, M.fires.binds)
  ns.Printf("  hooks installed: %s", M.hooked and "|cff88ff88yes|r" or "|cffff4040no (viewers absent at install time)|r")
  for _, name in ipairs(ALL_VIEWERS) do
    ns.Printf("  |cffffd100%s|r — %d bound", name, M.counts[name] or 0)
  end
  ns.Printf("  keybinds: %d resolved / %d unbound   (cache: %d slot(s) with a spell, %d scan(s), %d coalesced, %d deferred to OOC%s)",
    M.keyStats.hits, M.keyStats.misses,
    ns.HudBinds.stats.slots, ns.HudBinds.stats.scans, ns.HudBinds.stats.coalesced,
    ns.HudBinds.stats.deferred,
    ns.HudBinds.dirty and ", |cffffd100dirty|r" or "")
  -- B7's PERSISTENT home.  Chat scrolls away; this readout doesn't, and it is
  -- what `/cdmp probe` captures to disk for off-line reading.  So the gap is
  -- listed here EVERY time, not just on the edge that first found it.
  if M.missing and #M.missing > 0 then
    ns.Printf("  |cffffd100expected but NOT tracked by the CDM: %d|r", #M.missing)
    for _, id in ipairs(M.missing) do
      ns.Printf("   |cffff4040missing|r %s (%d) — %s", ns.SpellName(id) or "?", id, lossText(id))
    end
  else
    ns.Print("  expected vs bound: |cff88ff88complete|r — every ns.Spec button you know is tracked")
  end
  ns.HudState.PrintStatus()
  ns.Heading("  bound items")
  for _, name in ipairs(ALL_VIEWERS) do
    for key, e in pairs(M.items) do
      if e.viewer == name then
        local info, known = ns.SpecInfo(e.baseSpellID or e.spellID)
        -- `base` differs from `id` exactly while a spell override is armed
        -- (Demonic Art) — the one case M3a's keybind lookup used to miss.
        local ready = ns.HudChrome.GetReady(e.item)
        local sc = ns.HudState.score[key]
        -- M3d — WHERE that readiness came from.  Both an alert edge and an
        -- out-of-combat read are direct observations and both render solid, so
        -- this readout is the only place the two are distinguishable — which is
        -- also what keeps M3c-b and M3d separable inside one release.
        local src = ns.HudState.readySource[key]
        local readyText = (ready == nil) and "|cff808080unknown|r"
          or ((ready and "|cff88ff88yes|r" or "no") .. (src and ("(" .. src .. ")") or ""))
        ns.Printf("   [%s] cd=%s id=%s%s %s  group=%s/%s cadence=%s%s  key=%s  ready=%s  dot=%s%s",
          VIEWER_TAG[name] or name:sub(1, 4), tostring(e.cooldownID), ns.Describe(e.spellID),
          (e.baseSpellID and e.baseSpellID ~= e.spellID)
            and (" |cffffd100(base " .. tostring(e.baseSpellID) .. ", overridden)|r") or "",
          (e.spellID and ns.SpellName(e.spellID)) or "?",
          info.group, ns.SpecPole(info), tostring(info.cadence or "-"),
          known and "" or " |cffffd100(not in ns.Spec — neutral)|r",
          ns.HudBinds.GetForItem(e.item, e.spellID) or "|cff808080none|r",
          readyText,
          sc and (sc.level .. (sc.soon and "/SOON" or "") .. (sc.projected and "~est" or "")) or "|cff808080none|r",
          ns.HudChrome.IsGlowing(e.item) and "  |cff44e0ffGLOW|r" or "")
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Keybind diagnostic (§7.2 items 4/5)
--------------------------------------------------------------------------------
-- "I remapped a key and the HUD didn't pick it up."  The resolved map only keeps
-- the winning slot, so this prints EVERY slot each tracked spell sits in, with
-- the binding command and raw key, and marks which one the chrome is using.
-- Reading the three failure modes off this is faster than reasoning about the
-- cache — see the header comment on ns.HudBinds.Explain.
local function printBinds()
  ns.Heading("HUD keybinds — every action slot per tracked spell")
  if InCombatLockdown() then
    ns.Print("  |cffffd100in combat|r — the bar scan is out-of-combat only; this is a live read and may be stale.")
  end
  if not next(M.items) then
    -- The registry is only populated while the HUD is on, and an empty readout
    -- would look like "no keybinds found" rather than "nothing is bound yet".
    return ns.Print("  |cffffd100nothing bound|r — the registry fills when the HUD is on. |cffffffff/cdmp hud|r first.")
  end
  local bySpell = ns.HudBinds.Explain()
  local seen = {}
  for _, e in pairs(M.items) do
    local id = e.baseSpellID or e.spellID
    -- The tracked set holds duplicates by design (one spell, two cooldownIDs),
    -- so dedupe on the spell rather than printing it twice.
    if type(id) == "number" and not ns.IsSecret(id) and not seen[id] then
      seen[id] = true
      local used = ns.HudBinds.Get(id)
      local rows = bySpell[id]
      ns.Printf(" |cffffd100%s|r (%d) -> chrome shows %s",
        ns.SpellName(id) or "?", id, used and ("|cff88ff88" .. used .. "|r") or "|cff808080nothing|r")
      if not rows then
        -- No slot maps to this spell at all: either it's genuinely off your bars,
        -- or it's behind a conditional macro GetMacroSpell can't resolve (3).
        ns.Print("    |cff808080no action slot holds this spell (off-bars, or a macro that doesn't resolve)|r")
      else
        for _, r in ipairs(rows) do
          ns.Printf("    slot %3d (%s)  cmd=%s  key=%s%s  -> %s%s",
            r.slot, r.via,
            r.cmd or "|cffff4040none — unbindable slot range|r",
            r.key or "|cff808080unbound|r",
            -- The FOURTH failure mode (M3e R5): GetBindingKey returns TWO keys
            -- and the resolver only ever reads the first, so a player who
            -- remapped the SECONDARY binding saw no change and no row saying why.
            r.key2 and ("  |cffffd1002nd=" .. r.key2 .. " (not used)|r") or "",
            r.short or "|cff808080-|r",
            (r.short and r.short == used) and "  |cff88ff88<-- used|r" or "")
        end
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------
-- ⚠ ORDER-SENSITIVE substring matching, and anything unmatched falls through to
-- toggling the whole HUD.  Every new subcommand goes ABOVE the bare-toggle tail,
-- and the help string above is the only place a user learns it exists.
ns.RegisterCommand("hud",
  "the real spec HUD (dot score + why). 'hud log' = the last recorded pull (histogram + peak set + events; 'hud log all' for the ring); 'hud status' = the readout in chat; 'hud binds' = every slot/key per spell; 'hud debug' = verbose rows; 'hud rows' = toggle the rows entirely; 'hud rail' = toggle the shard rail + mode chrome; 'hud opener on|off' = the pre-pull opener strip (now in the movable sequence pane; default off, shares the BURST window); 'hud pane lock|unlock' = position the over-the-character sequence pane.",
  function(rest)
    rest = (rest or ""):lower()
    if rest:find("status") then return printStatus() end
    -- M3e.  Above the bare-toggle tail like every other subcommand — this
    -- dispatch is order-sensitive substring matching and ANYTHING UNMATCHED
    -- TOGGLES THE HUD, which is a very confusing way to learn you typo'd.
    if rest:find("log") then return ns.HudLog.Print(rest:find("all") ~= nil) end
    if rest:find("bind") then return printBinds() end
    if rest:find("dump") then return ns.HudRow.Dump() end
    if rest:find("debug") or rest:find("verbose") then
      return ns.HudRow.SetVerbose(not ns.HudRow.verbose)
    end
    if rest:find("rail") then
      local db = ensureDB()
      db.rail = (db.rail == false)          -- flip; the default is ON
      if M.on then
        if db.rail then
          pcall(ns.HudChrome.ShowRail, ns.GetViewer(ICON_VIEWERS[1]))
          pcall(ns.HudState.PaintRail)
        else
          pcall(ns.HudChrome.HideRail)
        end
      end
      return ns.Printf("HUD shard rail %s.",
        db.rail and "|cff88ff88ON|r" or "|cffff8080OFF|r")
    end
    if rest:find("rows") then
      ns.HudRow.Set(not ns.HudRow.on)
      return ns.Printf("HUD rows %s.", ns.HudRow.on and "|cff88ff88ON|r" or "|cffff8080OFF|r")
    end
    -- M3c-c2 — the pre-pull opener strip.  `on`/`off` set it; a bare `hud opener`
    -- toggles.  DEFAULT OFF: it is the only instructional widget and is on notice
    -- (§0.5.8.7 §0), so it must be opted into.
    if rest:find("opener") then
      local db = ensureDB()
      local arg = rest:match("opener%s+(%S+)")
      if arg == "off" then db.opener = "off"
      elseif arg == "on" or arg == "1a" then db.opener = "on"   -- 1a: legacy alias
      else db.opener = (db.opener == "off") and "on" or "off" end
      if M.on and ns.HudOpener then pcall(ns.HudOpener.Arm) end
      return ns.Printf("HUD opener: %s",
        ns.HudOpener and ns.HudOpener.StatusText() or tostring(db.opener))
    end
    -- M4 — the sequence pane's lock/unlock, the ONLY positioning path (it does not
    -- ride Edit Mode — over-the-character placement is the point).  `unlock` shows
    -- it draggable (a placeholder if idle); `lock` makes it click-through + hides
    -- it when idle.  Above the bare-toggle tail like every other subcommand.
    if rest:find("pane") then
      if not ns.HudPane then return ns.Print("HUD: pane module missing.") end
      local arg = rest:match("pane%s+(%S+)")
      if arg == "lock" then ns.HudPane.SetLocked(true)
      elseif arg == "unlock" then ns.HudPane.SetLocked(false)
      else ns.HudPane.SetLocked(not ns.HudPane.locked) end
      return ns.Printf("HUD sequence pane: %s", ns.HudPane.StatusText())
    end
    ns.SetHud(not ensureDB().on)
  end)

-- Manual single/AoE toggle (v0.16.3) — MACRO-FRIENDLY, on purpose.  `/cdmp
-- single` and `/cdmp multi` are idempotent setters (bind each to a button, or
-- put both in one /click macro), and `/cdmp aoe` bare-toggles for a single key.
-- Setting a flag is not a protected action, so these run fine mid-combat.
local function reportAoE()
  ns.Printf("target mode: %s  |cff808080(no Demo dot changes yet — Demo is a passive-cleave spec; scaffolding for a 2nd spec / talent rule)|r",
    ns.HudState.aoe and "|cffbef264MULTI (AoE)|r" or "|cff88ccffSINGLE|r")
end
ns.RegisterCommand("single", "target mode: SINGLE-target (suppresses Implosion). Macro-friendly.", function()
  ns.HudState.SetAoE(false); reportAoE()
end)
ns.RegisterCommand("multi", "target mode: MULTI-target / AoE (offers Implosion). Macro-friendly.", function()
  ns.HudState.SetAoE(true); reportAoE()
end)
ns.RegisterCommand("aoe", "toggle target mode single<->multi (bare toggle for a one-key macro)", function(rest)
  rest = (rest or ""):lower()
  if rest:find("on") or rest:find("multi") then ns.HudState.SetAoE(true)
  elseif rest:find("off") or rest:find("single") then ns.HudState.SetAoE(false)
  else ns.HudState.SetAoE(not ns.HudState.aoe) end
  reportAoE()
end)

-- Fold into /cdmp reset (wrap the chain Probes.lua + Resource.lua built).
local prevReset = ns.commands.reset and ns.commands.reset.fn
ns.RegisterCommand("reset", "turn every experiment off (unskin, hide bars/rail, resource + hud off, log off)", function(rest)
  if ns.db.hud and ns.db.hud.on then ns.SetHud(false) end
  if prevReset then prevReset(rest) end
end)

-- Restore on login (wrap the existing chain).
local prevOnLogin = ns.OnLogin
function ns.OnLogin()
  if prevOnLogin then prevOnLogin() end
  if ns.db and ns.db.hud and ns.db.hud.on then
    C_Timer.After(1.0, function() ns.SetHud(true) end)
  end
end
