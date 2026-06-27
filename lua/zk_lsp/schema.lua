local M = {}

local cache = {}

local function cache_key(kind)
  local cfg = require("zk_lsp.config").get()
  return table.concat({ kind, cfg.executable, cfg.wiki_root }, "\n")
end

local function get_cached(kind, loader)
  local key = cache_key(kind)
  if cache[key] ~= nil then
    return cache[key]
  end
  local value, err = loader()
  if value ~= nil then
    cache[key] = value
  end
  return value, err
end

function M.clear()
  cache = {}
end

function M.fields()
  return get_cached("fields", function()
    return require("zk_lsp.cli").metadata_fields()
  end)
end

function M.defaults()
  return get_cached("defaults", function()
    return require("zk_lsp.cli").metadata_defaults()
  end)
end

function M.json_schema()
  return get_cached("json_schema", function()
    return require("zk_lsp.cli").metadata_json_schema()
  end)
end

function M.field_map()
  local fields, err = M.fields()
  if not fields then
    return nil, err
  end
  local map = {}
  for _, field in ipairs(fields.fields or {}) do
    map[field.path] = field
  end
  return map
end

function M.filter_metadata(metadata)
  local field_map = M.field_map() or {}
  local filtered = {}
  local skipped = {}
  for key, value in pairs(metadata or {}) do
    if field_map[key] then
      filtered[key] = value
    else
      skipped[#skipped + 1] = key
    end
  end
  table.sort(skipped)
  return filtered, skipped
end

return M
