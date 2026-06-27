local config = require("zk_lsp.config")

local M = {}

local ns_id = vim.api.nvim_create_namespace("zk_lsp_note_titles")
local note_link_pattern = "@(%d%d%d%d%d%d%d%d%d%d)"

local state = {
  cache = {},
  active_link_by_buf = {},
  group = nil,
}

local function note_root()
  return vim.fs.joinpath(config.get().wiki_root, "note")
end

local function note_path(id)
  return vim.fs.joinpath(note_root(), id .. ".typ")
end

local function is_note_buffer(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name:match("/note/%d%d%d%d%d%d%d%d%d%d%.typ$") ~= nil
end

local function get_cursor_link(bufnr)
  if vim.api.nvim_get_current_buf() ~= bufnr then
    return nil
  end

  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, 0)
  if not ok then
    return nil
  end

  local line_idx = cursor[1] - 1
  local cursor_col = cursor[2]
  local line = vim.api.nvim_buf_get_lines(bufnr, line_idx, line_idx + 1, false)[1]
  if not line then
    return nil
  end

  local current_pos = 1
  while true do
    local start_col, end_col, id = line:find(note_link_pattern, current_pos)
    if not start_col then
      return nil
    end

    if cursor_col >= start_col - 1 and cursor_col < end_col then
      return {
        line = line_idx,
        start_col = start_col - 1,
        end_col = end_col,
        id = id,
      }
    end

    current_pos = end_col + 1
  end
end

local function link_key(link)
  if not link then
    return ""
  end
  return table.concat({ link.line, link.start_col, link.end_col, link.id }, ":")
end

local function title_from_file(id)
  if state.cache[id] then
    return state.cache[id]
  end

  local path = note_path(id)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end

  for _, line in ipairs(vim.fn.readfile(path, "", 120)) do
    local title, heading_id = line:match("^=%s*(.-)%s*<(%d%d%d%d%d%d%d%d%d%d)>%s*$")
    if heading_id == id then
      state.cache[id] = title
      return title
    end
  end
  return nil
end

function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].filetype ~= "typst" and not is_note_buffer(bufnr) then
    return
  end

  local cfg = config.get().extmark or {}
  if cfg.conceal ~= false then
    for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
      vim.wo[winid].conceallevel = math.max(vim.wo[winid].conceallevel, 2)
    end
  end

  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local active_link = get_cursor_link(bufnr)
  state.active_link_by_buf[bufnr] = link_key(active_link)

  for line_idx, line in ipairs(lines) do
    local current_pos = 1
    while true do
      local start_col, end_col, id = line:find(note_link_pattern, current_pos)
      if not start_col then
        break
      end

      local is_active_link = active_link
        and active_link.line == line_idx - 1
        and active_link.start_col == start_col - 1
        and active_link.end_col == end_col

      if not is_active_link then
        local title = title_from_file(id)
        if title then
          local hl_group = cfg.hl_group or "Identifier"
          if cfg.conceal ~= false then
            vim.api.nvim_buf_set_extmark(bufnr, ns_id, line_idx - 1, start_col - 1, {
              end_col = end_col,
              conceal = "@",
              hl_group = hl_group,
            })
          end

          vim.api.nvim_buf_set_extmark(bufnr, ns_id, line_idx - 1, end_col, {
            virt_text = { { title, hl_group } },
            virt_text_pos = "inline",
            hl_mode = "combine",
          })
        end
      end

      current_pos = end_col + 1
    end
  end
end

function M.clear_cache()
  state.cache = {}
end

function M.setup()
  state.group = vim.api.nvim_create_augroup("ZkLspExtmarkRefresh", { clear = true })

  vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "InsertLeave", "TextChanged" }, {
    group = state.group,
    pattern = "*.typ",
    callback = function(ev)
      if ev.event == "BufEnter" or ev.event == "BufWritePost" then
        M.clear_cache()
      end
      M.refresh(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = state.group,
    pattern = "*.typ",
    callback = function(ev)
      local active_key = link_key(get_cursor_link(ev.buf))
      if state.active_link_by_buf[ev.buf] ~= active_key then
        M.refresh(ev.buf)
      end
    end,
  })

  vim.schedule(function()
    M.refresh()
  end)
end

return M
