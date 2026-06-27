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

local function open_path(path)
  if path and path ~= "" then
    vim.cmd.edit(vim.fn.fnameescape(path))
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
  if not id or id == "" then
    id = vim.fn.expand("<cword>")
  end
  if not id:match("^%d%d%d%d%d%d%d%d%d%d$") then
    return nil, "remove requires a 10-digit note id"
  end
  local stdout, err = run_ok({ "remove", id })
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

function M.note_paths()
  local root = config.get().wiki_root
  return vim.fn.globpath(vim.fs.joinpath(root, "note"), "*.typ", false, true)
end

function M.list_notes()
  local notes = {}
  for _, path in ipairs(M.note_paths()) do
    local id = note_id_from_path(path)
    if id then
      local note = M.note_info(id)
      if note then
        notes[#notes + 1] = note
      end
    end
  end
  table.sort(notes, function(a, b)
    return tostring(a.id) > tostring(b.id)
  end)
  return notes
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
    local ok, err = M.remove(args[1])
    if not ok then
      util.notify(err, vim.log.levels.ERROR)
      return
    end
    util.notify("Removed note " .. (args[1] or vim.fn.expand("<cword>")))
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
