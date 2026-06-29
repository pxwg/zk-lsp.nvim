local M = {}

local defaults = {
  executable = "zk-lsp",
  wiki_root = nil,
  command = {
    name = "Zk",
  },
  search = {
    enabled = true,
    picker = "snacks",
    default_mode = "title",
    include_inactive = false,
    providers = {
      local_note = true,
    },
  },
  capture = {
    enabled = true,
    fetch = {
      manual = true,
      browser = false,
      paper = true,
    },
    bibliography = {
      path = "ref.bib",
      declare = {
        enabled = true,
        file = "index.typ",
      },
      translators = {
        enabled = true,
        timeout = 12,
        arxiv = true,
        crossref = true,
        generic_html = true,
        pdf_text = true,
        pdf_text_pages = 3,
      },
    },
    browser = {
      enabled = true,
      host_name = "top.homeward_sky.zk_capture",
    },
    templates = {},
  },
  extmark = {
    enabled = true,
    conceal = true,
    hl_group = "Identifier",
  },
}

local state = nil

local function home_dir()
  return vim.uv.os_homedir() or vim.env.HOME or "~"
end

local function expand_path(path)
  if type(path) ~= "string" or path == "" then
    return path
  end
  return vim.fs.normalize(vim.fn.expand(path))
end

local function resolve_wiki_root(opts)
  local root = opts.wiki_root
  if type(root) ~= "string" or root == "" then
    root = vim.env.WIKI_ROOT
  end
  if type(root) ~= "string" or root == "" then
    root = home_dir() .. "/wiki"
  end
  return expand_path(root)
end

local function resolve_executable(opts)
  local executable = opts.executable or "zk-lsp"
  if type(executable) == "string" and executable:match("[/\\]") then
    return expand_path(executable)
  end
  return executable
end

function M.setup(opts)
  opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  opts.wiki_root = resolve_wiki_root(opts)
  opts.executable = resolve_executable(opts)
  state = opts
  return state
end

function M.get()
  if not state then
    return M.setup({})
  end
  return state
end

function M.defaults()
  return vim.deepcopy(defaults)
end

return M
