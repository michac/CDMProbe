-- Layout.lua — probe: is the Cooldown Manager's layout data addon-writable?
-- Answers the spec §7 open question that gates the config-delivery model:
--   can a (tainted) addon call C_CooldownViewer.SetLayoutData() out of combat
--   without a blocked-action / taint error?  If YES → we can *auto-apply* the
--   opinionated per-spec Cooldown Layout instead of asking the user to paste.
--
-- Test design (safe): C_CooldownViewer.GetLayoutData()/SetLayoutData() is the
-- game's own full-store persistence round-trip (see Blizzard's
-- CooldownViewerSettingsDataStoreSerialization.lua). So reading the current data
-- and writing the SAME bytes back is a functional NO-OP; the only thing under
-- test is whether the call is *permitted* from addon (tainted) code. We back the
-- original string up to SavedVariables first, so it's re-importable no matter what.
local ADDON, ns = ...

local CV = C_CooldownViewer

-- Split C_CooldownViewer's functions into get/set/other so any *other* setters
-- (reorder/active-layout/etc.) surface too, not just SetLayoutData.
local function listFns()
  local getters, setters, other = {}, {}, {}
  if type(CV) ~= "table" then return getters, setters, other end
  for k, v in pairs(CV) do
    if type(v) == "function" then
      if k:find("^Get") then getters[#getters + 1] = k
      elseif k:find("^Set") then setters[#setters + 1] = k
      else other[#other + 1] = k end
    end
  end
  table.sort(getters); table.sort(setters); table.sort(other)
  return getters, setters, other
end

ns.RegisterCommand("layout",
  "probe whether C_CooldownViewer.SetLayoutData() is addon-writable (auto-apply viability). add 'write' to attempt the safe round-trip.",
  function(rest)
    rest = (rest or ""):lower()
    local doWrite = rest:find("write") ~= nil
    local key = "layout_" .. (InCombatLockdown() and "combat" or "ooc")
    ns.BeginCapture()
    ns.Heading(string.format("Layout probe  (in combat: %s)", tostring(InCombatLockdown())))

    if type(CV) ~= "table" then
      ns.Print("  |cffff4040C_CooldownViewer absent|r")
      ns.EndCapture(key)
      return
    end

    -- 1) Enumerate the API surface (reveals every getter/setter available).
    local getters, setters, other = listFns()
    ns.Printf("  getters: %s", #getters > 0 and table.concat(getters, ", ") or "(none)")
    ns.Printf("  setters: %s", #setters > 0 and table.concat(setters, ", ") or "(none)")
    if #other > 0 then ns.Printf("  other:   %s", table.concat(other, ", ")) end

    local hasGet = type(CV.GetLayoutData) == "function"
    local hasSet = type(CV.SetLayoutData) == "function"
    ns.Printf("  GetLayoutData: %s   SetLayoutData: %s",
      hasGet and "|cff88ff88present|r" or "|cffff4040missing|r",
      hasSet and "|cff88ff88present|r" or "|cffff4040missing|r")

    -- 2) Read the current full layout data store (+ back it up).
    local d0
    if hasGet then
      local ok, data = pcall(CV.GetLayoutData)
      if not ok then
        ns.Printf("  GetLayoutData() |cffff4040errored:|r %s", tostring(data))
      elseif ns.IsSecret(data) then
        ns.Print("  GetLayoutData() returned |cffff4040<secret>|r (unexpected)")
      elseif type(data) ~= "string" then
        ns.Printf("  GetLayoutData() returned %s (expected string)", type(data))
      else
        d0 = data
        local ver = data:match("^([^|]*)|")
        ns.Printf("  current data: %d bytes, encodingVersion=%s, head=%q",
          #data, tostring(ver), data:sub(1, 24))
        ns.db.layoutBackup = data  -- safety net: exact original, re-importable
        ns.Print("  backed up original to SavedVariables (CDMProbeDB.layoutBackup)")
      end
    end

    -- 3) The write test (opt-in).
    if not doWrite then
      ns.Print("read-only. To attempt the safe round-trip write, run |cffffffff/cdmp layout write|r |cffffd100OUT OF COMBAT first|r.")
      ns.Print("when you do, watch chat for a red |cffff4040blocked-action / taint|r error — that = NOT addon-writable.")
      ns.EndCapture(key)
      return
    end

    if not (hasSet and d0) then
      ns.Print("  |cffff4040cannot write:|r no SetLayoutData or no readable current data")
      ns.EndCapture(key)
      return
    end

    -- Write the SAME bytes back — the game's own persistence path, so a no-op;
    -- the only thing under test is whether a tainted addon is allowed to call it.
    ns.Printf("  calling SetLayoutData() with identical %d bytes ...", #d0)
    local ok, err = pcall(CV.SetLayoutData, d0)
    if not ok then
      ns.Printf("  SetLayoutData() |cffff4040errored:|r %s", tostring(err))
      ns.Print("  → likely protected / not addon-callable here. (If in combat, retry out of combat.)")
    else
      ns.Print("  SetLayoutData() returned |cff88ff88without error|r")
      local ok2, d1 = pcall(CV.GetLayoutData)
      if ok2 and type(d1) == "string" then
        ns.Printf("  read-back: %s (%d bytes)",
          d1 == d0 and "|cff88ff88identical|r" or "|cffffd100changed|r", #d1)
      end
      ns.Print("  |cffffd100Now check:|r did a red \"blocked/taint\" error pop? NO error at all → |cff88ff88SetLayoutData IS addon-writable → auto-apply viable|r.")
    end
    ns.EndCapture(key)
  end)
