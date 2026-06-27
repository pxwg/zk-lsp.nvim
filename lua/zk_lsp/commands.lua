local config = require("zk_lsp.config")
local util = require("zk_lsp.util")

local M = {}

local root_commands = {
  "new",
  "remove",
  "export",
  "generate",
  "reconcile",
  "check",
  "search",
  "capture",
}

local search_commands = {
  "alias",
  "keyword",
  "abstract",
  "tag",
  "todo",
  "done",
  "orphans",
}

local capture_commands = {
  "web",
  "paper",
  "paper-note",
  "extension-path",
  "install-native-host",
}

local reconcile_flags = { "--dry-run" }
local check_flags = { "--no-orphans", "--no-dead-links" }
local export_flags = { "--depth", "--inverse", "--simple" }

local function complete_from(values, arg_lead)
  return vim.tbl_filter(function(value)
    return vim.startswith(value, arg_lead)
  end, values)
end

local function call_cli(command, args)
  local ok, cli = pcall(require, "zk_lsp.cli")
  if not ok then
    util.notify("CLI module is not available yet: " .. cli, vim.log.levels.ERROR)
    return
  end
  cli.dispatch(command, args)
end

local function call_search(args)
  local ok, search = pcall(require, "zk_lsp.search")
  if not ok then
    util.notify("Search module is not available yet: " .. search, vim.log.levels.ERROR)
    return
  end
  search.dispatch(args)
end

local function call_capture(args)
  local ok, capture = pcall(require, "zk_lsp.capture")
  if not ok then
    util.notify("Capture module is not available yet: " .. capture, vim.log.levels.ERROR)
    return
  end
  capture.dispatch(args)
end

function M.dispatch(opts)
  local args = util.split_args(opts.args)
  local command = table.remove(args, 1)
  if not command or command == "" then
    util.notify("Usage: :Zk <command>", vim.log.levels.WARN)
    return
  end

  if command == "search" then
    call_search(args)
  elseif command == "capture" then
    call_capture(args)
  elseif command == "new"
    or command == "remove"
    or command == "export"
    or command == "generate"
    or command == "reconcile"
    or command == "check"
  then
    call_cli(command, args)
  else
    util.notify("Unknown Zk command: " .. command, vim.log.levels.ERROR)
  end
end

function M.complete(arg_lead, cmdline)
  local args = util.split_args(cmdline)
  local zk_index = 1
  for index, value in ipairs(args) do
    if value == config.get().command.name then
      zk_index = index
      break
    end
  end

  local subargs = {}
  for index = zk_index + 1, #args do
    subargs[#subargs + 1] = args[index]
  end

  if #subargs == 0 or (#subargs == 1 and vim.endswith(cmdline, " ")) then
    return complete_from(root_commands, arg_lead)
  end

  local root = subargs[1]
  if root == "search" then
    return complete_from(search_commands, arg_lead)
  elseif root == "capture" then
    return complete_from(capture_commands, arg_lead)
  elseif root == "reconcile" then
    return complete_from(reconcile_flags, arg_lead)
  elseif root == "check" then
    return complete_from(check_flags, arg_lead)
  elseif root == "export" then
    return complete_from(export_flags, arg_lead)
  end

  return complete_from(root_commands, arg_lead)
end

function M.setup()
  local name = config.get().command.name
  vim.api.nvim_create_user_command(name, M.dispatch, {
    nargs = "*",
    complete = M.complete,
    desc = "ZK note workflow commands",
  })
end

return M
