local config = require("zk_lsp.config")

local M = {}

local function trim(value)
  if type(value) ~= "string" then
    return ""
  end
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function join_paths(...)
  local path = table.concat({ ... }, "/"):gsub("//+", "/")
  return vim.fs.normalize(path)
end

local function write_text(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local ok, err = pcall(vim.fn.writefile, vim.split(text, "\n", { plain = true }), path)
  if not ok then
    return nil, tostring(err)
  end
  return true
end

local function sh_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function M.plugin_root()
  local source = debug.getinfo(1, "S").source:gsub("^@", "")
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

function M.extension_path()
  return join_paths(M.plugin_root(), "chrome", "zk-capture")
end

local function native_dir()
  return join_paths(vim.fn.stdpath("data"), "zk-lsp.nvim", "native-host")
end

local function native_config_path()
  return join_paths(native_dir(), "config.json")
end

local function launcher_path()
  return join_paths(native_dir(), "zk-capture-native-host")
end

local function chrome_manifest_dir()
  local home = vim.uv.os_homedir() or vim.env.HOME
  if vim.fn.has("mac") == 1 then
    return join_paths(home, "Library", "Application Support", "Google", "Chrome", "NativeMessagingHosts")
  end
  if vim.fn.has("unix") == 1 then
    return join_paths(home, ".config", "google-chrome", "NativeMessagingHosts")
  end
  return nil
end

local function manifest_path(host_name)
  local dir = chrome_manifest_dir()
  if not dir then
    return nil
  end
  return join_paths(dir, host_name .. ".json")
end

local function serializable_capture_config()
  local capture = config.get().capture or {}
  return {
    fetch = capture.fetch,
    bibliography = capture.bibliography,
    browser = capture.browser,
  }
end

function M.build()
  local root = M.plugin_root()
  local ext = M.extension_path()
  if vim.fn.filereadable(join_paths(ext, "manifest.json")) == 0 then
    return nil, "Chrome extension assets are missing: " .. ext
  end

  local cfg = config.get()
  local native_config = {
    executable = cfg.executable,
    wiki_root = cfg.wiki_root,
    plugin_root = root,
    capture = serializable_capture_config(),
  }
  local encoded = vim.json.encode(native_config)
  local ok, err = write_text(native_config_path(), encoded)
  if not ok then
    return nil, err
  end

  local nvim = vim.fn.exepath(vim.v.progpath)
  if nvim == "" then
    nvim = vim.v.progpath
  end
  local native_host = join_paths(root, "lua", "zk_lsp", "capture", "native_host.lua")
  local launcher = table.concat({
    "#!/bin/sh",
    "exec "
      .. sh_quote(nvim)
      .. " --headless --clean -n --cmd "
      .. sh_quote("set rtp^=" .. root)
      .. " -l "
      .. sh_quote(native_host)
      .. " "
      .. sh_quote(native_config_path()),
  }, "\n")
  ok, err = write_text(launcher_path(), launcher)
  if not ok then
    return nil, err
  end
  vim.uv.fs_chmod(launcher_path(), 493)
  return {
    config_path = native_config_path(),
    launcher_path = launcher_path(),
    extension_path = ext,
  }
end

function M.install_native_host(extension_id)
  extension_id = trim(extension_id)
  if extension_id == "" then
    return nil, "extension_id is required"
  end
  local built, err = M.build()
  if not built then
    return nil, err
  end

  local host_name = config.get().capture.browser.host_name
  local path = manifest_path(host_name)
  if not path then
    return nil, "unsupported platform for Chrome native messaging manifest"
  end
  local manifest = {
    name = host_name,
    description = "ZK Capture native host",
    path = built.launcher_path,
    type = "stdio",
    allowed_origins = { "chrome-extension://" .. extension_id .. "/" },
  }
  local ok
  ok, err = write_text(path, vim.json.encode(manifest))
  if not ok then
    return nil, err
  end
  built.manifest_path = path
  built.host_name = host_name
  return built
end

return M
