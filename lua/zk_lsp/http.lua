local M = {}

local function curl_base(opts)
  opts = opts or {}
  local args = {
    "curl",
    "--silent",
    "--show-error",
    "--fail",
    "--location",
    "--max-time",
    tostring(opts.timeout or 20),
    "--user-agent",
    opts.user_agent or "zk-lsp.nvim/0.1",
  }
  for _, header in ipairs(opts.headers or {}) do
    args[#args + 1] = "--header"
    args[#args + 1] = header
  end
  return args
end

function M.text(url, opts)
  local args = curl_base(opts)
  args[#args + 1] = url
  local result = vim.system(args, { text = true }):wait()
  if result.code ~= 0 then
    return nil, vim.trim((result.stderr or "") .. "\n" .. (result.stdout or ""))
  end
  return result.stdout or ""
end

function M.download(url, outpath, opts)
  local args = curl_base(opts)
  args[#args + 1] = "--output"
  args[#args + 1] = outpath
  args[#args + 1] = url
  local result = vim.system(args, { text = true }):wait()
  if result.code ~= 0 then
    return nil, vim.trim((result.stderr or "") .. "\n" .. (result.stdout or ""))
  end
  return outpath
end

return M
