-- json_fixture.lua — the Phase-2 golden LOADER for the busted diff-harness.
--
-- The goldens live in the WOW REPO (source of truth, versioned with the contract),
-- NOT in this addon repo (corpus/goldens/README.md §1).  This addon repo is a
-- separate git root checked out inside the workspace, so the corpus is a SIBLING on
-- disk: projects/cooldown-hud/addon/ (here) <-> projects/cooldown-hud/corpus/goldens.
--
-- Path resolution (configurable, per the README):
--   1. $CDMP_GOLDENS_DIR if set (a standalone checkout points it at a clone),
--   2. else the computed sibling relative to THIS file.
-- Decoding is via **dkjson** (luarocks), the chosen format so the goldens stay one
-- diffable artifact next to the contract rather than generated Lua tables.
local json = require("dkjson")

local M = {}

local HERE = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
-- HERE = .../addon/CDMProbe/tests/  ->  ../../../corpus/goldens
local DEFAULT_DIR = HERE .. "../../../corpus/goldens"

function M.goldensDir()
  return os.getenv("CDMP_GOLDENS_DIR") or DEFAULT_DIR
end

local function readFile(path)
  local f, err = io.open(path, "r")
  if not f then return nil, err end
  local data = f:read("*a")
  f:close()
  return data
end

-- Decode one goldens JSON file (state.json / guidance.json) to a Lua table.
function M.load(scenario, which)
  local path = M.goldensDir() .. "/" .. scenario .. "/" .. which
  local data, err = readFile(path)
  if not data then error("json_fixture: cannot read " .. path .. ": " .. tostring(err)) end
  local obj, _, derr = json.decode(data, 1, nil)
  if not obj then error("json_fixture: bad JSON in " .. path .. ": " .. tostring(derr)) end
  return obj
end

function M.state(scenario)    return M.load(scenario, "state.json") end
function M.guidance(scenario) return M.load(scenario, "guidance.json") end

return M
