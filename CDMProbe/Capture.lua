-- Capture — the one way data leaves this addon.
--
-- Every recorder writes to `<DB>.captures.<stream>`; `wowkb.capture` is the only reader.
-- Contract: .claude/skills/wow-developer/references/capture-and-dump-standard.md
--
-- Vendored: copy this file into another addon and adapt it. The SavedVariables shape is
-- the contract; everything below it is not.

local ADDON, ns = ...

ns.Capture = {}
local Capture = ns.Capture

local Stream = {}
Stream.__index = Stream

-- Readability classes. A Secret Value must never be formatted or indexed.
local function isSecret(v)
  if type(issecretvalue) ~= "function" then return false end
  local ok, s = pcall(issecretvalue, v)
  return ok and s
end

local function isSecretTable(v)
  if type(issecrettable) ~= "function" then return false end
  local ok, s = pcall(issecrettable, v)
  return ok and s
end

-- One line stays one line: no colour escapes, no quotes, no newlines.
local function flatten(s)
  s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  s = s:gsub('"', ""):gsub("[\r\n]+", " ")
  return s
end

--- Render a game value for a capture line. The only sanctioned route.
function Capture.Safe(v)
  if v == nil then return "<nil>" end
  if isSecret(v) then return "<secret>" end
  if isSecretTable(v) then return "<secrettable>" end
  local t = type(v)
  if t == "number" or t == "boolean" then return tostring(v) end
  if t == "string" then return flatten(v) end
  return "<" .. t .. ">"
end

--- Open a stream. Safe before ADDON_LOADED: the handle is live, writes are dropped.
-- opts.sessions and opts.cap are REQUIRED; there is no unbounded ring.
function Capture.Open(name, opts)
  opts = opts or {}
  assert(type(name) == "string" and name ~= "", "Capture.Open: stream name required")
  assert(type(opts.sessions) == "number" and opts.sessions > 0,
         "Capture.Open: opts.sessions required")
  assert(type(opts.cap) == "number" and opts.cap > 0, "Capture.Open: opts.cap required")
  return setmetatable({
    name = name, sessions = opts.sessions, cap = opts.cap,
    dedup = opts.dedup and true or false,
    session = nil, last = nil,
  }, Stream)
end

-- The session is lazy: a stream that never writes must not burn a ring slot.
function Stream:_session()
  if self.session then return self.session end
  if not ns.db then return nil end

  local captures = ns.db.captures
  if type(captures) ~= "table" then captures = {}; ns.db.captures = captures end

  local ring = captures[self.name]
  if type(ring) ~= "table" then ring = {}; captures[self.name] = ring end

  local sess = {
    started = date("%Y-%m-%d %H:%M:%S"),
    version = ns.version,
    meta = {},
    lines = {},
    rows = {},
  }
  ring[#ring + 1] = sess
  while #ring > self.sessions do table.remove(ring, 1) end

  self.session, self.last = sess, nil
  return sess
end

function Stream:_append(list, entry)
  list[#list + 1] = entry
  while #list > self.cap do table.remove(list, 1) end
end

--- A capture line. Skipped when identical to the previous line and dedup is on.
function Stream:Line(fmt, ...)
  local sess = self:_session()
  if not sess then return end
  local text = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
  if self.dedup and text == self.last then return end
  self.last = text
  self:_append(sess.lines, text)
end

--- An edge marker: always written, never deduped. Use for transitions the log exists
--- to record — they must not be conditional on something else changing.
function Stream:Mark(fmt, ...)
  local sess = self:_session()
  if not sess then return end
  local text = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
  self:_append(sess.lines, text)
end

--- A structured row, for a stream a grader consumes.
function Stream:Row(tbl)
  local sess = self:_session()
  if not sess or type(tbl) ~= "table" then return end
  self:_append(sess.rows, tbl)
end

--- Session-scoped context. Late binding is expected: re-stamp on a spec swap rather
--- than mislabelling the whole session.
function Stream:Meta(k, v)
  local sess = self:_session()
  if not sess then return end
  sess.meta[k] = Capture.Safe(v)
end

--- Discard this session's content and restart it. For one-run streams.
function Stream:Wipe()
  local sess = self:_session()
  if not sess then return end
  sess.lines, sess.rows, self.last = {}, {}, nil
  sess.started = date("%Y-%m-%d %H:%M:%S")
end

--- Entry count, for a chat confirmation.
function Stream:Count()
  local sess = self.session
  if not sess then return 0 end
  return #sess.lines + #sess.rows
end
