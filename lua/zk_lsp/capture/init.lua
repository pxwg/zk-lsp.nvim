local bib = require("zk_lsp.bib")
local cli = require("zk_lsp.cli")
local config = require("zk_lsp.config")
local http = require("zk_lsp.http")
local schema = require("zk_lsp.schema")
local util = require("zk_lsp.util")

local M = {}

local function trim(value)
  if type(value) ~= "string" then
    return ""
  end
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function collapse_ws(value)
  return trim(tostring(value or ""):gsub("%s+", " "))
end

local function join_paths(...)
  local path = table.concat({ ... }, "/"):gsub("//+", "/")
  return vim.fs.normalize(path)
end

local function basename(path)
  return vim.fn.fnamemodify(path, ":t")
end

local function stem(path)
  return vim.fn.fnamemodify(path, ":t:r")
end

local function is_url(value)
  return tostring(value or ""):match("^https?://") ~= nil
end

local function infer_title_from_url(url)
  local path = tostring(url or ""):gsub("[?#].*$", ""):gsub("/+$", "")
  local name = path:match("([^/]+)$") or "Captured source"
  name = name:gsub("%.[%w]+$", ""):gsub("[-_]+", " ")
  return collapse_ws(name:gsub("^%l", string.upper))
end

local function decode_html_entities(value)
  value = tostring(value or "")
  local entities = {
    amp = "&",
    lt = "<",
    gt = ">",
    quot = '"',
    apos = "'",
    nbsp = " ",
  }
  value = value:gsub("&(#%d+);", function(code)
    local number = tonumber(code:sub(2))
    if number and number < 128 then
      return string.char(number)
    end
    return " "
  end)
  value = value:gsub("&([%a]+);", function(name)
    return entities[name] or " "
  end)
  return collapse_ws(value)
end

local function split_keywords(value)
  if type(value) == "table" then
    local result = {}
    for _, item in ipairs(value) do
      local text = collapse_ws(item)
      if text ~= "" then
        result[#result + 1] = text
      end
    end
    return result
  end

  local result = {}
  for item in tostring(value or ""):gmatch("[^,;]+") do
    item = collapse_ws(item)
    if item ~= "" then
      result[#result + 1] = item
    end
  end
  return result
end

local function flatten_metadata(metadata, prefix, out)
  out = out or {}
  for key, value in pairs(metadata or {}) do
    local path = prefix and (prefix .. "." .. key) or key
    if type(value) == "table" and not vim.islist(value) then
      flatten_metadata(value, path, out)
    else
      out[path] = value
    end
  end
  return out
end

local function source_list(source)
  local result = {}
  local seen = {}
  local function add(value)
    value = trim(value)
    if value ~= "" and not seen[value] then
      seen[value] = true
      result[#result + 1] = value
    end
  end

  if type(source) == "table" then
    for _, value in ipairs(source) do
      add(value)
    end
  else
    add(source)
  end
  return result
end

local function base_metadata(capture_type, source, extra)
  extra = extra or {}
  local metadata = {
    aliases = {},
    abstract = extra.abstract or "",
    keywords = split_keywords(extra.keywords),
    generated = true,
    ["checklist-status"] = "none",
    relation = "active",
    ["relation-target"] = {},
    ["user.public"] = true,
    ["user.ai-generated"] = false,
    ["user.captured"] = true,
    ["user.source"] = source_list(source),
    ["user.capture-type"] = capture_type,
    ["user.frs"] = false,
    ["user.project"] = "",
  }

  for key, value in pairs(flatten_metadata(extra.metadata or {})) do
    metadata[key] = value
  end
  return metadata
end

local function filter_metadata(metadata)
  metadata = vim.deepcopy(metadata or {})
  metadata["schema-version"] = nil
  local filtered, skipped, err = schema.filter_metadata(metadata)
  if err then
    return nil, skipped, err
  end
  return filtered, skipped, nil
end

local function warn_skipped(skipped)
  if skipped and #skipped > 0 then
    util.notify("Skipped unsupported metadata fields: " .. table.concat(skipped, ", "), vim.log.levels.WARN)
  end
end

local function title_heading(title, id)
  title = collapse_ws(title)
  if title == "" then
    return "= <" .. id .. ">"
  end
  return "= " .. title .. " <" .. id .. ">"
end

local function find_note_heading(lines, id)
  local escaped = vim.pesc(id or "")
  for index, line in ipairs(lines) do
    if line:match("^=%s*.-<" .. escaped .. ">%s*$") then
      return index
    end
  end
  for index, line in ipairs(lines) do
    if line:match("^=%s+") then
      return index
    end
  end
  return nil
end

local function content_insert_index(lines, heading_index)
  local index = heading_index + 1
  while lines[index] == "" do
    index = index + 1
  end
  if lines[index] and lines[index]:match("^#status_tag%(") then
    return index + 1
  end
  return heading_index + 1
end

local function normalize_created_note(path, id, title, content)
  if not path or path == "" or vim.fn.filereadable(path) == 0 then
    return nil, "created note is not readable: " .. tostring(path)
  end
  if not id or id == "" then
    return nil, "created note path did not include a note id: " .. path
  end
  local lines = vim.fn.readfile(path)
  local heading_index = find_note_heading(lines, id)
  if not heading_index then
    return nil, "created note has no title heading: " .. path
  end

  lines[heading_index] = title_heading(title, id)
  content = trim(content)
  if content ~= "" and not table.concat(lines, "\n"):find(content, 1, true) then
    local insert_at = content_insert_index(lines, heading_index)
    local block = vim.split(content, "\n", { plain = true })
    table.insert(block, 1, "")
    for offset, line in ipairs(block) do
      table.insert(lines, insert_at + offset - 1, line)
    end
  end

  local ok, err = pcall(vim.fn.writefile, lines, path)
  if not ok then
    return nil, tostring(err)
  end
  return true
end

local function toml_string(value)
  return '"' .. tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n") .. '"'
end

local function toml_array(values)
  local encoded = {}
  for _, value in ipairs(values) do
    encoded[#encoded + 1] = toml_string(value)
  end
  return "[" .. table.concat(encoded, ", ") .. "]"
end

local function toml_block_range(lines)
  local start_line = nil
  for index, line in ipairs(lines) do
    if not start_line and line:match("^%s*```toml%s*$") then
      start_line = index
    elseif start_line and line:match("^%s*```%.text%s*,?%s*$") then
      return start_line + 1, index - 1
    end
  end
  return nil, nil
end

local function rewrite_note_source(path, sources)
  sources = source_list(sources)
  local filtered, skipped, filter_err = filter_metadata({ ["user.source"] = sources })
  if not filtered then
    return nil, filter_err
  end
  if filtered["user.source"] == nil then
    warn_skipped(skipped)
    return true, skipped
  end

  local lines = vim.fn.readfile(path)
  local toml_start, toml_end = toml_block_range(lines)
  if not toml_start then
    return nil, "created note has no TOML metadata block: " .. path
  end

  local user_start = nil
  local source_line = nil
  for index = toml_start, toml_end do
    local line = lines[index]
    if line:match("^%s*%[user%]%s*$") then
      user_start = index
    elseif user_start and index > user_start and line:match("^%s*%[.+%]%s*$") then
      break
    elseif user_start and line:match("^%s*source%s*=") then
      source_line = index
      break
    end
  end

  local replacement = "  source = " .. toml_array(filtered["user.source"])
  if source_line then
    lines[source_line] = (lines[source_line]:match("^(%s*)") or "  ")
      .. "source = "
      .. toml_array(filtered["user.source"])
  elseif user_start then
    table.insert(lines, user_start + 1, replacement)
  else
    table.insert(lines, toml_end + 1, "  [user]")
    table.insert(lines, toml_end + 2, replacement)
  end

  local ok, err = pcall(vim.fn.writefile, lines, path)
  if not ok then
    return nil, tostring(err)
  end
  warn_skipped(skipped)
  return true, skipped
end

local function merge_note(base, patch)
  if type(patch) ~= "table" then
    return base
  end
  if type(patch.note) == "table" then
    base = vim.tbl_deep_extend("force", base, patch.note)
  else
    base = vim.tbl_deep_extend("force", base, patch)
  end
  return base
end

local function run_template_hook(kind, hook_name, ctx)
  local template = config.get().capture.templates[kind]
  if type(template) == "function" and hook_name == "pre_create" then
    return template(ctx)
  end
  if type(template) ~= "table" then
    return nil
  end
  local hook = template[hook_name] or (type(template.hooks) == "table" and template.hooks[hook_name])
  if type(hook) ~= "function" then
    return nil
  end
  return hook(ctx)
end

local function create_note(kind, note, payload)
  local pre = run_template_hook(kind, "pre_create", {
    kind = kind,
    note = vim.deepcopy(note),
    payload = payload,
    wiki_root = config.get().wiki_root,
  })
  note = merge_note(note, pre)

  local filtered, skipped, filter_err = filter_metadata(note.metadata)
  if not filtered then
    return nil, filter_err
  end

  local created, err = cli.new({
    json = true,
    title = note.title,
    content = note.content,
    metadata = filtered,
  })
  if not created then
    return nil, err
  end
  local normalized, normalize_err = normalize_created_note(created.path, created.id, note.title, note.content)
  if not normalized then
    return nil, normalize_err
  end
  if note.metadata and note.metadata["user.source"] ~= nil then
    local source_ok, source_err = rewrite_note_source(created.path, note.metadata["user.source"])
    if not source_ok then
      return nil, source_err
    end
  end

  local result = {
    ok = true,
    status = "created",
    kind = kind,
    note_path = created.path,
    note_id = created.id,
    title = note.title,
    skipped_metadata = skipped,
  }

  local post = run_template_hook(kind, "post_create", {
    kind = kind,
    note = vim.tbl_deep_extend("force", vim.deepcopy(note), {
      path = created.path,
      id = created.id,
    }),
    payload = payload,
    result = result,
    wiki_root = config.get().wiki_root,
  })
  if type(post) == "table" then
    result = vim.tbl_deep_extend("force", result, post)
  end

  return result
end

local function meta_value(metadata, ...)
  metadata = metadata or {}
  for _, key in ipairs({ ... }) do
    local value = metadata[key]
    if trim(value) ~= "" then
      return trim(value)
    end
  end
  return ""
end

local function fetch_web_metadata(url)
  local html, err = http.text(url, { timeout = 20 })
  if not html then
    return nil, err
  end

  local metadata = {}
  metadata.title = decode_html_entities(html:match("<title[^>]*>(.-)</title>") or "")
  for attrs in html:gmatch("<meta%s+([^>]-)>") do
    local name = attrs:match('name%s*=%s*"([^"]+)"') or attrs:match("name%s*=%s*'([^']+)'")
    local property = attrs:match('property%s*=%s*"([^"]+)"') or attrs:match("property%s*=%s*'([^']+)'")
    local content = attrs:match('content%s*=%s*"([^"]*)"') or attrs:match("content%s*=%s*'([^']*)'")
    local key = name or property
    if key and content then
      metadata[key:lower()] = decode_html_entities(content)
    end
  end
  return {
    title = metadata.title,
    abstract = metadata.description or metadata["og:description"] or metadata["twitter:description"] or "",
    keywords = split_keywords(metadata.keywords),
  }
end

local function build_web_note(payload)
  payload = payload or {}
  local page_meta = payload.metadata or {}
  local url = trim(payload.url or page_meta.url or "")
  if url == "" then
    return nil, "capture web requires a URL"
  end

  local fetched = nil
  if not payload.from_browser and config.get().capture.fetch.manual then
    fetched = fetch_web_metadata(url)
  end

  local title = collapse_ws(payload.title)
  if title == "" then
    title = meta_value(page_meta, "title", "ogTitle", "twitterTitle")
  end
  if title == "" and fetched then
    title = fetched.title or ""
  end
  if title == "" then
    title = infer_title_from_url(url)
  end

  local abstract = collapse_ws(payload.abstract)
  if abstract == "" then
    abstract = meta_value(page_meta, "description", "ogDescription", "twitterDescription")
  end
  if abstract == "" and fetched then
    abstract = fetched.abstract or ""
  end

  local keywords = split_keywords(payload.keywords or page_meta.keywords or (fetched and fetched.keywords) or {})
  local source = trim(page_meta.canonicalUrl or page_meta.canonical or url)
  local body = { "#tag.capture", "", "Source: " .. url }
  if source ~= "" and source ~= url then
    body[#body + 1] = "Canonical: " .. source
  end
  local selection = trim(payload.selection or page_meta.selection or "")
  if selection ~= "" then
    body[#body + 1] = ""
    body[#body + 1] = selection
  elseif abstract ~= "" then
    body[#body + 1] = ""
    body[#body + 1] = abstract
  end

  return {
    title = title,
    content = table.concat(body, "\n"),
    metadata = base_metadata("web", source ~= "" and source or url, {
      abstract = abstract,
      keywords = keywords,
      metadata = payload.extra_metadata,
    }),
  }
end

function M.capture_page(payload)
  local note, err = build_web_note(payload)
  if not note then
    return nil, err
  end
  local result
  result, err = create_note("web", note, payload)
  if not result then
    return nil, err
  end
  warn_skipped(result.skipped_metadata)
  return result
end

local function unique_child(dir_path, filename)
  local name = filename ~= "" and filename or "paper.pdf"
  local candidate = join_paths(dir_path, name)
  local base = vim.fn.fnamemodify(name, ":r")
  local ext = vim.fn.fnamemodify(name, ":e")
  ext = ext ~= "" and ("." .. ext) or ""
  local index = 2
  while vim.fn.filereadable(candidate) == 1 do
    candidate = join_paths(dir_path, base .. "-" .. index .. ext)
    index = index + 1
  end
  return candidate
end

local function slugify_filename(filename)
  local ext = filename:match("(%.[%w]+)$") or ".pdf"
  local slug = bib.slug(stem(filename), { separator = "-", max_words = 12 })
  if slug == "" then
    slug = "paper"
  end
  return slug .. ext:lower()
end

local function rel_to_wiki(path)
  local root = config.get().wiki_root:gsub("/+$", "")
  path = vim.fs.normalize(path)
  if vim.startswith(path, root .. "/") then
    return path:sub(#root + 2)
  end
  return path
end

local function copy_file(source, target, move)
  local ok, err = vim.uv.fs_copyfile(source, target)
  if not ok then
    return nil, err
  end
  if move then
    local removed, remove_err = vim.uv.fs_unlink(source)
    if not removed then
      return nil, remove_err
    end
  end
  return true
end

local function ensure_bib()
  local ok, warning = bib.ensure_bibliography()
  if not ok then
    return nil, warning
  end
  if warning then
    util.notify(warning, vim.log.levels.WARN)
  end
  return true
end

local function append_entry(entry, target_rel)
  local fields = vim.deepcopy(entry.fields or {})
  fields.file = target_rel
  local key = entry.key or bib.derive_key(fields)
  local text = bib.render_entry({
    type = entry.type or "misc",
    key = key,
    fields = fields,
  })
  local ok, err = bib.append_entry(text)
  if not ok then
    return nil, err
  end
  return key
end

local function entry_sources(entry)
  local sources = {}
  if entry then
    sources[#sources + 1] = bib.field(entry, "url")
    sources[#sources + 1] = bib.field(entry, "file")
  end
  if #source_list(sources) == 0 then
    sources[#sources + 1] = bib.entry_primary_source(entry)
  end
  return source_list(sources)
end

function M.capture_pdf_file(payload)
  payload = payload or {}
  local source_path = vim.fs.normalize(vim.fn.expand(trim(payload.path or payload.file or payload.filename or "")))
  if source_path == "" or vim.fn.filereadable(source_path) == 0 then
    return nil, "capture paper requires a readable PDF path"
  end

  local ok, err = ensure_bib()
  if not ok then
    return nil, err
  end

  local parsed = payload.bibtex and bib.parse_entry(payload.bibtex) or nil
  local fields = vim.deepcopy((parsed and parsed.fields) or {})
  local source_url = trim(payload.source_url or payload.sourceUrl or payload.url or fields.url or "")
  local title = collapse_ws(payload.title)
  if title == "" then
    title = bib.clean_title(fields.title or "")
  end
  if title == "" then
    title = stem(source_path)
  end

  local key = trim(payload.key or (parsed and parsed.key) or "")
  if key == "" then
    key = bib.derive_key({ title = title, url = source_url, file = source_path })
  end
  fields.title = fields.title or title
  if source_url ~= "" and not fields.url then
    fields.url = source_url
  end

  local duplicate, reason = bib.find_duplicate({
    key = key,
    fields = fields,
    file = source_path,
    url = source_url,
    entry = parsed,
  })
  local reused_entry = nil
  local reused_reason = nil
  if duplicate then
    local matches = bib.find_source_notes(duplicate.key)
    if #matches > 0 then
      return {
        ok = true,
        status = "exists",
        kind = "paper",
        key = duplicate.key,
        matched_by = reason,
        note_path = matches[1],
        ref_path = bib.bib_path(),
      }
    end

    reused_entry = duplicate
    reused_reason = reason
    key = duplicate.key
    fields = vim.tbl_deep_extend("keep", fields, vim.deepcopy(duplicate.fields or {}))
    if title == "" then
      title = bib.clean_title(fields.title or "")
    end
  end

  local note = {
    title = title,
    content = table.concat({ "#tag.capture", "", "Source: @" .. key }, "\n"),
    metadata = base_metadata("paper", source_url ~= "" and { source_url } or {}, {
      abstract = fields.abstract or payload.abstract or "",
      keywords = split_keywords(fields.keywords or payload.keywords or {}),
      metadata = payload.extra_metadata or payload.metadata,
    }),
  }
  local result
  result, err = create_note("paper", note, payload)
  if not result then
    return nil, err
  end

  local asset_dir = join_paths(config.get().wiki_root, "assets", result.note_id .. "-pdf")
  vim.fn.mkdir(asset_dir, "p")
  local target = unique_child(asset_dir, slugify_filename(basename(source_path)))
  ok, err = copy_file(source_path, target, payload.move == true)
  if not ok then
    return nil, err
  end

  local target_rel = rel_to_wiki(target)
  ok, err = rewrite_note_source(result.note_path, { source_url, target_rel })
  if not ok then
    return nil, err
  end

  if reused_entry then
    if bib.field(reused_entry, "file") == "" then
      ok, err = bib.set_entry_field(key, "file", target_rel)
      if not ok then
        return nil, err
      end
    end
  else
    key, err = append_entry({
      type = parsed and parsed.type or "misc",
      key = key,
      fields = fields,
    }, target_rel)
    if not key then
      return nil, err
    end
  end

  result.key = key
  result.reused_bib_entry = reused_entry ~= nil
  result.matched_by = reused_reason
  result.asset_path = target
  result.asset_rel = target_rel
  result.ref_path = bib.bib_path()
  warn_skipped(result.skipped_metadata)
  return result
end

local function pdf_filename_from_url(url)
  local name = url:gsub("[?#].*$", ""):match("([^/]+)$") or "paper.pdf"
  name = vim.uri_decode(name)
  if not name:lower():match("%.pdf$") then
    name = name .. ".pdf"
  end
  return name
end

function M.capture_pdf_url(url, opts)
  opts = opts or {}
  url = trim(url)
  if url == "" then
    return nil, "capture paper requires a URL"
  end
  if not config.get().capture.fetch.paper then
    return nil, "paper URL fetch is disabled"
  end
  local tmp = join_paths(vim.fn.tempname(), pdf_filename_from_url(url))
  vim.fn.mkdir(vim.fn.fnamemodify(tmp, ":h"), "p")
  local downloaded, err = http.download(url, tmp, { timeout = 60 })
  if not downloaded then
    return nil, err
  end
  return M.capture_pdf_file(vim.tbl_deep_extend("force", opts, {
    path = downloaded,
    source_url = url,
    move = true,
  }))
end

function M.paper_note_from_ref(key)
  key = trim((key or ""):gsub("^@", ""))
  if key == "" then
    return nil, "paper-note requires a BibTeX key"
  end

  local ok, err = ensure_bib()
  if not ok then
    return nil, err
  end

  local entry = bib.find_entry_by_key(key)
  if not entry then
    return nil, "No ref.bib entry found for @" .. key
  end
  local matches = bib.find_source_notes(key)
  if #matches > 0 then
    return {
      ok = true,
      status = "exists",
      kind = "paper",
      key = key,
      note_path = matches[1],
      ref_path = entry.bib_path,
    }
  end

  local title = bib.clean_title(bib.field(entry, "title"))
  if title == "" then
    title = key
  end
  local result
  result, err = create_note("paper", {
    title = title,
    content = table.concat({ "#tag.capture", "", "Source: @" .. key }, "\n"),
    metadata = base_metadata("paper", entry_sources(entry), {
      abstract = bib.field(entry, "abstract"),
      keywords = bib.split_words(bib.field(entry, "keywords")),
    }),
  }, { key = key, entry = entry })
  if not result then
    return nil, err
  end
  result.key = key
  result.ref_path = entry.bib_path
  warn_skipped(result.skipped_metadata)
  return result
end

local function open_created(result)
  if result and result.note_path and result.note_path ~= "" then
    vim.cmd.edit(vim.fn.fnameescape(result.note_path))
  end
end

local function notify_result(result)
  if result.status == "exists" then
    util.notify("Already captured @" .. (result.key or "unknown"))
  else
    util.notify("Captured " .. result.kind .. ": " .. (result.title or result.note_path or "note"))
  end
end

local function finish(result, err, open_note)
  if not result then
    util.notify(err or "capture failed", vim.log.levels.ERROR)
    return
  end
  notify_result(result)
  if open_note then
    open_created(result)
  end
end

function M.start()
  vim.ui.select({ "web", "paper" }, { prompt = "ZK capture" }, function(choice)
    if choice == "web" then
      M.dispatch({ "web" })
    elseif choice == "paper" then
      M.dispatch({ "paper" })
    end
  end)
end

function M.dispatch(args)
  args = args or {}
  local command = table.remove(args, 1)
  if not command or command == "" then
    M.start()
    return
  end

  if command == "web" then
    local url = args[1]
    if url and url ~= "" then
      local result, err = M.capture_page({ url = url })
      finish(result, err, true)
      return
    end
    vim.ui.input({ prompt = "Web URL: " }, function(input)
      local result, err = M.capture_page({ url = input })
      finish(result, err, true)
    end)
  elseif command == "paper" then
    local source = args[1]
    local function capture_source(value)
      value = trim(value)
      if value == "" then
        return
      end
      if is_url(value) then
        local result, err = M.capture_pdf_url(value)
        finish(result, err, true)
      else
        local result, err = M.capture_pdf_file({ path = value })
        finish(result, err, true)
      end
    end
    if source and source ~= "" then
      capture_source(source)
    else
      vim.ui.input({ prompt = "Paper URL or PDF path: " }, capture_source)
    end
  elseif command == "paper-note" then
    local key = args[1]
    if key and key ~= "" then
      local result, err = M.paper_note_from_ref(key)
      finish(result, err, true)
      return
    end
    vim.ui.input({ prompt = "BibTeX key: @", default = trim(vim.fn.expand("<cword>"):gsub("^@", "")) }, function(input)
      local result, err = M.paper_note_from_ref(input)
      finish(result, err, true)
    end)
  elseif command == "extension-path" then
    local install = require("zk_lsp.install")
    local path = install.extension_path()
    vim.fn.setreg("+", path)
    util.notify("Chrome extension path copied: " .. path)
  elseif command == "install-native-host" then
    local extension_id = args[1]
    if not extension_id or extension_id == "" then
      util.notify("Usage: :Zk capture install-native-host {extension_id}", vim.log.levels.ERROR)
      return
    end
    local install = require("zk_lsp.install")
    local result, err = install.install_native_host(extension_id)
    if not result then
      util.notify(err, vim.log.levels.ERROR)
      return
    end
    util.notify("Installed native host: " .. result.manifest_path)
  else
    util.notify("Unknown capture command: " .. tostring(command), vim.log.levels.ERROR)
  end
end

return M
