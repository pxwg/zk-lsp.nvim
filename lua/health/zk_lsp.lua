local M = {}

function M.check()
  require("zk_lsp.health").check()
end

return M
