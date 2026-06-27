local config = require("zk_lsp.config")
local util = require("zk_lsp.util")

local M = {}

local DEFAULT_TIMEOUT_MS = 120000

local function command(args)
  local cfg = config.get()
  local cmd = { cfg.executable, "--wiki-root", cfg.wiki_root }
  vim.list_extend(cmd, args)
  return cmd
end

local function run(args, opts)
  opts = opts or {}
  local system_opts = {
    text = opts.text ~= false,
    stdin = opts.stdin,
    timeout = opts.timeout or DEFAULT_TIMEOUT_MS,
  }
  local result = vim.system(command(args), system_opts):wait()
  return result
end

local function run_ok(args, opts)
  local result = run(args, opts)
  if result.code ~= 0 then
    return nil, util.shell_error(table.concat(args, " "), result), result
  end
  return result.stdout or "", nil, result
end

local function decode_json(raw, context)
  local ok, decoded = pcall(vim.json.decode, raw or "")
  if ok then
    return decoded
  end
  return nil, "failed to decode JSON from " .. context
end

local function trim_stdout(stdout)
  return vim.trim(stdout or "")
end

local function note_id_from_path(path)
  return type(path) == "string" and path:match("(%d%d%d%d%d%d%d%d%d%d)%.typ$") or nil
end

local function normalize_path(path)
  if type(path) ~= "string" or path == "" then
    return ""
  end
  return vim.fs.normalize(path)
end

local function note_path(id)
  return normalize_path(vim.fs.joinpath(config.get().wiki_root, "note", id .. ".typ"))
end

local function index_path()
  return normalize_path(vim.fs.joinpath(config.get().wiki_root, "index.typ"))
end

local function note_id_from_buffer(bufnr)
  return note_id_from_path(vim.api.nvim_buf_get_name(bufnr))
end

local function open_path(path)
  if path and path ~= "" then
    vim.cmd.edit(vim.fn.fnameescape(path))
  end
end

local function resolve_note_id(id, command_name)
  if not id or id == "" then
    id = vim.fn.expand("<cword>")
  end
  if not id:match("^%d%d%d%d%d%d%d%d%d%d$") then
    return nil, command_name .. " requires a 10-digit note id"
  end
  return id
end

local function buffers_for_note(id)
  local path = note_path(id)
  local buffers = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and normalize_path(vim.api.nvim_buf_get_name(bufnr)) == path then
      buffers[#buffers + 1] = bufnr
    end
  end
  return buffers
end

local function confirm_modified_note_buffers(id)
  for _, bufnr in ipairs(buffers_for_note(id)) do
    if vim.bo[bufnr].modified then
      local is_current = bufnr == vim.api.nvim_get_current_buf()
      local message = is_current and "Current note buffer has unsaved changes. Remove note and wipe buffer?"
        or ("Loaded buffer for note " .. id .. " has unsaved changes. Remove note and wipe buffer?")
      if vim.fn.confirm(message, "&Remove\n&Cancel", 2) ~= 1 then
        return false
      end
    end
  end
  return true
end

local function fallback_buffer(exclude_bufnr, removed_path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = normalize_path(vim.api.nvim_buf_get_name(bufnr))
    if
      vim.api.nvim_buf_is_loaded(bufnr)
      and vim.bo[bufnr].buflisted
      and bufnr ~= exclude_bufnr
      and name ~= removed_path
      and note_id_from_buffer(bufnr)
      and vim.fn.filereadable(name) == 1
    then
      return bufnr
    end
  end

  local index = index_path()
  if vim.fn.filereadable(index) == 1 then
    local bufnr = vim.fn.bufadd(index)
    vim.fn.bufload(bufnr)
    return bufnr
  end

  return vim.api.nvim_create_buf(true, false)
end

local function wipe_removed_note_buffers(id)
  local removed_path = note_path(id)
  for _, bufnr in ipairs(buffers_for_note(id)) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local replacement = fallback_buffer(bufnr, removed_path)
      for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
        if vim.api.nvim_win_is_valid(winid) then
          vim.api.nvim_win_set_buf(winid, replacement)
        end
      end
      pcall(vim.api.nvim_buf_delete, bufnr, { force = vim.bo[bufnr].modified })
    end
  end
end

function M.run(args, opts)
  return run(args, opts)
end

function M.run_ok(args, opts)
  return run_ok(args, opts)
end

function M.new(opts)
  opts = opts or {}
  local args = { "new" }
  if opts.json then
    args[#args + 1] = "--json"
  end
  if opts.id then
    args[#args + 1] = "--id"
    args[#args + 1] = opts.id
  end

  local stdin
  if opts.json then
    stdin = vim.json.encode({
      title = opts.title or "",
      content = opts.content or "",
      metadata = opts.metadata or {},
    })
  end

  local stdout, err = run_ok(args, { stdin = stdin })
  if not stdout then
    return nil, err
  end

  local path = trim_stdout(stdout)
  return {
    path = path,
    id = note_id_from_path(path),
  }
end

function M.remove(id)
  local resolved, parse_err = resolve_note_id(id, "remove")
  if not resolved then
    return nil, parse_err
  end
  local stdout, err = run_ok({ "remove", resolved })
  if not stdout then
    return nil, err
  end
  return stdout
end

function M.generate()
  return run_ok({ "generate" })
end

function M.reconcile(opts)
  local args = { "reconcile" }
  if opts and opts.dry_run then
    args[#args + 1] = "--dry-run"
  end
  return run_ok(args)
end

function M.check(opts)
  local args = { "check" }
  if opts and opts.no_orphans then
    args[#args + 1] = "--no-orphans"
  end
  if opts and opts.no_dead_links then
    args[#args + 1] = "--no-dead-links"
  end
  local result = run(args)
  local output = (result.stdout or "") .. (result.stderr or "")
  return output, result.code == 0 and nil or "zk-lsp check reported issues", result
end

function M.export(id, opts)
  opts = opts or {}
  local args = { "export", id }
  if opts.depth then
    args[#args + 1] = "--depth"
    args[#args + 1] = tostring(opts.depth)
  end
  if opts.inverse then
    args[#args + 1] = "--inverse"
  end
  if opts.simple then
    args[#args + 1] = "--simple"
  end
  return run_ok(args)
end

function M.note_info(id)
  local stdout, err = run_ok({ "note-info", id })
  if not stdout then
    return nil, err
  end
  return decode_json(stdout, "zk-lsp note-info " .. id)
end

function M.note_info_by_file(path)
  local id = note_id_from_path(path)
  if not id then
    return nil, "not a note file: " .. tostring(path)
  end
  return M.note_info(id)
end

local function normalize_note_record(note)
  if type(note) ~= "table" then
    return nil
  end
  if type(note.path) == "string" and note.path ~= "" then
    note.path = normalize_path(note.path)
  end
  if type(note.id) ~= "string" or note.id == "" then
    note.id = note_id_from_path(note.path)
  end
  note.metadata = type(note.metadata) == "table" and note.metadata or {}
  if not note.id or note.id == "" or not note.path or note.path == "" then
    return nil
  end
  return note
end

function M.notes()
  local stdout, err = run_ok({ "notes", "--json" })
  if not stdout then
    return nil, err
  end
  local decoded, decode_err = decode_json(stdout, "zk-lsp notes")
  if not decoded then
    return nil, decode_err
  end
  if type(decoded) ~= "table" then
    return nil, "zk-lsp notes returned non-array JSON"
  end

  local notes = {}
  for _, note in ipairs(decoded) do
    local normalized = normalize_note_record(note)
    if normalized then
      notes[#notes + 1] = normalized
    end
  end
  table.sort(notes, function(a, b)
    return tostring(a.id) > tostring(b.id)
  end)
  return notes
end

function M.note_paths()
  local root = config.get().wiki_root
  return vim.fn.globpath(vim.fs.joinpath(root, "note"), "*.typ", false, true)
end

function M.list_notes()
  return M.notes()
end

function M.metadata_fields()
  local stdout, err = run_ok({ "config", "metadata", "fields", "--json", "--sources" })
  if not stdout then
    return nil, err
  end
  return decode_json(stdout, "zk-lsp config metadata fields")
end

function M.metadata_defaults()
  local stdout, err = run_ok({ "config", "metadata", "defaults", "--json" })
  if not stdout then
    return nil, err
  end
  return decode_json(stdout, "zk-lsp config metadata defaults")
end

function M.metadata_json_schema()
  local stdout, err = run_ok({ "config", "metadata", "json-schema", "--json", "--sources" })
  if not stdout then
    return nil, err
  end
  return decode_json(stdout, "zk-lsp config metadata json-schema")
end

local function show_output(name, stdout, filetype)
  local lines = vim.split(stdout or "", "\n", { plain = true })
  util.open_scratch(name, lines, { filetype = filetype or "" })
end

local function parse_export_args(args)
  local id = args[1]
  if not id or id == "" then
    return nil, "export requires a note id"
  end
  local depth = util.parse_flag_value(args, "--depth")
  return {
    id = id,
    depth = depth and tonumber(depth) or nil,
    inverse = util.has_flag(args, "--inverse"),
    simple = util.has_flag(args, "--simple"),
  }
end

function M.dispatch(command_name, args)
  args = args or {}

  if command_name == "new" then
    local note, err = M.new({})
    if not note then
      util.notify(err, vim.log.levels.ERROR)
      return
    end
    open_path(note.path)
  elseif command_name == "remove" then
    local id, parse_err = resolve_note_id(args[1], "remove")
    if not id then
      util.notify(parse_err, vim.log.levels.ERROR)
      return
    end
    if not confirm_modified_note_buffers(id) then
      util.notify("Remove cancelled")
      return
    end
    local ok, err = M.remove(id)
    if not ok then
      util.notify(err, vim.log.levels.ERROR)
      return
    end
    wipe_removed_note_buffers(id)
    util.notify("Removed note " .. id)
  elseif command_name == "generate" then
    local stdout, err = M.generate()
    if not stdout then
      util.notify(err, vim.log.levels.ERROR)
      return
    end
    util.notify("Regenerated link.typ")
  elseif command_name == "reconcile" then
    local stdout, err = M.reconcile({ dry_run = util.has_flag(args, "--dry-run") })
    if not stdout then
      util.notify(err, vim.log.levels.ERROR)
      return
    end
    show_output("zk-lsp://reconcile", stdout, "text")
  elseif command_name == "check" then
    local stdout, err = M.check({
      no_orphans = util.has_flag(args, "--no-orphans"),
      no_dead_links = util.has_flag(args, "--no-dead-links"),
    })
    show_output("zk-lsp://check", stdout, "text")
    if err then
      util.notify(err, vim.log.levels.WARN)
    end
  elseif command_name == "export" then
    local parsed, parse_err = parse_export_args(args)
    if not parsed then
      util.notify(parse_err, vim.log.levels.ERROR)
      return
    end
    local stdout, err = M.export(parsed.id, parsed)
    if not stdout then
      util.notify(err, vim.log.levels.ERROR)
      return
    end
    show_output("zk-lsp://export/" .. parsed.id, stdout, parsed.simple and "json" or "typst")
  else
    util.notify("Unknown executable command: " .. tostring(command_name), vim.log.levels.ERROR)
  end
end

return M
