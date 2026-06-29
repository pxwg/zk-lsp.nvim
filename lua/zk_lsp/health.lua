local config = require("zk_lsp.config")

local M = {}

local function health()
  return vim.health
end

local function ok(message)
  health().ok(message)
end

local function warn(message)
  health().warn(message)
end

local function error(message)
  health().error(message)
end

local function info(message)
  health().info(message)
end

local function executable_ok(executable)
  if vim.fn.executable(executable) == 1 then
    ok("Found executable: " .. executable)
    return true
  end
  error("Executable not found: " .. executable)
  return false
end

local function snacks_available()
  if _G.Snacks and _G.Snacks.picker then
    return true
  end
  local ok_require, snacks = pcall(require, "snacks")
  return ok_require and snacks and snacks.picker ~= nil
end

local function check_schema()
  local ok_call, fields_or_err, err = pcall(function()
    return require("zk_lsp.cli").metadata_fields()
  end)
  if not ok_call then
    error("Failed to inspect metadata schema: " .. tostring(fields_or_err))
    return
  end
  if not fields_or_err then
    error("Failed to inspect metadata schema: " .. tostring(err))
    return
  end
  local count = #(fields_or_err.fields or {})
  ok("Metadata schema available (" .. count .. " fields)")
  for _, source in ipairs(fields_or_err.sources or {}) do
    local status = source.loaded and "loaded" or "not loaded"
    info(string.format("%s config %s: %s", source.scope or "unknown", status, source.path or ""))
  end
end

local function check_notes_command()
  local search = config.get().search or {}
  if search.enabled == false then
    return
  end

  local ok_call, notes_or_err, err = pcall(function()
    return require("zk_lsp.cli").notes()
  end)
  if not ok_call then
    error("Failed to inspect notes: " .. tostring(notes_or_err))
    return
  end
  if not notes_or_err then
    error("Failed to inspect notes: " .. tostring(err))
    return
  end
  ok("Bulk notes command available (" .. #notes_or_err .. " records)")
end

local function check_wiki(root)
  if vim.fn.isdirectory(root) == 1 then
    ok("Wiki root exists: " .. root)
  else
    warn("Wiki root does not exist: " .. root)
    return
  end

  local note_dir = vim.fs.joinpath(root, "note")
  if vim.fn.isdirectory(note_dir) == 1 then
    ok("Note directory exists: " .. note_dir)
  else
    warn("Note directory does not exist: " .. note_dir)
  end
end

local function check_search()
  local search = config.get().search or {}
  if search.enabled == false then
    info("Search is disabled")
    return
  end
  if search.picker == "snacks" and snacks_available() then
    ok("Snacks picker is available")
  elseif search.picker == "snacks" then
    warn("Snacks picker is not available; :Zk search requires folke/snacks.nvim")
  else
    warn("Unsupported picker configured: " .. tostring(search.picker))
  end
end

local function check_capture()
  local capture = config.get().capture or {}
  if capture.enabled == false then
    info("Capture is disabled")
    return
  end

  local fetch = capture.fetch or {}
  if (fetch.manual ~= false or fetch.paper ~= false) and vim.fn.executable("curl") ~= 1 then
    warn("curl is not available; manual web/paper URL capture will not fetch URLs")
  elseif fetch.manual ~= false or fetch.paper ~= false then
    ok("curl is available for manual web/paper URL capture")
  end

  local translators = (capture.bibliography or {}).translators or {}
  if translators.enabled ~= false then
    if vim.fn.executable("curl") == 1 then
      ok("curl is available for bibliography metadata translators")
    else
      warn("curl is not available; arXiv/Crossref bibliography translators will be skipped")
    end
    if translators.pdf_text ~= false then
      if vim.fn.executable("pdftotext") == 1 then
        ok("pdftotext is available for PDF identifier extraction")
      else
        info("pdftotext is not available; PDF identifier extraction will use URL/title metadata only")
      end
    end
  end

  if capture.browser and capture.browser.enabled ~= false then
    local install = require("zk_lsp.install")
    local ext = install.extension_path()
    if
      vim.fn.filereadable(vim.fs.joinpath(ext, "manifest.json")) == 1
      and vim.fn.filereadable(vim.fs.joinpath(ext, "background.js")) == 1
    then
      ok("Chrome extension assets found: " .. ext)
    else
      error("Chrome extension assets are missing: " .. ext)
    end
    info("Native host name: " .. tostring(capture.browser.host_name))
  end
end

function M.check()
  health().start("zk-lsp.nvim")

  if vim.fn.has("nvim-0.12") == 1 then
    ok("Neovim >= 0.12")
  else
    error("Neovim >= 0.12 is required")
  end

  local cfg = config.get()
  local has_executable = executable_ok(cfg.executable)
  check_wiki(cfg.wiki_root)
  if has_executable then
    check_schema()
    check_notes_command()
  end
  check_search()
  check_capture()
end

return M
