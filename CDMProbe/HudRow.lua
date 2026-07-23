-- HudRow.lua — the row beside each icon: the DOT's reason, in words.
--
-- (Was HudDebug.lua.  Renamed in v0.10.0 when it stopped being a debug mode and
-- became part of the HUD.)
--
-- WHY IT'S DEFAULT-ON NOW.  M3a/M3b encoded state as colour, luminance,
-- thickness and glow, and five in-game passes returned the same verdict:
-- "yellow, purple etc. don't really have any meaning in isolation."  That is
-- correct and structural — you cannot read an arbitrary encoding you haven't
-- learned.  §0.5.8.7's answer is a per-ability DOT carrying an actionability
-- level, plus this row saying WHY.
--
-- The row is therefore not decoration and not diagnostics: it is what makes the
-- score AUDITABLE RATHER THAN AN ORACLE.  A dot whose stated reason you disagree
-- with is a scoring bug you can argue with; a dot with no reason is a design
-- failure.  So the reason ships with the dot, always.
--
-- Two modes, ONE row builder, a flag — deliberately not two near-duplicate
-- renderers:
--   normal   — dot's level + the reasons.  Conservative: NO ability name (the
--              icon already says that), just [keybind] LEVEL reasons.
--   verbose  — `/cdmp hud debug`.  Adds identity (group/pole), base cooldown,
--              raw + normalised cost, presence source, and override state.  This
--              is the correctness check: before trusting a compressed signal we
--              get to see whether the underlying state is even RIGHT.
--
-- The DOT itself is drawn by HudChrome (it's a chrome primitive that has to
-- compose with recede and the bracket); this module owns only the text, and
-- reports its measured width back so the bracket can span icon + dot + text.
local ADDON, ns = ...

ns.HudRow = { on = false, verbose = false }
local D = ns.HudRow

-- Bundled JetBrains Mono, same as the BucketBinds console.  A genuine monospace
-- is the whole point of a terminal readout: columns line up, and glyphs stay
-- distinguishable at small sizes in a way ARIALN's condensed forms do not.
-- The font + its load-failure fallback now live in Util (ns.SetFont) because
-- HudChrome's imp-count path needs the identical guard (§7.2 item 3).
local SIZE = 14                 -- was 11 — unreadable at 1440p+
local REFRESH = 0.15

local function applyFont(obj, size)
  ns.SetFont(obj, size, "OUTLINE")
end

-- Weak keys: rows hang off pooled item frames we don't own.
local rows = setmetatable({}, { __mode = "k" })
local summary, ticker

--------------------------------------------------------------------------------
-- Colour helpers
--------------------------------------------------------------------------------
local function hex(r, g, b)
  return string.format("|cff%02x%02x%02x", math.floor(r * 255 + 0.5),
    math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

-- The group name printed in the group's own hue — this is what makes the colour
-- map self-teaching rather than something you have to hold in your head.
local function groupTag(group)
  local c = ns.SpecGroups[group] or ns.SpecGroups.neutral
  return hex(c[1], c[2], c[3]) .. group .. "|r"
end

local WHITE, GREY = "|cffffffff", "|cff808080"
local GREEN, RED, AMBER, CYAN = "|cff55ff55", "|cffff5555", "|cffffd100", "|cff44e0ff"

-- Level word, printed in the dot's own colour so the two teach each other.
local function levelTag(level)
  local c = ns.HudChrome.DOT_COLORS[level]
  local pad = string.rep(" ", math.max(0, 9 - #level))
  if not c then return GREY .. level .. "|r" .. pad end
  return hex(c.c[1], c.c[2], c.c[3]) .. level .. "|r" .. pad
end

--------------------------------------------------------------------------------
-- One text row per item, anchored OUTSIDE the icon, past the dot
--------------------------------------------------------------------------------
-- Nothing clips our overlay (notes.md §9 — no clipsChildren in the CDM
-- templates), so a row can run as far past the narrow column as it likes.
local function ensureRow(item, viewer)
  if rows[item] then return rows[item] end
  local lvl = (ns.HasMethod(item, "GetFrameLevel") and item:GetFrameLevel() or 1) + 20
  local f = CreateFrame("Frame", nil, item)
  f:SetSize(1, 1)
  f:SetFrameLevel(lvl)
  local fs = f:CreateFontString(nil, "OVERLAY")
  applyFont(fs, SIZE)
  -- H.ROW_OFFSET clears the dot, so the two never overlap whatever the dot's
  -- current size is (it grows with level).  Buff viewers carry no dot — they're
  -- inputs to the score, not scored — so their rows sit tight against the icon
  -- rather than leaving a gap for a mark that will never appear.
  local off = ns.Hud.IsIconViewer(viewer) and ns.HudChrome.ROW_OFFSET or 8
  if ns.HudChrome.SideFor(viewer) == "LEFT" then
    f:SetPoint("RIGHT", item, "LEFT", -off, 0)
    fs:SetPoint("RIGHT", f, "RIGHT", 0, 0)
    fs:SetJustifyH("RIGHT")
  else
    f:SetPoint("LEFT", item, "RIGHT", off, 0)
    fs:SetPoint("LEFT", f, "LEFT", 0, 0)
    fs:SetJustifyH("LEFT")
  end
  f.text = fs
  rows[item] = f
  return f
end

--------------------------------------------------------------------------------
-- The line itself
--------------------------------------------------------------------------------
-- NORMAL:   [key] LEVEL   reason · reason
-- VERBOSE:  ...plus name · group/pole · cd · cost · presence · override
local function lineFor(key, e)
  local info, known = ns.SpecInfo(e.baseSpellID or e.spellID)

  -- M4.1 — NON-VERBOSE + a scored icon draws NO reason text: the cue bar off the
  -- icon edge is the whole signal now (this reverses M3c-a's words-first default,
  -- on purpose — the fix for illegible colour is a legible visual, not permanent
  -- words).  Return nil so the row hides and its bracket collapses.  `hud debug`
  -- restores the full reasoned rows below unchanged (the correctness view), and
  -- the buff-viewer PRESENT rows + the `lit` summary line are untouched.
  -- M4.6 §4.6, hint 2 — "SHARDS!" beside TYRANT, in the space the debug row
  -- normally occupies.  This is the ONE row that prints with `hud debug` off: the
  -- burst window is open, the go-signal is sitting there yellow, and the single
  -- thing standing between you and pressing it is the shard count.  It is a
  -- call-out, not a reason line, so it is checked BEFORE the non-verbose return.
  if ns.HudBurst and ns.HudBurst.NeedShards()
     and ns.SpecIDs and (e.baseSpellID or e.spellID) == ns.SpecIDs.TYRANT then
    return AMBER .. "SHARDS!|r"
  end

  if ns.Hud.IsIconViewer(e.viewer) and not D.verbose then return nil end

  local parts = {}

  local bind = ns.HudBinds.GetForItem(e.item, e.spellID)
  parts[#parts + 1] = bind and (AMBER .. "[" .. bind .. "]|r") or (GREY .. "[--]|r")

  if D.verbose then
    local name = (e.spellID and ns.SpellName(e.spellID)) or "?"
    if ns.IsSecret(name) then name = "<secret>" end
    parts[#parts + 1] = WHITE .. tostring(name) .. "|r"
    parts[#parts + 1] = groupTag(info.group) .. GREY .. "/" .. "|r" .. ns.SpecPole(info)
      .. (known and "" or (AMBER .. "(unmapped)|r"))
  end

  if ns.Hud.IsIconViewer(e.viewer) then
    local sc = ns.HudState.score[key]
    if sc then
      -- SOON is a treatment on NEVER, not a level — but in WORDS it deserves its
      -- own name, because "NEVER, ~2.4s" reads as a contradiction and "SOON" does
      -- not.  The dot stays hollow either way: still an estimate, still not a
      -- claim that you can press it.
      local shown = (sc.soon and sc.level == "NEVER") and "SOON" or sc.level
      parts[#parts + 1] = levelTag(shown)
      -- Mirror the hollow dot in WORDS (B4): this level came off an in-flight-cast
      -- projection, so the row says so rather than letting the level stand alone
      -- as if it were observed.
      if sc.projected and (sc.level == "ROTATION" or sc.level == "LATE") then
        parts[#parts + 1] = AMBER .. "~est|r"
      end
      local why = ns.HudScore.Why(sc)
      if why ~= "" then parts[#parts + 1] = why end
    else
      parts[#parts + 1] = GREY .. "—|r"
    end

    if D.verbose then
      -- Readiness is TRI-state and the unknown is meaningful: we have not
      -- observed an edge for this spell yet, and we refuse to guess one.
      local ready = ns.HudChrome.GetReady(e.item)
      local baseCD = ns.BaseCooldown(e.baseSpellID or e.spellID)
      if ready == true then parts[#parts + 1] = GREEN .. "READY|r"
      elseif ready == false then parts[#parts + 1] = RED .. "on-CD|r"
      elseif baseCD == 0 then
        -- NOT "unknown".  A spell with no cooldown never fires a cooldown edge,
        -- so readiness is the wrong question for it entirely — its gate is
        -- RESOURCE (shards / a proc), which is what the score reads.
        parts[#parts + 1] = GREY .. "no-CD (resource-gated)|r"
      else parts[#parts + 1] = GREY .. "? (no edge seen yet)|r" end
      if baseCD and baseCD > 0 then
        parts[#parts + 1] = GREY .. string.format("cd %ds|r", baseCD)
      end
      -- Cost as the CLIENT reports it for THIS build — the arbiter for the
      -- talent-dependent numbers no doc can settle (Dreadstalkers free under
      -- Demonic Calling, Tyrant's cost, Grimoire's cost).  BOTH the normalised
      -- shard figure and the raw one, because the units question (shards vs
      -- fragments) is now load-bearing: if the cost reads wrong, the gate logic
      -- is wrong, and this line is what settles it in game.
      local shardCost, rawCost = ns.ShardCost(e.baseSpellID or e.spellID)
      if shardCost and shardCost > 0 then
        parts[#parts + 1] = AMBER .. string.format("cost %d shard(s)%s|r", shardCost,
          rawCost ~= shardCost and string.format(" [raw %d]", rawCost) or "")
      elseif shardCost == 0 then
        parts[#parts + 1] = GREY .. "cost free|r"
      end
      if ns.HudChrome.IsGlowing(e.item) then
        local st = ns.HudChrome.GlowStrength(e.item)
        parts[#parts + 1] = CYAN .. "GLOW" ..
          ((st and st < 1) and string.format(" (soft %.2f)", st) or "") .. "|r"
      end
    end
  else
    -- Buff viewers carry no dot: they are INPUTS to the score, not scored.
    -- Presence is the interesting fact, plus where it came from.
    local present = ns.HudState.presence[key]
    if present then
      parts[#parts + 1] = CYAN .. "PRESENT|r"
    elseif D.verbose then
      parts[#parts + 1] = GREY .. "absent|r"
    else
      return nil            -- normal mode: an absent aura is not worth a row
    end
    if D.verbose then
      local src = e.baseSpellID and ns.HudState.lastEdge[e.baseSpellID]
      if src then parts[#parts + 1] = GREY .. "via " .. src .. "|r" end
    end
  end

  -- A live spell override (Demonic Art) — the one case where the item's reported
  -- spell differs from its identity, and the thing #3 glows on.
  if D.verbose and e.baseSpellID and ns.HudState.override[e.baseSpellID] then
    parts[#parts + 1] = AMBER .. "OVERRIDE->" ..
      (ns.SpellName(ns.HudState.override[e.baseSpellID]) or "?") .. "|r"
  end

  return table.concat(parts, GREY .. " · |r")
end

--------------------------------------------------------------------------------
-- The global summary line, above the Essential column
--------------------------------------------------------------------------------
local function ensureSummary()
  if summary then return summary end
  local anchor = ns.GetViewer("EssentialCooldownViewer")
  if not anchor then return nil end
  local f = CreateFrame("Frame", nil, anchor)
  f:SetSize(1, 1)
  f:SetFrameLevel((ns.HasMethod(anchor, "GetFrameLevel") and anchor:GetFrameLevel() or 1) + 20)
  f:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 26)
  local fs = f:CreateFontString(nil, "OVERLAY")
  applyFont(fs, SIZE)
  fs:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
  fs:SetJustifyH("LEFT")
  f.text = fs
  summary = f
  return f
end

local function summaryLine()
  local S = ns.HudState
  local shards = S.shards and (WHITE .. tostring(S.shards) .. "/" .. ns.SHARD_CAP .. "|r")
    or (RED .. "unreadable|r")
  -- The spend-side projection, on the summary line: while a cast is in flight the
  -- dots are scored against this figure, so it has to be visible or the board
  -- looks like it's disagreeing with the shard count sitting right next to it.
  if S.ProjectedShards then
    local proj, isProj = S.ProjectedShards()
    if isProj then shards = shards .. AMBER .. " ->~" .. tostring(proj) .. "|r" end
  end
  local lit = 0
  for _, sc in pairs(S.score) do
    if sc.level == "ROTATION" or sc.level == "LATE" then lit = lit + 1 end
  end
  -- `lit` is the strictness meter, on screen, permanently.  1-2 is the design;
  -- a board that sits at 4+ means the RULES need tightening, not the visuals.
  local base = string.format("shards %s  %slit|r %s%d|r", shards, GREY,
    lit <= 2 and GREEN or AMBER, lit)
  if not D.verbose then
    -- Anticipation dark is worth knowing WITHOUT opening the status block, since
    -- it's the one failure that looks exactly like "nothing is happening yet".
    if ns.HudNapkin.readable == false then
      base = base .. "  " .. RED .. "napkin OFF (cast IDs secret)|r"
    end
    return base
  end
  return string.format("%sVERBOSE|r  %s  %sedges|r rdy+%d/-%d aura+%d/-%d  %srecede|r %.2f  %slevel|r %s",
    AMBER, base, GREY,
    S.fires.available, S.fires.oncd, S.fires.applied, S.fires.removed,
    GREY, ns.HudChrome.GetRecede(), GREY,
    S.levelOK == true and "ok" or (S.levelOK == false and "edges-only" or "?"))
end

--------------------------------------------------------------------------------
-- Refresh / toggle
--------------------------------------------------------------------------------
-- Returns the number of rows actually drawn, so the toggle can REPORT it.  A
-- silent zero is what made the first build indistinguishable from a no-op.
function D.Refresh()
  if not D.on or not (ns.Hud and ns.Hud.on) then return 0 end
  local drawn = 0
  for key, e in pairs(ns.Hud.items) do
    if e.item then
      -- Per-item pcall around the FRAME work too, not just the string build:
      -- one unco-operative item must not take the other nineteen rows down.
      local okRow = pcall(function()
        local ok, line = pcall(lineFor, key, e)
        local row = ensureRow(e.item, e.viewer)
        if ok and line == nil then
          row.text:SetText("")
          row:Hide()
          -- No text -> the bracket collapses back to the icon.  This is why the
          -- extent is reported rather than computed once: it is not constant.
          ns.HudChrome.SetBracketExtent(e.item, 0)
          return
        end
        row.text:SetText(ok and line or (RED .. "<row error>|r"))
        row:Show()
        -- GetStringWidth is only valid once the FontString HAS text and a font,
        -- which is exactly here — the documented order-of-attach hazard, avoided
        -- by measuring after SetText rather than predicting before it.
        ns.HudChrome.SetBracketExtent(e.item, row.text:GetStringWidth())
      end)
      if okRow then drawn = drawn + 1 end
    end
  end
  -- M4.6 §4.8 — the `shards N/5  lit N` line is OFF the HUD by default.  Player
  -- read it as debug information they never looked at, and they are right that it
  -- is not a rotation cue: shards are already on the rail and in the pane's dot
  -- row, and `lit` is instrumentation for US.
  --
  -- ⚠ It is MOVED, not deleted, and that distinction matters.  `lit` is the
  -- STRICTNESS METER — the thing that tells us whether the rules are too loose —
  -- and §4.5b is an open strictness defect, so deleting the readout while the
  -- defect is open would remove the instrument we need to confirm the fix.  It
  -- still draws under `hud debug`, and `hud dump` / `hud status` / `probe` all
  -- carry it unconditionally.
  local s = summary
  if D.verbose then
    s = ensureSummary()
    if s then
      local ok, line = pcall(summaryLine)
      s.text:SetText(ok and line or "")
      s:Show()
    end
  elseif s then
    s:Hide()
  end
  return drawn
end

-- The same readout, to CHAT.  The on-screen rows depend on our frame layer
-- behaving; chat does not.  "Write out what you're tracking" should never be
-- contingent on the fancy path working, so this is also the copy/pasteable form
-- for talking about what we're seeing.
function D.Dump()
  ns.Heading("HUD rows — the dot score, per item")
  if not (ns.Hud and ns.Hud.on) then
    ns.Print("  |cffff4040the HUD is off|r — /cdmp hud first.")
    return
  end
  local ok, line = pcall(summaryLine)
  ns.Print("  " .. (ok and line or "<summary error>"))
  for _, viewer in ipairs({ "EssentialCooldownViewer", "UtilityCooldownViewer",
                            "BuffBarCooldownViewer", "BuffIconCooldownViewer" }) do
    for key, e in pairs(ns.Hud.items) do
      if e.viewer == viewer then
        local okL, l = pcall(lineFor, key, e)
        if okL and l then ns.Printf("  %s", l)
        elseif not okL then ns.Print("  <row error>") end
      end
    end
  end
end

local function hideAll()
  for _, f in pairs(rows) do
    f.text:SetText("")
    f:Hide()
  end
  -- Collapse the brackets back to icon width — but ONLY for items that are
  -- CURRENTLY BOUND.  SetBracketExtent re-Apply()s, which Show()s the edges, and
  -- `rows` is a weak table that still holds frames from earlier layouts; walking
  -- it here would re-show chrome on items the registry has already let go of.
  for _, e in pairs((ns.Hud and ns.Hud.items) or {}) do
    if e.item then pcall(ns.HudChrome.SetBracketExtent, e.item, 0) end
  end
  if summary then summary:Hide() end
end

function D.Set(on)
  D.on = on and true or false
  if D.on then
    if not (ns.Hud and ns.Hud.on) then
      ns.Print("rows armed, but the HUD is off — |cffffffff/cdmp hud|r to turn it on.")
    end
    if not ticker then ticker = C_Timer.NewTicker(REFRESH, D.Refresh) end
    pcall(D.Refresh)
  else
    if ticker then ticker:Cancel(); ticker = nil end
    hideAll()
  end
  if ns.db and ns.db.hud then ns.db.hud.rows = D.on end
end

-- `/cdmp hud debug` — the SAME rows with everything else the HUD knows appended.
-- One module, one row builder, a flag; never a second renderer to drift.
function D.SetVerbose(on)
  D.verbose = on and true or false
  if ns.db and ns.db.hud then ns.db.hud.verbose = D.verbose end
  if D.verbose then
    -- Print BEFORE doing any work.  v0.8.0 refreshed first, so a throw in the
    -- frame layer was caught by the slash dispatcher's pcall and the ON message
    -- never printed — making a crash look exactly like "the command did nothing".
    ns.Print("row verbose |cff88ff88ON|r — identity, cooldown, cost (raw + shards), "
      .. "presence source and override state appended to every row.")
  else
    ns.Print("row verbose |cffff8080OFF|r — back to dot level + reasons.")
  end
  local okR, drawn = pcall(D.Refresh)
  if not okR then
    ns.Printf("|cffff4040on-screen rows failed:|r %s — falling back to chat.", tostring(drawn))
  elseif (drawn or 0) == 0 then
    ns.Print("|cffffd100no rows drawn|r (0 bound items?) — see the chat dump below.")
  end
  if D.verbose then pcall(D.Dump) end
end

-- Called by HudCore when the HUD itself goes off.  This STOPS the ticker as well
-- as hiding — but deliberately does NOT write `db.rows`, so the user's rows-on
-- preference survives a HUD toggle.  (D.Set is the preference; this is the
-- lifecycle.)  Without the stop the ticker outlived the HUD forever: harmless,
-- since Refresh early-returns, but it's a timer that can never die.
function D.Hide()
  if ticker then ticker:Cancel(); ticker = nil end
  hideAll()
end
