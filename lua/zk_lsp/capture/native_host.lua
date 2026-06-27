local function read_exact(count)
  local chunks = {}
  local total = 0
  while total < count do
    local chunk = io.stdin:read(count - total)
    if not chunk or chunk == "" then
      return nil
    end
    chunks[#chunks + 1] = chunk
    total = total + #chunk
  end
  return table.concat(chunks)
end

local function decode_length(header)
  local b1, b2, b3, b4 = header:byte(1, 4)
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function encode_length(length)
  local b1 = length % 256
  local b2 = math.floor(length / 256) % 256
  local b3 = math.floor(length / 65536) % 256
  local b4 = math.floor(length / 16777216) % 256
  return string.char(b1, b2, b3, b4)
end

local function read_message()
  local header = read_exact(4)
  if not header then
    return nil
  end
  local length = decode_length(header)
  local body = read_exact(length)
  if not body then
    return nil
  end
  return vim.json.decode(body)
end

local function write_message(payload)
  local body = vim.json.encode(payload)
  io.stdout:write(encode_length(#body))
  io.stdout:write(body)
  io.stdout:flush()
end

local function read_config(path)
  local raw = table.concat(vim.fn.readfile(path), "\n")
  return vim.json.decode(raw)
end

local function handle(message)
  if type(message) ~= "table" then
    return { ok = false, error = "invalid native message" }
  end
  if message.action == "ping" then
    return { ok = true, status = "pong" }
  end

  local capture = require("zk_lsp.capture")
  local result, err
  if message.action == "capturePage" then
    message.from_browser = true
    result, err = capture.capture_page(message)
  elseif message.action == "capturePdfFile" then
    result, err = capture.capture_pdf_file({
      path = message.path,
      title = message.title,
      source_url = message.sourceUrl or message.source_url or message.url,
      extra_metadata = message.metadata,
      move = true,
      from_browser = true,
    })
  elseif message.action == "capturePdfUrl" then
    return { ok = false, error = "Chrome capture must download the PDF before calling native host" }
  else
    return { ok = false, error = "unknown action: " .. tostring(message.action) }
  end
  if not result then
    return { ok = false, error = err or "capture failed" }
  end
  result.ok = true
  return result
end

local config_path = arg and arg[1]
if not config_path or config_path == "" then
  write_message({ ok = false, error = "missing native host config path" })
  os.exit(1)
end

local host_config = read_config(config_path)
if host_config.plugin_root then
  vim.opt.runtimepath:prepend(host_config.plugin_root)
end

require("zk_lsp").setup({
  executable = host_config.executable,
  wiki_root = host_config.wiki_root,
  capture = host_config.capture,
})

local ok, message = pcall(read_message)
if not ok or not message then
  write_message({ ok = false, error = ok and "empty native message" or tostring(message) })
  os.exit(1)
end

local handled_ok, response = pcall(handle, message)
if not handled_ok then
  write_message({ ok = false, error = tostring(response) })
  os.exit(1)
end
write_message(response)
