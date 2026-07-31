-- case_builders.lua — the two constructors that turn a PURE-DATA fixture case into live
-- objects: `mint` (markers -> secrets / poisoned tables) and `buildItem` (a row's `frame`
-- table -> a CDM item frame).
--
-- WHY A SEPARATE FILE.  These used to be file-locals in `spec/cdm_cases_spec.lua`, where
-- nothing could test them — and `buildItem` in particular is a CLOSED WHITELIST of the
-- fields it copies onto the item, so a case writing `frame = { PandemicIcon = … }` was
-- silently dropped and the case passed for the wrong reason.  That is the harness-lies
-- shape `harness_spec.lua` exists to catch, so the builders move here and get proved
-- there, next to H.poison / H.secretTable / the default-inert client fakes.
--
-- A FACTORY, not a module: both constructors close over the harness (`H`, for the secret
-- and poison registries) and over the fixture's `SECRET` sentinel.  Call it once per spec
-- file:
--     local mk = dofile(dir .. "../case_builders.lua")(H, FX.SECRET)
--     mk.mint(v) · mk.buildItem(cid, frameSpec)
return function(H, SECRET)
  local M = {}

  -- The fixture is PURE DATA, so it cannot mint a secret or a poisoned table itself.  It
  -- writes a marker and this turns it into the real thing:
  --   SECRET                             -> a secret VALUE (a sentinel table, because
  --                                         H.secret is keyed by value and marking a number
  --                                         would mark every occurrence of it in the case)
  --   { __secretTable = { … } }          -> a table that refuses indexing outright
  --   { __poison = { fields = {…}, raises = {"startTime"} } }
  --                                      -> a table that indexes fine EXCEPT on those fields
  local function mint(v)
    if v == SECRET then return H.secretValue() end
    if type(v) == "table" and v.__secretTable then
      local t = {}
      for k, e in pairs(v.__secretTable) do t[k] = mint(e) end
      return H.markSecretTable(t)
    end
    if type(v) == "table" and v.__poison then
      local t = {}
      for k, e in pairs(v.__poison.fields or {}) do t[k] = mint(e) end
      return H.poison(t, v.__poison.raises)
    end
    if type(v) == "table" then
      local t = {}
      for k, e in pairs(v) do t[k] = mint(e) end
      return t
    end
    return v
  end
  M.mint = mint

  -- One CDM item frame.  Deliberately a plain table, not H.newStub(): State probes it with
  -- ns.HasMethod, so "this row does not expose IsActive at all" has to be expressible.
  --
  -- ⚠ THE NAMED FIELDS BELOW ARE A WHITELIST, and `fields` / `methods` are the escape
  -- hatches that keep it from being a silent one:
  --   fields  = { PandemicIcon = {}, auraDataUnit = "target" }
  --             copied VERBATIM onto the item, routed through `mint`, so SECRET / a poisoned
  --             index / plain absence all work for free.  This is how the §3.10 widget-
  --             internals reads (`item.auraDataUnit`, `item.PandemicIcon`) are expressed.
  --   methods = { "GetAuraDataUnit", "CheckPandemicTimeDisplay" }
  --             defined as no-op stubs, purely so `ns.HasMethod` answers TRUE.  Their
  --             ABSENCE is the point: a bind-time capability check (rule 17b) has to be
  --             falsifiable, and by default an item here exposes none of them, so a case
  --             states "the mechanism is present" by listing it and "absent" by not.
  --             ⚠ Never CALL these in the code under test — they are a capability probe.
  function M.buildItem(cid, f)
    local it = {}
    if f.cooldownIDSecret then it.cooldownID = H.secretValue()
    elseif f.noCooldownID ~= true then it.cooldownID = cid end
    if f.getCooldownID ~= false then
      it.GetCooldownID = function()
        if f.getCooldownIDThrows then error("mock: GetCooldownID refused", 0) end
        return cid
      end
    end
    if f.isActive ~= nil then
      local secret = H.secretValue()
      it.IsActive = function()
        if f.isActive == "throws" then error("mock: IsActive refused", 0) end
        if f.isActive == "secret" then return secret end
        return f.isActive
      end
    end
    if f.isShown ~= nil then
      it.IsShown = function()
        if f.isShown == "throws" then error("mock: IsShown refused", 0) end
        return f.isShown
      end
    end
    if f.hideWhenInactive ~= nil and f.hideWhenInactive ~= "throws" then
      it.hideWhenInactive = f.hideWhenInactive
    end
    for _, name in ipairs(f.methods or {}) do
      it[name] = function() end
    end
    for k, v in pairs(f.fields or {}) do it[k] = mint(v) end
    -- The alert choke point.  hooksecurefunc is a no-op off-game, so the hook installs and
    -- does nothing; the script drives St.OnAlert directly, exactly as the shipped hook does.
    it.TriggerAlertEvent = function() end
    -- ⚠ POISON LAST.  H.poison moves every existing key into a shadow store, so anything
    -- written afterwards would live on the raw table and bypass the metatable — and the
    -- named raising fields have to be the ones the copy above just installed.
    local raises = {}
    for _, name in ipairs(f.raises or {}) do raises[#raises + 1] = name end
    if f.hideWhenInactive == "throws" then raises[#raises + 1] = "hideWhenInactive" end
    if #raises > 0 then H.poison(it, raises) end
    return it
  end

  return M
end
