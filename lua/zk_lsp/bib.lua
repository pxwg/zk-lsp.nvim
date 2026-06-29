local config = require("zk_lsp.config")

local M = {}

local function trim(value)
  if type(value) ~= "string" then
    return ""
  end
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function collapse_ws(value)
  return trim((value or ""):gsub("%s+", " "))
end

local function join_paths(...)
  return (table.concat({ ... }, "/"):gsub("//+", "/"))
end

local function read_file_text(path)
  if vim.fn.filereadable(path) == 0 then
    return ""
  end
  return table.concat(vim.fn.readfile(path), "\n")
end

local function split_lines(text)
  return vim.split(text or "", "\n", { plain = true })
end

local function line_for_offset(text, offset)
  local _, count = text:sub(1, math.max(offset - 1, 0)):gsub("\n", "")
  return count + 1
end

local function strip_wrapping_braces(value)
  value = trim(value)
  while value:match("^{.*}$") do
    local depth = 0
    local balanced = true
    for index = 1, #value do
      local ch = value:sub(index, index)
      if ch == "{" then
        depth = depth + 1
      elseif ch == "}" then
        depth = depth - 1
        if depth == 0 and index < #value then
          balanced = false
          break
        end
      end
      if depth < 0 then
        balanced = false
        break
      end
    end
    if not balanced or depth ~= 0 then
      break
    end
    value = trim(value:sub(2, -2))
  end
  return value
end

local function normalize_field_value(value)
  value = strip_wrapping_braces(value or "")
  value = value:gsub("\\\n%s*", " ")
  return collapse_ws(value)
end

local function read_braced_value(text, pos)
  local depth = 1
  local index = pos + 1
  while index <= #text do
    local ch = text:sub(index, index)
    if ch == "{" then
      depth = depth + 1
    elseif ch == "}" then
      depth = depth - 1
      if depth == 0 then
        return text:sub(pos + 1, index - 1), index + 1
      end
    end
    index = index + 1
  end
  return text:sub(pos + 1), #text + 1
end

local function read_quoted_value(text, pos)
  local index = pos + 1
  while index <= #text do
    local ch = text:sub(index, index)
    local prev = index > 1 and text:sub(index - 1, index - 1) or ""
    if ch == '"' and prev ~= "\\" then
      return text:sub(pos + 1, index - 1), index + 1
    end
    index = index + 1
  end
  return text:sub(pos + 1), #text + 1
end

local function read_bare_value(text, pos)
  local index = pos
  while index <= #text do
    local ch = text:sub(index, index)
    if ch == "," or ch == "\n" or ch == "}" or ch == ")" then
      break
    end
    index = index + 1
  end
  return text:sub(pos, index - 1), index
end

local function parse_fields(body)
  local fields = {}
  local pos = 1
  while pos <= #body do
    local start_idx, eq_idx, name = body:find("([%a][%w_%-%:]*)%s*=", pos)
    if not start_idx then
      break
    end
    pos = eq_idx + 1
    while pos <= #body and body:sub(pos, pos):match("%s") do
      pos = pos + 1
    end
    local ch = body:sub(pos, pos)
    local value
    if ch == "{" then
      value, pos = read_braced_value(body, pos)
    elseif ch == '"' then
      value, pos = read_quoted_value(body, pos)
    else
      value, pos = read_bare_value(body, pos)
    end
    fields[name:lower()] = normalize_field_value(value)
  end
  return fields
end

function M.parse_text(text)
  local entries = {}
  local pos = 1
  while true do
    local entry_start, type_end, entry_type, open_char = text:find("@([%a][%w%-]*)%s*([%{%(%[])", pos)
    if not entry_start then
      break
    end

    local close_char = open_char == "{" and "}" or (open_char == "(" and ")" or "]")
    local depth = 1
    local index = type_end + 1
    local in_quote = false
    local entry_end
    while index <= #text do
      local ch = text:sub(index, index)
      local prev = index > 1 and text:sub(index - 1, index - 1) or ""
      if ch == '"' and prev ~= "\\" then
        in_quote = not in_quote
      end
      if not in_quote then
        if ch == open_char then
          depth = depth + 1
        elseif ch == close_char then
          depth = depth - 1
        end
        if depth == 0 then
          entry_end = index
          break
        end
      end
      index = index + 1
    end
    if not entry_end then
      break
    end

    local entry_text = text:sub(entry_start, entry_end)
    local first_comma = entry_text:find(",", 1, true)
    local raw_key = first_comma and trim(entry_text:sub(entry_text:find(open_char, 1, true) + 1, first_comma - 1)) or ""
    local key = raw_key:match("[%s=]") and "" or raw_key
    local body = first_comma and entry_text:sub(first_comma + 1, -2) or ""
    entries[#entries + 1] = {
      type = entry_type:lower(),
      key = key,
      raw_key = raw_key,
      text = entry_text,
      fields = parse_fields(body),
      start_line = line_for_offset(text, entry_start),
      end_line = line_for_offset(text, entry_end),
      start_offset = entry_start,
      end_offset = entry_end,
    }
    pos = entry_end + 1
  end
  return entries
end

function M.parse_entry(text)
  return M.parse_text(text or "")[1]
end

function M.wiki_root(root)
  return vim.fs.normalize(root or config.get().wiki_root)
end

function M.bib_path(root)
  local path = config.get().capture.bibliography.path or "ref.bib"
  if path:match("^/") then
    return vim.fs.normalize(path)
  end
  return vim.fs.normalize(join_paths(M.wiki_root(root), path))
end

function M.parse_file(path)
  return M.parse_text(read_file_text(path or M.bib_path()))
end

function M.field(entry, name)
  if not entry or type(entry.fields) ~= "table" then
    return ""
  end
  return entry.fields[(name or ""):lower()] or ""
end

local function normalize_doi(value)
  value = trim(value or "")
  value = value:gsub("^https?://dx%.doi%.org/", "")
  value = value:gsub("^https?://doi%.org/", "")
  return value:lower()
end

function M.normalize_doi(value)
  return normalize_doi(value)
end

local function normalize_url(value)
  value = trim(value or "")
  value = value:gsub("%s+", "")
  value = value:gsub("#.*$", "")
  value = value:gsub("%?$", "")
  value = value:gsub("/$", "")
  return value
end

local function normalize_file_path(value)
  value = trim(value or "")
  if value:sub(1, 1) == "~" then
    value = vim.fn.expand(value)
  end
  return value:gsub("/+$", "")
end

local function normalize_arxiv_id(value)
  value = trim(value or "")
  value = value:gsub("^arXiv:", "")
  value = value:gsub("^https?://arxiv%.org/abs/", "")
  value = value:gsub("^https?://arxiv%.org/pdf/", "")
  value = value:gsub("%.pdf$", "")
  value = value:gsub("^https?://doi%.org/10%.48550/arXiv%.", "")
  value = value:gsub("^10%.48550/arXiv%.", "")
  value = value:gsub("v%d+$", "")
  return value:lower()
end

function M.normalize_arxiv_id(value)
  return normalize_arxiv_id(value)
end

function M.extract_arxiv_id(value)
  value = trim(value or "")
  local id = value:match("arxiv%.org/abs/([^?#%s]+)")
    or value:match("arxiv%.org/pdf/([^?#%s]+)")
    or value:match("^arXiv:(.+)$")
    or value:match("^arxiv:(.+)$")
    or value:match("10%.48550/arXiv%.([^%s}%]%)>,]+)")
  if not id then
    return nil
  end
  id = id:gsub("%.pdf$", "")
  return id
end

function M.find_entry_by_key(key, opts)
  key = trim((key or ""):gsub("^@", ""))
  if key == "" then
    return nil
  end
  local path = (opts and opts.bib_path) or M.bib_path(opts and opts.wiki_root)
  for _, entry in ipairs(M.parse_file(path)) do
    if entry.key == key then
      entry.bib_path = path
      return entry
    end
  end
  return nil
end

function M.find_duplicate(query, opts)
  query = query or {}
  local path = (opts and opts.bib_path) or M.bib_path(opts and opts.wiki_root)
  local parsed = query.entry or (query.bibtex and M.parse_entry(query.bibtex)) or nil
  local fields = vim.deepcopy((parsed and parsed.fields) or {})
  for key, value in pairs(query.fields or {}) do
    fields[key:lower()] = value
  end

  local key = trim(query.key or (parsed and parsed.key) or "")
  local doi = normalize_doi(query.doi or fields.doi or "")
  local url = normalize_url(query.url or fields.url or fields.howpublished or "")
  local file_value = trim(query.file or fields.file or "")
  local eprint = normalize_arxiv_id(query.eprint or fields.eprint or M.extract_arxiv_id(url) or "")

  for _, entry in ipairs(M.parse_file(path)) do
    entry.bib_path = path
    if key ~= "" and entry.key == key then
      return entry, "key"
    end
    local entry_doi = normalize_doi(M.field(entry, "doi"))
    if doi ~= "" and entry_doi ~= "" and doi == entry_doi then
      return entry, "doi"
    end
    local entry_url =
      normalize_url(M.field(entry, "url") ~= "" and M.field(entry, "url") or M.field(entry, "howpublished"))
    local entry_eprint = normalize_arxiv_id(
      M.field(entry, "eprint") ~= "" and M.field(entry, "eprint") or M.extract_arxiv_id(entry_url) or ""
    )
    if eprint ~= "" and entry_eprint ~= "" and eprint == entry_eprint then
      return entry, "eprint"
    end
    if url ~= "" and entry_url ~= "" and url == entry_url then
      return entry, "url"
    end
    if file_value ~= "" and normalize_file_path(M.field(entry, "file")) == normalize_file_path(file_value) then
      return entry, "file"
    end
  end
  return nil, nil
end

local function bib_escape(value)
  return collapse_ws(value or ""):gsub("[{}]", "")
end

function M.append_entry(entry_text, opts)
  entry_text = trim(entry_text or "")
  if entry_text == "" then
    return nil, "empty BibTeX entry"
  end
  local path = (opts and opts.bib_path) or M.bib_path(opts and opts.wiki_root)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local lines = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
  if #lines > 0 and trim(lines[#lines]) ~= "" then
    lines[#lines + 1] = ""
  end
  vim.list_extend(lines, split_lines(entry_text))
  local ok, err = pcall(vim.fn.writefile, lines, path)
  if not ok then
    return nil, tostring(err)
  end
  return true, nil
end

function M.set_entry_field(key, field_name, value, opts)
  local path = (opts and opts.bib_path) or M.bib_path(opts and opts.wiki_root)
  local lines = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or nil
  if not lines then
    return nil, "ref.bib is not readable"
  end
  local entry = M.find_entry_by_key(key, { bib_path = path })
  if not entry then
    return nil, "no entry found for @" .. key
  end
  local field_pattern = "^%s*" .. vim.pesc(field_name) .. "%s*="
  local replacement = "  " .. field_name .. " = {" .. bib_escape(value) .. "},"
  for index = entry.start_line + 1, entry.end_line - 1 do
    if lines[index] and lines[index]:lower():match(field_pattern:lower()) then
      local indent = lines[index]:match("^(%s*)") or "  "
      lines[index] = indent .. field_name .. " = {" .. bib_escape(value) .. "},"
      local ok, err = pcall(vim.fn.writefile, lines, path)
      if not ok then
        return nil, tostring(err)
      end
      return true, nil
    end
  end
  table.insert(lines, entry.end_line, replacement)
  local ok, err = pcall(vim.fn.writefile, lines, path)
  if not ok then
    return nil, tostring(err)
  end
  return true, nil
end

local stopwords = {
  a = true,
  an = true,
  ["and"] = true,
  ["for"] = true,
  ["in"] = true,
  of = true,
  on = true,
  the = true,
  to = true,
  with = true,
}

function M.slug(value, opts)
  opts = opts or {}
  local max_words = opts.max_words or 6
  local separator = opts.separator or ""
  local words = {}
  value = (value or ""):lower():gsub("['’]", ""):gsub("[^%w]+", " ")
  for word in value:gmatch("[%w]+") do
    if not stopwords[word] or #words == 0 then
      words[#words + 1] = word
    end
    if #words >= max_words then
      break
    end
  end
  return table.concat(words, separator)
end

local function short_hash(value)
  local hash = 5381
  for index = 1, #(value or "") do
    hash = (hash * 33 + value:byte(index)) % 0x1000000
  end
  return string.format("%06x", hash)
end

function M.derive_key(fields)
  fields = fields or {}
  local title = fields.title or fields.url or fields.file or "source"
  local year = tostring(fields.year or fields.date or ""):match("%d%d%d%d") or ""
  local slug = M.slug(title, { max_words = 4 })
  if slug == "" then
    slug = "source"
  end
  if year ~= "" then
    return slug .. year
  end
  return slug .. short_hash(title)
end

function M.clean_title(value)
  value = collapse_ws(value or "")
  value = value:gsub("^%{", ""):gsub("%}$", "")
  return value
end

function M.render_entry(entry)
  local entry_type = entry.type or "misc"
  local key = entry.key or M.derive_key(entry.fields or {})
  local fields = entry.fields or {}
  local order = {
    "author",
    "title",
    "year",
    "journal",
    "booktitle",
    "doi",
    "url",
    "eprint",
    "archiveprefix",
    "primaryclass",
    "file",
  }
  local emitted = {}
  local lines = { "@" .. entry_type .. "{" .. key .. "," }
  for _, name in ipairs(order) do
    local value = fields[name]
    if value and trim(tostring(value)) ~= "" then
      lines[#lines + 1] = "  " .. name .. " = {" .. bib_escape(tostring(value)) .. "},"
      emitted[name] = true
    end
  end
  local extra = {}
  for name, value in pairs(fields) do
    if not emitted[name] and trim(tostring(value)) ~= "" then
      extra[#extra + 1] = name
    end
  end
  table.sort(extra)
  for _, name in ipairs(extra) do
    lines[#lines + 1] = "  " .. name .. " = {" .. bib_escape(tostring(fields[name])) .. "},"
  end
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n")
end

function M.source_key_from_content(content)
  return (content or ""):match("Source:%s*@([%w%-%_:%.]+)") or (content or ""):match("@([%w%-%_:%.]+)")
end

function M.split_words(value)
  if type(value) == "table" then
    local result = {}
    for _, item in ipairs(value) do
      if trim(tostring(item)) ~= "" then
        result[#result + 1] = collapse_ws(tostring(item))
      end
    end
    return result
  end

  local result = {}
  for word in tostring(value or ""):gmatch("[^,;]+") do
    word = collapse_ws(word)
    if word ~= "" then
      result[#result + 1] = word
    end
  end
  return result
end

function M.entry_primary_source(entry)
  if not entry then
    return ""
  end
  local file = M.field(entry, "file")
  if file ~= "" then
    return file
  end
  local url = M.field(entry, "url")
  if url ~= "" then
    return url
  end
  local doi = M.field(entry, "doi")
  if doi ~= "" then
    return "https://doi.org/" .. normalize_doi(doi)
  end
  local eprint = M.field(entry, "eprint")
  if eprint ~= "" then
    return "https://arxiv.org/abs/" .. eprint
  end
  return ""
end

function M.find_source_notes(key, opts)
  local root = M.wiki_root(opts and opts.wiki_root)
  local matches = {}
  for _, path in ipairs(vim.fn.globpath(join_paths(root, "note"), "*.typ", false, true)) do
    local text = read_file_text(path)
    if text:match("Source:%s*@" .. vim.pesc(key) .. "%f[%W]") then
      matches[#matches + 1] = path
    end
  end
  return matches
end

function M.open_source_or_entry(key, opts)
  local matches = M.find_source_notes(key, opts)
  if #matches > 0 then
    vim.cmd.edit(vim.fn.fnameescape(matches[1]))
    return matches[1]
  end

  local entry = M.find_entry_by_key(key, opts)
  if entry and entry.bib_path then
    vim.cmd.edit(vim.fn.fnameescape(entry.bib_path))
    vim.api.nvim_win_set_cursor(0, { entry.start_line, 0 })
    return entry.bib_path
  end
  return nil
end

function M.ensure_bibliography(opts)
  opts = opts or {}
  local root = M.wiki_root(opts.wiki_root)
  local bib_path = M.bib_path(root)
  vim.fn.mkdir(vim.fn.fnamemodify(bib_path, ":h"), "p")
  if vim.fn.filereadable(bib_path) == 0 then
    vim.fn.writefile({}, bib_path)
  end

  local declare = config.get().capture.bibliography.declare or {}
  if declare.enabled == false then
    return true
  end
  local file = declare.file or "index.typ"
  local target = file:match("^/") and file or join_paths(root, file)
  if vim.fn.filereadable(target) == 0 then
    return true, "bibliography declaration target does not exist: " .. target
  end
  local rel = config.get().capture.bibliography.path or "ref.bib"
  local line = declare.line or ('#bibliography("' .. rel .. '")')
  local lines = vim.fn.readfile(target)
  for _, existing in ipairs(lines) do
    if existing:find(line, 1, true) then
      return true
    end
  end
  if #lines > 0 and trim(lines[#lines]) ~= "" then
    lines[#lines + 1] = ""
  end
  lines[#lines + 1] = line
  local ok, err = pcall(vim.fn.writefile, lines, target)
  if not ok then
    return nil, tostring(err)
  end
  return true
end

return M
