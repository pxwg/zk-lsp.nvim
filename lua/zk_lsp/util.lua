local M = {}

function M.notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "zk-lsp.nvim" })
end

function M.split_args(args)
  if type(args) ~= "string" or args == "" then
    return {}
  end
  return vim.split(args, "%s+", { trimempty = true })
end

function M.shell_error(prefix, result)
  local parts = {}
  if prefix and prefix ~= "" then
    parts[#parts + 1] = prefix
  end
  if result and result.stderr and result.stderr ~= "" then
    parts[#parts + 1] = vim.trim(result.stderr)
  end
  if result and result.stdout and result.stdout ~= "" then
    parts[#parts + 1] = vim.trim(result.stdout)
  end
  if #parts == 0 then
    return "command failed"
  end
  return table.concat(parts, ": ")
end

function M.open_scratch(name, lines, opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = opts.filetype or ""
  vim.api.nvim_buf_set_name(bufnr, name)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or {})
  vim.cmd(opts.command or "botright split")
  vim.api.nvim_win_set_buf(0, bufnr)
  return bufnr
end

function M.parse_flag_value(args, flag)
  for index, value in ipairs(args) do
    if value == flag then
      return args[index + 1], index
    end
    local prefix = flag .. "="
    if vim.startswith(value, prefix) then
      return value:sub(#prefix + 1), index
    end
  end
  return nil, nil
end

function M.has_flag(args, flag)
  for _, value in ipairs(args) do
    if value == flag then
      return true
    end
  end
  return false
end

return M
