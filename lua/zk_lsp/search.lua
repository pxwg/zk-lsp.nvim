local cli = require("zk_lsp.cli")
local config = require("zk_lsp.config")
local schema = require("zk_lsp.schema")
local util = require("zk_lsp.util")

local M = {}

local INACTIVE_RELATIONS = {
  archived = true,
  legacy = true,
}

local SEARCH_MODES = {
  { mode = "title", label = "Title", desc = "precise title search" },
  { mode = "all", label = "All", desc = "title, id, metadata, and tags" },
  { mode = "alias", label = "Alias", desc = "metadata aliases" },
  { mode = "keyword", label = "Keyword", desc = "metadata keywords" },
  { mode = "abstract", label = "Abstract", desc = "metadata abstracts" },
  { mode = "tag", label = "Tag", desc = "local and provider tags" },
  { mode = "todo", label = "Todo", desc = "todo notes by title" },
  { mode = "done", label = "Done", desc = "done notes by title" },
  { mode = "orphans", label = "Orphans", desc = "notes without inbound references" },
}

local MODE_BY_NAME = {}
for _, item in ipairs(SEARCH_MODES) do
  MODE_BY_NAME[item.mode] = item
end

local function list_or_empty(value)
  return type(value) == "table" and value or {}
end

local function is_array(tbl)
  if type(tbl) ~= "table" then
    return false
  end
  local n = 0
  for key, _ in pairs(tbl) do
    if type(key) ~= "number" then
      return false
    end
    n = math.max(n, key)
  end
  return n == #tbl
end

local function value_parts(value, out)
  out = out or {}
  local value_type = type(value)
  if value_type == "string" then
    if value ~= "" then
      out[#out + 1] = value
    end
  elseif value_type == "number" or value_type == "boolean" then
    out[#out + 1] = tostring(value)
  elseif value_type == "table" then
    for _, item in pairs(value) do
      value_parts(item, out)
    end
  end
  return out
end

local function get_path(tbl, path)
  local cur = tbl
  for part in path:gmatch("[^.]+") do
    if type(cur) ~= "table" then
      return nil
    end
    cur = cur[part]
  end
  return cur
end

local function set_path(tbl, path, value)
  local cur = tbl
  local parts = vim.split(path, ".", { plain = true, trimempty = true })
  for index = 1, #parts - 1 do
    local part = parts[index]
    if type(cur[part]) ~= "table" or is_array(cur[part]) then
      cur[part] = {}
    end
    cur = cur[part]
  end
  cur[parts[#parts]] = value
end

local function merge_list(target, values)
  local seen = {}
  for _, value in ipairs(target or {}) do
    seen[value] = true
  end
  local out = vim.deepcopy(target or {})
  for _, value in ipairs(values or {}) do
    if not seen[value] then
      out[#out + 1] = value
      seen[value] = true
    end
  end
  table.sort(out)
  return out
end

local function merge_metadata(note, provider_name, metadata)
  if type(metadata) ~= "table" then
    return
  end
  note.metadata = note.metadata or {}
  for key, value in pairs(metadata) do
    if note.metadata[key] == nil then
      note.metadata[key] = value
    else
      local namespaced = provider_name .. "." .. key
      set_path(note.metadata, namespaced, value)
    end
  end
end

local function apply_patch(note, provider_name, patch)
  if type(patch) ~= "table" then
    return
  end
  if patch.title_line and not note.title_line then
    note.title_line = patch.title_line
  end
  if patch.tags then
    note.tags = merge_list(note.tags or {}, patch.tags)
  end
  if patch.references then
    note.references = note.references or {}
    for id, value in pairs(patch.references) do
      if value then
        note.references[id] = true
      end
    end
  end
  merge_metadata(note, provider_name, patch.metadata)
end

local function provider_specs()
  local opts = config.get().search or {}
  local providers = {}
  if opts.providers and opts.providers.local_note ~= false then
    providers[#providers + 1] = require("zk_lsp.providers.local_note").new()
  end
  for _, provider in ipairs(opts.providers or {}) do
    if type(provider) == "function" then
      local built = provider({ config = config.get() })
      if built then
        providers[#providers + 1] = built
      end
    elseif type(provider) == "table" then
      providers[#providers + 1] = provider
    end
  end
  return providers
end

local function enrich_notes(notes)
  for _, provider in ipairs(provider_specs()) do
    if provider.enrich then
      for _, note in ipairs(notes) do
        local ok, patch = pcall(provider.enrich, note, { config = config.get() })
        if ok then
          apply_patch(note, provider.name or "provider", patch)
        else
          util.notify("Search provider " .. tostring(provider.name) .. " failed: " .. patch, vim.log.levels.WARN)
        end
      end
    end
  end
  return notes
end

local function note_text(note, mode)
  local parts = {}
  local metadata = note.metadata or {}
  if mode == "title" then
    parts = { note.title or "" }
  elseif mode == "alias" then
    parts = value_parts(metadata.aliases)
  elseif mode == "keyword" then
    parts = value_parts(metadata.keywords)
  elseif mode == "abstract" then
    parts = { metadata.abstract or "" }
  elseif mode == "tag" then
    parts = value_parts(note.tags)
  elseif mode == "all" then
    parts = { note.title or "", note.id or "" }
    value_parts(metadata, parts)
    value_parts(note.tags, parts)
  else
    parts = { note.title or "" }
  end
  return table.concat(parts, " ")
end

local function relation(note)
  local value = get_path(note.metadata or {}, "relation") or note.relation or ""
  if type(value) ~= "string" then
    return ""
  end
  return vim.trim(value):lower()
end

local function is_inactive_note(note)
  return INACTIVE_RELATIONS[relation(note)] == true
end

local function has_tag(note, tag)
  for _, value in ipairs(note.tags or {}) do
    if value == tag then
      return true
    end
  end
  return false
end

local function checklist_status(note)
  return get_path(note.metadata or {}, "checklist-status")
end

local function orphan_notes(notes)
  local referenced = {}
  for _, note in ipairs(notes) do
    for id, enabled in pairs(note.references or {}) do
      if enabled and id ~= note.id then
        referenced[id] = true
      end
    end
  end
  local out = {}
  for _, note in ipairs(notes) do
    if not referenced[note.id] then
      out[#out + 1] = note
    end
  end
  return out
end

local function filter_notes(notes, mode, opts)
  opts = opts or {}
  local include_inactive = opts.include_inactive
  if include_inactive == nil then
    include_inactive = (config.get().search or {}).include_inactive == true
  end

  if include_inactive ~= true then
    notes = vim.tbl_filter(function(note)
      return not is_inactive_note(note)
    end, notes)
  end

  if mode == "todo" then
    return vim.tbl_filter(function(note)
      return has_tag(note, "todo") or checklist_status(note) == "todo"
    end, notes)
  elseif mode == "done" then
    return vim.tbl_filter(function(note)
      return has_tag(note, "done") or checklist_status(note) == "done"
    end, notes)
  elseif mode == "orphans" then
    return orphan_notes(notes)
  end
  return notes
end

local function load_snacks_picker()
  if _G.Snacks and _G.Snacks.picker then
    return _G.Snacks.picker
  end
  local ok, snacks = pcall(require, "snacks")
  if ok and snacks.picker then
    return snacks.picker
  end
  return nil
end

local function item_for(note, mode)
  local metadata = note.metadata or {}
  local labels = {}
  for _, tag in ipairs(note.tags or {}) do
    labels[#labels + 1] = "#" .. tag
  end
  local relation = metadata.relation
  if relation and relation ~= "active" then
    labels[#labels + 1] = relation
  end
  return {
    text = note_text(note, mode),
    file = note.path,
    pos = { note.title_line or 1, 0 },
    note = note,
    labels = labels,
  }
end

local function mode_label(mode)
  return (MODE_BY_NAME[mode] and MODE_BY_NAME[mode].label) or mode or "Title"
end

local function picker_title(state)
  local scope = state.include_inactive and "all notes" or "active"
  return ("ZK Notes: %s / %s  Ctrl-f/f filters"):format(mode_label(state.mode), scope)
end

local function filter_prompt_items(state)
  local items = {}
  for _, mode in ipairs(SEARCH_MODES) do
    items[#items + 1] = {
      text = mode.label .. " " .. mode.mode .. " " .. mode.desc,
      kind = "mode",
      mode = mode.mode,
      label = mode.label,
      desc = mode.desc,
      active = state.mode == mode.mode,
    }
  end
  items[#items + 1] = {
    text = "Archived legacy inactive",
    kind = "inactive",
    label = "Archived / legacy",
    desc = state.include_inactive and "shown in results" or "hidden by default",
    active = state.include_inactive,
  }
  items[#items + 1] = {
    text = "Reset title active",
    kind = "reset",
    label = "Reset",
    desc = "title search, active notes only",
    active = false,
  }
  return items
end

local function format_filter_item(item)
  local active = item.active == true
  return {
    { active and "* " or "  ", active and "SnacksPickerSpecial" or "SnacksPickerDimmed" },
    { item.label, active and "SnacksPickerFile" or "SnacksPickerDimmed" },
    { "  " .. item.desc, "SnacksPickerDimmed" },
  }
end

local function apply_filter_choice(state, item)
  if not item then
    return
  end
  if item.kind == "mode" then
    state.mode = item.mode
  elseif item.kind == "inactive" then
    state.include_inactive = not state.include_inactive
  elseif item.kind == "reset" then
    state.mode = config.get().search.default_mode or "title"
    state.include_inactive = (config.get().search or {}).include_inactive == true
  end
end

local function format_item(item)
  local note = item.note
  local ret = {
    { "󰈙 ", "SnacksPickerIcon" },
    { note.title or "Untitled", "SnacksPickerFile" },
    { " @" .. tostring(note.id or ""), "SnacksPickerDimmed" },
  }
  for _, label in ipairs(item.labels or {}) do
    ret[#ret + 1] = { " " .. label, "SnacksPickerSpecial" }
  end
  local abstract = get_path(note.metadata or {}, "abstract")
  if type(abstract) == "string" and abstract ~= "" then
    ret[#ret + 1] = { "  " .. abstract:sub(1, 100), "SnacksPickerComment" }
  end
  return ret
end

local function open_item(item)
  if not item or not item.file then
    return
  end
  local root = config.get().wiki_root
  vim.cmd("cd " .. vim.fn.fnameescape(root))
  vim.cmd("edit " .. vim.fn.fnameescape(item.file))
  if item.pos and item.pos[1] then
    vim.api.nvim_win_set_cursor(0, { item.pos[1], item.pos[2] or 0 })
  end
end

function M.collect(mode, opts)
  mode = mode or config.get().search.default_mode or "title"
  local fields, schema_err = schema.fields()
  if not fields then
    util.notify(schema_err, vim.log.levels.WARN)
  end
  local notes, notes_err = cli.list_notes()
  if not notes then
    util.notify(notes_err, vim.log.levels.ERROR)
    return {}
  end
  notes = enrich_notes(notes)
  notes = filter_notes(notes, mode, opts)
  return vim.tbl_map(function(note)
    return item_for(note, mode)
  end, notes)
end

function M.search(mode)
  mode = mode or config.get().search.default_mode or "title"
  if config.get().search.enabled == false then
    util.notify("Search is disabled", vim.log.levels.WARN)
    return
  end

  local picker = load_snacks_picker()
  if not picker then
    util.notify("Snacks picker is not available. Install folke/snacks.nvim or disable search.", vim.log.levels.ERROR)
    return
  end

  local state = {
    mode = mode,
    include_inactive = (config.get().search or {}).include_inactive == true,
    query = "",
  }

  local open_picker
  local open_filter_prompt

  local function capture_query(p)
    if p and p.input then
      state.query = p.input:get()
    end
  end

  local function reopen()
    vim.schedule(function()
      open_picker()
    end)
  end

  local function close_then_filter(p)
    capture_query(p)
    p:close()
    vim.schedule(function()
      open_filter_prompt()
    end)
  end

  open_filter_prompt = function()
    local confirmed = false
    picker.pick({
      title = "ZK Search Filters",
      layout = "select",
      items = filter_prompt_items(state),
      format = format_filter_item,
      confirm = function(p, item)
        confirmed = true
        apply_filter_choice(state, item)
        p:close()
        reopen()
      end,
      on_close = function()
        if not confirmed then
          reopen()
        end
      end,
    })
  end

  open_picker = function()
    local items = M.collect(state.mode, { include_inactive = state.include_inactive })
    if #items == 0 then
      util.notify("No notes found for search mode: " .. state.mode, vim.log.levels.INFO)
      return
    end

    picker.pick({
      title = picker_title(state),
      pattern = state.query,
      items = items,
      format = format_item,
      confirm = function(p, item)
        p:close()
        open_item(item)
      end,
      win = {
        input = {
          keys = {
            ["<C-f>"] = { "zk_filter_prompt", mode = { "i", "n" }, desc = "choose ZK search filter" },
            ["f"] = { "zk_filter_prompt", mode = "n", desc = "choose ZK search filter" },
          },
        },
        list = {
          keys = {
            ["f"] = { "zk_filter_prompt", desc = "choose ZK search filter" },
          },
        },
      },
      actions = {
        zk_filter_prompt = {
          desc = "choose ZK search filter",
          action = close_then_filter,
        },
      },
    })
  end

  open_picker()
end

function M.dispatch(args)
  local mode = args and args[1] or nil
  M.search(mode)
end

return M
