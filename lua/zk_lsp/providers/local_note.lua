local M = {}

local function split_lines(text)
  return vim.split(text or "", "\n", { plain = true })
end

local function sorted_set_values(set)
  local values = {}
  for value, enabled in pairs(set) do
    if enabled then
      values[#values + 1] = value
    end
  end
  table.sort(values)
  return values
end

local function title_line(lines)
  for index, line in ipairs(lines) do
    if line:match("^=%s+.-%s+<%d%d%d%d%d%d%d%d%d%d>%s*$") then
      return index
    end
  end
  return 1
end

function M.new()
  return {
    name = "local_note",
    fields = {
      {
        path = "local.tags",
        kind = "array-string",
        label = "Local tags",
        source = "local_note",
      },
    },
    enrich = function(note)
      local content = note.content
      if type(content) ~= "string" and type(note.path) == "string" and vim.fn.filereadable(note.path) == 1 then
        content = table.concat(vim.fn.readfile(note.path), "\n")
      end

      local lines = split_lines(content)
      local tags = {}
      local references = {}
      for _, line in ipairs(lines) do
        for tag in line:gmatch("#tag%.([%w_-]+)") do
          tags[tag] = true
        end
        for id in line:gmatch("@(%d%d%d%d%d%d%d%d%d%d)") do
          references[id] = true
        end
      end

      return {
        title_line = title_line(lines),
        tags = sorted_set_values(tags),
        references = references,
        metadata = {
          ["local"] = {
            tags = sorted_set_values(tags),
          },
        },
      }
    end,
  }
end

return M
