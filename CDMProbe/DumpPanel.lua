-- DumpPanel — captures a human takes at a moment, by button.
--
-- A dump is triggered mid-pull, at a moment only the player can recognise. It is a
-- button, never a typed subcommand. Everything lands on the `dump` capture stream, so
-- `wowkb.capture cdmp dump` still reads it and `[copy]` needs no /reload.
--
-- Contract: .claude/skills/wow-developer/references/capture-and-dump-standard.md

local ADDON, ns = ...

ns.Dumps = {}
local D = ns.Dumps

local SESSIONS, CAP = 4, 4000
local COPY_PAGE = 30000        -- chars per copy page; SetText stalls on very large payloads
local ROWS = 10                -- visible list rows
local MARK = "== dump "

local stream = ns.Capture.Open("dump", { sessions = SESSIONS, cap = CAP })

local registry, order = {}, {}
local entries = {}             -- in-memory index: { n, t, id, blurb, lines }
local panel                    -- built lazily, never in combat

--- Register a dump button. `capture` returns an array of plain-text lines.
function D.Register(def)
  assert(type(def) == "table" and def.id and def.capture, "Dumps.Register: id + capture required")
  if not registry[def.id] then order[#order + 1] = def.id end
  registry[def.id] = def
end

local function describe(def)
  if type(def.blurb) ~= "function" then return def.label or def.id end
  local ok, s = pcall(def.blurb)
  return (ok and type(s) == "string") and s or (def.label or def.id)
end

--- Take a dump: write it to the stream and index it for the list.
function D.Take(id)
  local def = registry[id]
  if not def then return end

  local ok, lines = pcall(def.capture)
  if not ok or type(lines) ~= "table" then
    ns.Printf("dump '%s' failed: %s", id, ns.Capture.Safe(lines))
    return
  end

  local blurb = describe(def)
  local n = #entries + 1
  local t = date("%H:%M:%S")

  stream:Mark("%s#%d %s %s · %s", MARK, n, t, id, blurb)
  for _, ln in ipairs(lines) do stream:Line("%s", tostring(ln)) end

  entries[n] = { n = n, t = t, id = id, blurb = blurb, lines = lines }
  if panel and panel:IsShown() then D.Refresh() end
  ns.Printf("dump #%d — %s (%d lines). |cffffffff/reload|r to flush to disk.", n, blurb, #lines)
end

-- Rebuild the index from the newest stored session, so the list survives a /reload.
function D.Restore()
  local ring = ns.db and ns.db.captures and ns.db.captures.dump
  if type(ring) ~= "table" or #ring == 0 then return end
  local sess = ring[#ring]
  local cur
  for _, ln in ipairs(sess.lines or {}) do
    local head = ln:match("^" .. MARK .. "(.+)$")
    if head then
      local num, t, rest = head:match("^#(%d+)%s+(%S+)%s+(.+)$")
      cur = { n = tonumber(num) or (#entries + 1), t = t or "?",
              id = (rest or ""):match("^(%S+)") or "?", blurb = rest or "?", lines = {} }
      entries[#entries + 1] = cur
    elseif cur then
      cur.lines[#cur.lines + 1] = ln
    end
  end
end

-- UI --------------------------------------------------------------------------

local function edge(f, r, g, b, a)
  for _, p in ipairs({ { "TOPLEFT", "TOPRIGHT", 0, 1 }, { "BOTTOMLEFT", "BOTTOMRIGHT", 0, -1 },
                       { "TOPLEFT", "BOTTOMLEFT", -1, 0 }, { "TOPRIGHT", "BOTTOMRIGHT", 1, 0 } }) do
    local t = f:CreateTexture(nil, "BORDER")
    t:SetColorTexture(r, g, b, a)
    t:SetPoint(p[1], f, p[1], p[3], p[4])
    t:SetPoint(p[2], f, p[2], p[3], p[4])
    if p[3] == 0 then t:SetHeight(1) else t:SetWidth(1) end
  end
end

local function button(parent, text, w, h, onClick)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(w, h)
  local bg = b:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(b)
  bg:SetColorTexture(0.16, 0.16, 0.20, 0.9)
  edge(b, 0.4, 0.4, 0.5, 0.8)
  local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetPoint("CENTER")
  fs:SetText(text)
  b.text = fs
  b:SetScript("OnEnter", function() bg:SetColorTexture(0.26, 0.26, 0.34, 0.95) end)
  b:SetScript("OnLeave", function() bg:SetColorTexture(0.16, 0.16, 0.20, 0.9) end)
  b:SetScript("OnClick", onClick)
  return b
end

-- The copy surface: WoW has no clipboard API, so the payload goes into a multiline
-- EditBox, selected, and the user's own Ctrl+C does the work.
local function showCopy(entry)
  local f = panel.copy
  local text = table.concat(entry.lines, "\n")
  f.pages, f.page = {}, 1
  for i = 1, math.max(1, math.ceil(#text / COPY_PAGE)) do
    f.pages[i] = text:sub((i - 1) * COPY_PAGE + 1, i * COPY_PAGE)
  end
  f.title:SetText(("#%d %s · %s   (page 1/%d — Ctrl+C)"):format(
    entry.n, entry.id, entry.blurb, #f.pages))
  f.box:SetText(f.pages[1])
  f.box:HighlightText()
  f.box:SetFocus()
  f:Show()
end

local function buildCopy(parent)
  local f = CreateFrame("Frame", nil, parent)
  f:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -8)
  f:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -8, 8)
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(f)
  bg:SetColorTexture(0.05, 0.05, 0.07, 0.97)
  edge(f, 0.5, 0.5, 0.6, 0.9)

  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -8)

  local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -26)
  scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -30, 34)

  local box = CreateFrame("EditBox", nil, scroll)
  box:SetMultiLine(true)
  box:SetMaxLetters(0)          -- the default cap is unmeasured; make it not matter
  box:SetMaxBytes(0)
  box:SetAutoFocus(false)
  box:SetFontObject("GameFontHighlightSmall")
  box:SetWidth(420)
  box:SetScript("OnEscapePressed", function() f:Hide() end)
  -- Read-only by reselection: revert an edit and re-select, as WeakAuras' debug log does.
  box:SetScript("OnTextChanged", function(self, user)
    if user then self:SetText(f.pages[f.page] or ""); self:HighlightText() end
  end)
  box:SetScript("OnMouseUp", function(self) self:HighlightText() end)
  scroll:SetScrollChild(box)
  f.box = box

  button(f, "Close", 60, 20, function() f:Hide() end)
      :SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 8)
  f.next = button(f, "Next page", 80, 20, function()
    f.page = (f.page % #f.pages) + 1
    f.title:SetText(f.title:GetText():gsub("page %d+/", "page " .. f.page .. "/"))
    box:SetText(f.pages[f.page]); box:HighlightText(); box:SetFocus()
  end)
  f.next:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8, 8)

  f:Hide()
  return f
end

local function build()
  local root = CreateFrame("Frame", nil, UIParent)
  root:SetSize(460, 380)
  root:SetFrameStrata("DIALOG")
  root:SetMovable(true)
  root:EnableMouse(true)
  root:RegisterForDrag("LeftButton")
  root:SetScript("OnDragStart", root.StartMoving)
  root:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local db = ns.db and ns.db.dumpPanel
    if db then
      local p, _, rp, x, y = self:GetPoint()
      db.point, db.relPoint, db.x, db.y = p, rp, x, y
    end
  end)

  local bg = root:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(root)
  bg:SetColorTexture(0.08, 0.08, 0.10, 0.94)
  edge(root, 0.45, 0.45, 0.55, 0.9)

  local title = root:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", root, "TOPLEFT", 10, -10)
  title:SetText("CDMProbe — dumps")

  button(root, "×", 20, 20, function() root:Hide() end)
      :SetPoint("TOPRIGHT", root, "TOPRIGHT", -8, -8)

  -- Button grid: one per registered dump.
  local grid = CreateFrame("Frame", nil, root)
  grid:SetPoint("TOPLEFT", root, "TOPLEFT", 10, -34)
  grid:SetPoint("TOPRIGHT", root, "TOPRIGHT", -10, -34)
  grid:SetHeight(1)
  local x, y, rowH = 0, 0, 22
  for _, id in ipairs(order) do
    local def = registry[id]
    local b = button(grid, def.label or id, 140, 20, function() D.Take(id) end)
    if x + 140 > 440 then x, y = 0, y + rowH end
    b:SetPoint("TOPLEFT", grid, "TOPLEFT", x, -y)
    x = x + 146
  end
  grid:SetHeight(y + rowH)

  -- List of captures taken.
  local list = CreateFrame("Frame", nil, root)
  list:SetPoint("TOPLEFT", grid, "BOTTOMLEFT", 0, -8)
  list:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", -10, 10)
  root.rows = {}
  for i = 1, ROWS do
    local r = CreateFrame("Frame", nil, list)
    r:SetHeight(20)
    r:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -(i - 1) * 21)
    r:SetPoint("TOPRIGHT", list, "TOPRIGHT", 0, -(i - 1) * 21)
    r.label = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.label:SetPoint("LEFT", r, "LEFT", 2, 0)
    r.label:SetJustifyH("LEFT")
    r.copy = button(r, "copy", 44, 18, function() if r.entry then showCopy(r.entry) end end)
    r.copy:SetPoint("RIGHT", r, "RIGHT", -2, 0)
    r.label:SetPoint("RIGHT", r.copy, "LEFT", -4, 0)
    root.rows[i] = r
  end

  root.copy = buildCopy(root)
  root:Hide()
  return root
end

function D.Refresh()
  if not panel then return end
  local total = #entries
  for i, r in ipairs(panel.rows) do
    local e = entries[total - i + 1]      -- newest first
    r.entry = e
    if e then
      r.label:SetText(("|cff888888#%d|r  %s  %s"):format(e.n, e.t, e.blurb))
      r.copy:Show(); r:Show()
    else
      r.label:SetText(""); r.copy:Hide()
    end
  end
end

function D.Toggle()
  if InCombatLockdown() and not panel then
    ns.Print("can't build the dump panel in combat — open it once out of combat.")
    return
  end
  if #entries == 0 then D.Restore() end
  panel = panel or build()
  if panel:IsShown() then
    panel:Hide()
  else
    local db = (ns.db and ns.db.dumpPanel) or {}
    panel:ClearAllPoints()
    if db.point then
      panel:SetPoint(db.point, UIParent, db.relPoint or db.point, db.x or 0, db.y or 0)
    else
      panel:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    D.Refresh()
    panel:Show()
  end
end

ns.RegisterCommand("dump", "toggle the dump panel — buttons that capture a moment", function()
  D.Toggle()
end)
