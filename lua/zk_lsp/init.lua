local M = {}

function M.setup(opts)
  local config = require("zk_lsp.config").setup(opts)
  require("zk_lsp.commands").setup()

  if config.extmark and config.extmark.enabled then
    local ok, extmark = pcall(require, "zk_lsp.extmark")
    if ok and extmark.setup then
      extmark.setup()
    end
  end

  return config
end

function M.config()
  return require("zk_lsp.config").get()
end

function M.build(opts)
  if opts then
    require("zk_lsp.config").setup(opts)
  end
  return require("zk_lsp.install").build()
end

return M
